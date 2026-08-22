# frozen_string_literal: true

require "prism"

require_relative "../source/constant_path"
require_relative "../source/node_children"
require_relative "attribution"
require_relative "catalog"
require_relative "envelope_index"
require_relative "file_collection"
require_relative "label_set"
require_relative "mutation_classifier"
require_relative "narrowing"
require_relative "origin"
require_relative "plugin_facts"
require_relative "summary"

module Rigor
  module Effects
    # Scans one **effect unit** — a method body — into its direct {Summary} plus the unresolved edges the
    # propagator later closes over (ADR-103 WD4).
    #
    # Two rules shape the walk:
    #
    # - **Containment.** A block literal's origins always join the enclosing method's summary, whether the
    #   callee invokes the block now, later, or never; an envelope is a contract about the method's *code*.
    #   So the walk simply descends into `BlockNode`s and stops only at a nested `def` or at a
    #   `define_method` with a literal name, both of which are units of their own.
    # - **Observation.** Everything the walk knows about a receiver comes from what the typer already
    #   decided at that call node ({Collector::CallRecord}); the scan resolves nothing, walks no callee,
    #   and touches no `Scope`.
    #
    # What it cannot prove it taints, and a taint is never a finding — the summary reads "these effects,
    # and possibly more".
    # Long by construction: the walk carries one `when` per Ruby construct that originates an effect, and
    # splitting that table across classes would put the vocabulary in one file and the reasons in another.
    class UnitScan # rubocop:disable Metrics/ClassLength
      # `$~` and friends are frame-local, not global state: a read of one is not `global.read`. (Prism
      # gives `$1` and `$&` node types of their own, so only the named specials need listing.)
      FRAME_LOCAL_GLOBALS = %w[$~ $_ $& $` $' $+ $!].to_set.freeze

      REFLECTIVE_SEND = %i[send public_send __send__].to_set.freeze

      # Selectors a per-class POSTURE default must never answer for, because a more specific reading of
      # the same site exists and would be swallowed: `send` and friends are the `dynamic-send` taint, and
      # `call` is the `opaque-callable` one. An explicit ROW still wins (`Fiddle::Function#call` is
      # `ffi`) — it is only the class default that steps aside.
      DEFERRED_SELECTORS = %i[send public_send __send__ call].to_set.freeze

      # `eval` and its family with a *string* argument, and `binding`, hand the analyzer code it cannot
      # read. The design note § 5.1 puts them outside the catalogue for exactly that reason: there is no
      # upper bound to give, only the honest "and possibly more". The BLOCK forms
      # (`instance_eval { … }`) are containment and must not taint, so the taint is conditioned on a
      # positional argument being present.
      EVAL_SELECTORS = %i[eval instance_eval class_eval module_eval].to_set.freeze

      # The construct origins this scan can produce, spelled once. A construct origin is line-free and
      # carries no per-site state, so every site that produces one produces the SAME value — allocating a
      # fresh `Data` per `@ivar` write in a project's every method was pure garbage.
      DEFINE_METHOD = Origin.construct("define-method")
      XSTRING = Origin.construct("xstring")
      GVAR_READ = Origin.construct("gvar-read")
      GVAR_WRITE = Origin.construct("gvar-write")
      CVAR_READ = Origin.construct("cvar-read")
      CVAR_WRITE = Origin.construct("cvar-write")
      IVAR_WRITE = Origin.construct("ivar-write")
      ALIAS = Origin.construct("alias")
      UNDEF = Origin.construct("undef")
      RECEIVER_MUTATION = Origin.construct("receiver-mutation")
      private_constant :DEFINE_METHOD, :XSTRING, :GVAR_READ, :GVAR_WRITE, :CVAR_READ, :CVAR_WRITE,
                       :IVAR_WRITE, :ALIAS, :UNDEF, :RECEIVER_MUTATION

      # What a receiver rooted at implicit self spells as the head of a receiver path. Must agree with
      # `Rigor::Plugin::EffectAttribution::SELF_HEAD`, which is what a plugin writes; spelled again rather
      # than required so the effects namespace does not pull the plugin contract in, and pinned by spec.
      SELF_PATH_HEAD = "self"

      GLOBAL_READ = LabelSet.new(["global.read"])
      GLOBAL_WRITE = LabelSet.new(["global.write"])
      MUTATE_STATIC = LabelSet.new(["mutate.static"])
      MUTATE_SELF = LabelSet.new(["mutate.self"])
      IO_PROCESS = LabelSet.new(["io.process"])

      # `define_method(:literal) { … }` — the block becomes `literal`'s body (WD14), so the call is a unit
      # declaration wherever it appears: in a class body it is the only way that method exists, and inside
      # another method it is a definition the enclosing method performs (`mutate.static`) rather than code
      # the enclosing method contains. A non-literal name has no key to file the block under, so it stays
      # contained in the enclosing method and this returns nil.
      #
      # @return [Array, nil] `[name, singleton, body, parameters]`
      def self.define_method_unit(node)
        return nil unless node.name == :define_method && node.receiver.nil?

        first = node.arguments&.arguments&.first
        return nil unless first.is_a?(Prism::SymbolNode) && first.unescaped

        block = node.block
        return nil unless block.is_a?(Prism::BlockNode)

        [first.unescaped, false, block.body, block.parameters]
      end

      # @param singleton [Boolean] whether the unit's `self` is the class object (`def self.x`,
      #   `class << self`) — the axis that separates `mutate.self` from `mutate.static` on an ivar write
      # @param block_parameter [String, nil] the unit's `&blk` parameter name, if any; a call on it is
      #   forwarding, not an opaque callable
      # @param calls [Hash] node-identity table of {Collector::CallRecord}s
      # @param attribution [Attribution] the project's `effects.attribution:` table
      # @param envelopes [EnvelopeIndex] the envelopes a call site may import as a `≤` bound (#386)
      # @param plugin_facts [PluginFacts] the loaded plugins' `effect_attributions:` (#387)
      # @param owner_class [String, nil] the class this unit is defined on — the carrier an
      #   implicit-self call's envelope is looked up under, since the syntax spells `Kernel#name`
      # @param method_name [String, nil] this unit's own selector — what a `super` in its body names as
      #   the target the propagator resolves above `owner_class` (#446). With no name to state, a `super`
      #   taints instead.
      def initialize(singleton:, parameters:, block_parameter:, owned_locals:, calls:, # rubocop:disable Metrics/ParameterLists
                     attribution: Attribution.empty, envelopes: EnvelopeIndex.empty,
                     plugin_facts: PluginFacts.empty, owner_class: nil, method_name: nil)
        @singleton = singleton
        @block_parameter = block_parameter
        @calls = calls
        @attribution = attribution
        @envelopes = envelopes
        @plugin_facts = plugin_facts
        @owner_class = owner_class
        @method_name = method_name
        @mutation = MutationClassifier.new(
          singleton: singleton, parameters: parameters, owned_locals: owned_locals
        )
        @bundles = {}
        @declared_bundles = {}
        @causes = []
        @edges = []
        @nested = []
        @delegates_upward = false
      end

      # Units discovered inside this one — a nested `def`, or a `define_method` with a literal name whose
      # block becomes that method's body. Each is `[name, singleton, body_node, parameters_node]`.
      attr_reader :nested

      # Whether this body reaches `super` — an override that delegates upward still runs whatever the
      # superclass does. Nested `def`s are unit boundaries, so a `super` counted here is this unit's.
      #
      # A separate reading of the same node from the edge {#visit_super} records: what this bit answers is
      # whether a framework's claim about the selector survives the class having written a body for it
      # ({FrameworkUnits.replaced?}, #440), which is a question about the *class*, not about what the
      # parent implementation does.
      def delegates_upward?
        @delegates_upward
      end

      # Walks `body` and returns `[Summary, edges]`.
      def run(body)
        walk(body)
        summary = Summary.new(
          bundles: @bundles, declared_bundles: @declared_bundles,
          exhaustive: @causes.empty?, causes: @causes
        )
        [summary, @edges]
      end

      private

      def add(origin, labels)
        return if labels.empty?

        @bundles[origin] = @bundles.key?(origin) ? @bundles[origin].join(labels) : labels
      end

      def add_declared(origin, labels)
        return if labels.empty?

        @declared_bundles[origin] = @declared_bundles.key?(origin) ? @declared_bundles[origin].join(labels) : labels
      end

      def taint(cause, detail = nil)
        @causes << [cause, detail]
      end

      def walk(node)
        return unless node.is_a?(Prism::Node)
        return if unit_boundary?(node)

        visit(node)
        node.rigor_each_child { |child| walk(child) }
      end

      # A nested unit is recorded and NOT descended into: its body belongs to its own summary, and the
      # enclosing method gets only the `mutate.static` of having defined it.
      def unit_boundary?(node)
        case node
        when Prism::DefNode
          @nested << [node.name.to_s, !node.receiver.nil?, node.body, node.parameters]
          true
        when Prism::CallNode
          declared = self.class.define_method_unit(node)
          return false unless declared

          @nested << declared
          add(DEFINE_METHOD, MUTATE_STATIC)
          true
        else
          false
        end
      end

      def visit(node) # rubocop:disable Metrics/CyclomaticComplexity
        case node
        when Prism::CallNode then visit_call(node)
        when Prism::XStringNode, Prism::InterpolatedXStringNode
          add(XSTRING, IO_PROCESS)
        when Prism::GlobalVariableReadNode
          add(GVAR_READ, GLOBAL_READ) unless FRAME_LOCAL_GLOBALS.include?(node.name.to_s)
        when Prism::GlobalVariableWriteNode, Prism::GlobalVariableOperatorWriteNode,
             Prism::GlobalVariableOrWriteNode, Prism::GlobalVariableAndWriteNode
          add(GVAR_WRITE, GLOBAL_WRITE)
        when Prism::ClassVariableReadNode
          add(CVAR_READ, GLOBAL_READ)
        when Prism::ClassVariableWriteNode, Prism::ClassVariableOperatorWriteNode,
             Prism::ClassVariableOrWriteNode, Prism::ClassVariableAndWriteNode
          add(CVAR_WRITE, MUTATE_STATIC)
        when Prism::InstanceVariableWriteNode, Prism::InstanceVariableOperatorWriteNode,
             Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode
          add(IVAR_WRITE, @singleton ? MUTATE_STATIC : MUTATE_SELF)
        when Prism::AliasMethodNode, Prism::AliasGlobalVariableNode
          add(ALIAS, MUTATE_STATIC)
        when Prism::UndefNode
          add(UNDEF, MUTATE_STATIC)
        when Prism::IndexOperatorWriteNode, Prism::IndexOrWriteNode, Prism::IndexAndWriteNode,
             Prism::CallOperatorWriteNode, Prism::CallOrWriteNode, Prism::CallAndWriteNode
          classify_mutation(node.receiver)
        when Prism::SuperNode, Prism::ForwardingSuperNode
          visit_super
        end
      end

      # `super` in every shape — bare, `super()`, `super(args)`, and each of those inside a block or a
      # rescue, since the walk descends into both (#446).
      #
      # It is a dispatch and must contribute like one. What the scan can settle from the syntax is the
      # *identity* of the target — this unit's own class and selector — and nothing more: which definition
      # sits above the class is a question about the whole project, so it goes out as an edge and the
      # propagator resolves it against the merged ancestry, tainting when nothing there answers.
      #
      # A unit with no class or no name has no target to state. That is not a shape the scanner produces,
      # and the taint is what a "cannot say" must read as rather than a silently dropped call.
      def visit_super
        @delegates_upward = true
        return taint("unresolved-super", @method_name) if @owner_class.nil? || @method_name.nil?

        @edges << FileCollection::Edge.new(
          receiver_class: @owner_class, kind: @singleton ? :singleton : :instance,
          selector: @method_name, self_call: true, super_call: true
        )
      end

      def visit_call(node)
        record = @calls[node]
        attribute(node, record)
        plugin = attribute_plugin(node, record)
        envelope = import_envelope(node, record)
        # A DISCHARGING plugin row bounds the site exactly as an imported envelope does (ADR-103 WD6): a
        # first-party bundled plugin's framework-derived attribution is a trusted claim about a callee the
        # analyzer will never read, so "the receiver was Dynamic" and "no project definition answered" are
        # both already accounted for. `Rails.env` on an app with no Rails RBS is the measured case — the
        # row says what it does, and a `dynamic-receiver` taint beside it would be noise that never clears.
        bound = envelope || (plugin&.discharge? ? plugin : nil)
        visit_uncatalogued(node, record, bound) unless claimed_by_catalogue?(node, record)
        visit_block_argument(node)
      end

      # The **plugin stratum** (#387; ADR-103 WD6 / WD10): what the plugin that models a framework says
      # this call does.
      #
      # It runs beside the catalogue and beside the project's own `effects.attribution:`, for the reason
      # both of those do: three different authorities can each have something true to say about one call,
      # and a summary that reported only the nearest would be less honest, not simpler. What separates it
      # from {#attribute} is the *taint*: a first-party bundled plugin's row is a discharging stratum, so
      # the site stays exhaustive; a third-party plugin's is a claim and taints exactly like the project's
      # own table.
      #
      # Three receiver shapes, tried nearest-syntax first — a written receiver path (`Rails.cache.read`),
      # a receiver rooted at implicit self inside a framework class (`session[:x] = 1`), and the receiver's
      # class through the project's inheritance chain (`user.save`).
      # @return [PluginFacts::Row, nil] the row that claimed this call, for {#visit_call} to read as a bound
      def attribute_plugin(node, record)
        return nil unless @plugin_facts.attributions?

        row = plugin_row(node, record)
        return nil if row.nil?

        labels = row.narrow ? Narrowing.apply(row.narrow, node) : row.labels
        return row if labels.nil? || labels.empty?

        add_declared(Origin.plugin(row.key), labels)
        # A row may discharge AND still taint: `render` states exactly what the CONTROLLER does and says
        # nothing about the template, which is not an effect unit yet (ADR-103 WD11).
        taint(row.taint, row.key) if row.taint
        taint("plugin-attribution", row.key) unless row.discharge?
        row
      end

      def plugin_row(node, record)
        receiver = node.receiver
        selector = node.name.to_s
        path = receiver_path(receiver)
        # Nearest-syntax first, and every shape is TRIED rather than selected: `Rails.cache.read` is a
        # receiver path and nothing else, but `ActiveRecord::Base.connection.execute` is both a receiver
        # path (which no plugin rows) and a call on the result of `ActiveRecord::Base.connection` (which
        # rigor-activerecord does row). Returning on the first shape that *applied* rather than the first
        # that *matched* silently lost the second.
        (path && @plugin_facts.path_row(path, selector)) ||
          (path && @plugin_facts.self_path_row(path, selector, @owner_class)) ||
          class_row_for(node, record, selector) ||
          @plugin_facts.result_row(producer_class(receiver), selector)
      end

      def class_row_for(node, record, selector)
        owner, singleton = envelope_target(node, record)
        @plugin_facts.class_row(owner, singleton, selector)
      end

      # The class whose call produced this receiver, for an `on_result:` row: the constant in
      # `UserMailer.welcome(u).deliver_now`, the receiver class the typer had otherwise. Nil unless the
      # receiver is itself a call with a receiver — a bare local variable says nothing about what made it.
      def producer_class(receiver)
        return nil unless receiver.is_a?(Prism::CallNode)

        inner = receiver.receiver
        return nil if inner.nil?

        Source::ConstantPath.qualified_name(inner) || @calls[receiver]&.receiver_class
      end

      # The receiver expression as the syntax spells it — `"Rails.cache"`, `"self.flash.now"` — or nil when
      # the receiver is not a chain of argument-less sends off a constant or off implicit self. Arguments
      # and blocks disqualify a link: `Rails.cache(x).read` is not the `Rails.cache` a row names, and
      # pretending otherwise would put a proven-looking label on a call nobody wrote.
      def receiver_path(node)
        return nil unless node.is_a?(Prism::CallNode)
        return nil unless node.arguments.nil? && node.block.nil?

        inner = node.receiver
        head =
          if inner.nil? || inner.is_a?(Prism::SelfNode) then SELF_PATH_HEAD
          else
            Source::ConstantPath.qualified_name(inner) || receiver_path(inner)
          end
        head && "#{head}.#{node.name}"
      end

      # The **declared lane at a call site** (#386; ADR-103 WD6). If the callee's own declaration carries
      # an envelope, the bound joins the caller's `≤` lane under an `envelope:` origin, and the returned
      # value is what tells the uncatalogued path the site is bounded rather than unknown.
      #
      # The carrier is nominal and *static*: the class the syntax names for a constant-path receiver, the
      # class the typer projected the receiver to otherwise, and this unit's own class for an
      # implicit-self call — which is the only reason `owner_class` is passed in at all, since
      # {#catalog_target} spells a receiver-less call `Kernel#name`.
      #
      # It runs BESIDE the catalogue, like {#attribute}: a catalogued row states what Ruby's surface
      # proves, an envelope states what the callee promises, and a call that is both reads as both (the
      # rendering rule drops a declared label the proven lane already admits, so the pair never prints
      # twice).
      def import_envelope(node, record)
        return nil if @envelopes.empty?

        owner, singleton = envelope_target(node, record)
        return nil if owner.nil?

        envelope = @envelopes[owner, singleton, node.name.to_s]
        return nil if envelope.nil?

        add_declared(Origin.envelope("#{owner}#{singleton ? '.' : '#'}#{node.name}"), envelope.bound)
        envelope
      end

      # `[owner, singleton]` for the envelope lookup, or `[nil, false]`. Differs from {#catalog_target}
      # in exactly one place, and that place is the point of the method: a receiver-less call resolves
      # against self's ancestry first, so the carrier is the enclosing unit's class rather than the
      # `Kernel` the catalogue reads it as.
      def envelope_target(node, record)
        owner, singleton, implicit = catalog_target(node, record)
        return [@owner_class, @singleton] if implicit

        [owner, singleton]
      end

      # The project's own `effects.attribution:` table, consulted on the same `(owner, selector)` the
      # catalogue is looked up under ({Attribution}).
      #
      # It runs BESIDE the catalogue rather than instead of it, and it never claims the call: attribution
      # answers a different question in a different lane. A catalogued row says what Ruby's own surface
      # proves; an attribution says what the project *claims* about a body Rigor never read, so its labels
      # go to the declared lane and the site keeps a `plugin-attribution` taint — "declared this, and
      # possibly more" (ADR-103 WD6). A call that is both catalogued and attributed honestly reads as both.
      def attribute(node, record)
        return if @attribution.empty?

        owner, singleton, = catalog_target(node, record)
        return if owner.nil?

        key = catalogue_key(owner, singleton, node)
        labels = @attribution[key]
        return if labels.nil?

        add_declared(Origin.attribution(key), labels)
        taint("plugin-attribution", key)
      end

      # The catalogued path. Answers whether the catalogue claimed this call — a claim suppresses the
      # uncatalogued reading, which is what an explicit ∅ row is for.
      #
      # A **row** is authoritative: it states everything that call does, and `mutates: receiver` is how it
      # asks for the ownership judgment on top (`ENV["k"] = v` is `global.write` and deliberately not a
      # receiver mutation; `Time#localtime` is both). A **posture** states nothing about this selector,
      # so the uncatalogued path's own mutation rule applies to it unchanged.
      def claimed_by_catalogue?(node, record)
        owner, singleton, implicit = catalog_target(node, record)
        return false if owner.nil?

        entry = Catalog.default.lookup(
          owner, node.name.to_s, singleton: singleton, call_node: node,
                                 posture: posture_allowed?(node, record, implicit)
        )
        return false if entry.nil?

        add(Origin.catalogue(catalogue_key(owner, singleton, node)), entry.labels) unless entry.labels.empty?
        classify_mutation(node.receiver) if mutating_catalogued?(node, entry, owner)
        push_edge(record, node.name.to_s, implicit) if keeps_project_edge?(entry, implicit)
        true
      end

      # Whether a claimed call still contributes its project edge. Two shapes do, and the summary is
      # then the union of the catalogue's reading and the project definition's:
      #
      # - an IMPLICIT-SELF call, because an unqualified name resolves against self's ancestry first and
      #   a project method of the same name wins at run time. `Kernel#format` is a real row and
      #   `CustomField#format` is a real method, and only the union reads both correctly. (Redmine's
      #   `format.cast_value(…)` is the measured case: the row alone silently cut the callee off.)
      # - a POSTURE answer, which is a class default rather than a statement about this selector, so a
      #   core class the project reopens still propagates its override's summary.
      #
      # An edge that reaches no project definition is dropped by the propagator, so the cost of keeping
      # one is nothing and the cost of dropping one is a missing callee.
      def keeps_project_edge?(entry, implicit)
        entry.posture? || implicit
      end

      def mutating_catalogued?(node, entry, owner)
        entry.mutates_receiver? || (entry.posture? && @mutation.mutating?(node, owner))
      end

      def catalogue_key(owner, singleton, node)
        "#{owner}#{singleton ? '.' : '#'}#{node.name}"
      end

      # Whether the class's default posture may answer here. Three shapes where it may not:
      #
      # - an implicit-self (or `self.`) call, which spells `Kernel#name` and would otherwise colour
      #   every unqualified call in a project body `io`;
      # - a `Dynamic` receiver, where the class the typer projected to is a guess and a default read off
      #   it would be a proven label with nothing proving it (the `dynamic-receiver` taint is the right
      #   answer, and the uncatalogued path records it);
      # - `send` / `call`, whose own taints are the more specific reading ({DEFERRED_SELECTORS}).
      def posture_allowed?(node, record, implicit)
        !implicit && !record&.dynamic && !DEFERRED_SELECTORS.include?(node.name)
      end

      def visit_uncatalogued(node, record, bound = nil)
        return visit_reflective_send(node, record) if REFLECTIVE_SEND.include?(node.name)
        return taint("opaque-callable") if opaque_eval?(node)

        # A write is a write whatever the receiver's type turns out to be, so ownership is classified
        # first and independently of the taints below: `params[:x] = 1` on an untyped `params` is a proven
        # `mutate.instance` *and* a `dynamic-receiver` taint — "this much, and possibly more".
        #
        # Unless a discharging plugin row already stated it. `session[:user_id] = id` is an index write on
        # an object no Rails app declares a type for, so the ownership judgment can only answer "unknown"
        # and taint; the row answers `mutate` + `rails.session.write`, which is both more precise and
        # already trusted.
        classify_mutation(node.receiver) if !plugin_bound?(bound) && @mutation.mutating?(node, record&.receiver_class)

        # `opaque-callable` is checked before `dynamic-receiver` because it is the more specific reading of
        # the same site: a `.call` the analyzer cannot follow to a body says *what* was unfollowable, where
        # a bare Dynamic receiver says only that the receiver's class was unknown.
        return taint("opaque-callable") if opaque_callable?(node, record)
        # **Exhaustive by envelope** (#386). A `Dynamic` receiver whose static facet still names a class
        # whose method carries an envelope is not "callee unknown": whatever object arrives, the bound its
        # declaration states is the upper bound of what this call can do, and that declaration is a
        # discharging stratum (ADR-103 WD6 — the project's own, contract- and Liskov-checked; or an
        # accepted signature, whose types are already trusted). So the site keeps its edges into the
        # project definitions the closed world knows and contributes no taint.
        return record_edge(node, record, bound) if record&.dynamic && bound
        return taint("dynamic-receiver", record.cause) if record&.dynamic

        record_edge(node, record, bound)
      end

      # Whether `bound` is a plugin row rather than an imported envelope. Only the mutation judgment cares
      # about the difference: an envelope bounds what a CALLEE does and says nothing about whether this
      # call mutates its receiver, while a plugin row is written about the call itself.
      def plugin_bound?(bound)
        bound.is_a?(PluginFacts::Row)
      end

      # `send` / `public_send` / `__send__`: a literal selector is an ordinary edge, a computed one is the
      # `dynamic-send` taint.
      def visit_reflective_send(node, record)
        selector = literal_selector(node.arguments&.arguments&.first)
        return taint("dynamic-send") unless selector

        push_edge(record, selector, node.receiver.nil?)
      end

      def literal_selector(node)
        node.unescaped if node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
      end

      # A `.call` the analyzer cannot follow to a body. A call on the unit's own block parameter is
      # forwarding (∅ — the block's effects are accounted at the caller's literal), and a call on a
      # project object resolves as an ordinary edge.
      def opaque_callable?(node, record)
        receiver = node.receiver
        return false unless node.name == :call && receiver
        return false if receiver.is_a?(Prism::LambdaNode)
        return false if receiver.is_a?(Prism::LocalVariableReadNode) && receiver.name.to_s == @block_parameter

        record.nil? || record.receiver_class.nil? || %w[Proc Method].include?(record.receiver_class)
      end

      # The edge is recorded speculatively — only the propagator can say whether `(receiver class,
      # selector)` reaches a project definition — and the taint is decided independently, from the typer's
      # own verdict. The two are not exclusive: a call the typer could not resolve still names a receiver
      # class, and an edge that resolves to nothing is silently dropped rather than tainting, because most
      # such calls are ordinary inherited ones the catalogue simply has no row for.
      def record_edge(node, record, bound = nil)
        self_call = node.receiver.nil?
        push_edge(record, node.name.to_s, self_call)
        return unless self_call && (record.nil? || !record.resolved)
        # An envelope on this unit's own class for the very selector the dispatcher declined is the
        # project declaring the method and stating its bound; a discharging plugin row on the framework
        # base class is the plugin doing the same for a method the framework supplies. `render` inside a
        # controller is the case — the dispatcher rightly declines, because the definition is in Action
        # Pack. There is nothing left to be unsure about that the bound does not already answer.
        return if bound

        taint("unresolved-self-call", node.name.to_s)
      end

      def push_edge(record, selector, self_call)
        return if record.nil? || record.receiver_class.nil?

        @edges << FileCollection::Edge.new(
          receiver_class: record.receiver_class, kind: record.kind, selector: selector, self_call: self_call
        )
      end

      def visit_block_argument(node)
        block = node.block
        return unless block.is_a?(Prism::BlockArgumentNode)

        expression = block.expression
        return if expression.nil? || expression.is_a?(Prism::SymbolNode)
        return if expression.is_a?(Prism::LocalVariableReadNode) && expression.name.to_s == @block_parameter

        taint("opaque-callable")
      end

      def classify_mutation(receiver)
        labels = @mutation.label_for(receiver)
        return taint("unknown-ownership") if labels.nil?

        add(RECEIVER_MUTATION, labels)
      end

      # An `eval` family call carrying code rather than a block, or a bare `binding`. Both hand the
      # analyzer source it will not read; the design note § 5.1 makes them a taint rather than a
      # catalogue row, because there is no upper bound to state.
      def opaque_eval?(node)
        return node.receiver.nil? && node.arguments.nil? if node.name == :binding
        return false unless EVAL_SELECTORS.include?(node.name)

        positional_arity(node).positive?
      end

      # The class the catalogue would look this call up under, as `[owner, singleton, implicit_self]`.
      # Spelled from the syntax where the syntax settles it and from the typer's receiver otherwise;
      # `[nil, …]` when neither does.
      def catalog_target(node, record)
        receiver = node.receiver
        return ["Kernel", false, true] if receiver.nil? || receiver.is_a?(Prism::SelfNode)

        constant = Source::ConstantPath.qualified_name(receiver)
        return [constant, !Catalog.default.object_constant?(constant), false] if constant
        return NO_TARGET if record.nil? || record.receiver_class.nil?

        [record.receiver_class, record.kind == :singleton, false]
      end

      NO_TARGET = [nil, false, false].freeze
      private_constant :NO_TARGET

      def positional_arity(node)
        node.arguments&.arguments&.count { |argument| !argument.is_a?(Prism::KeywordHashNode) } || 0
      end
    end
  end
end
