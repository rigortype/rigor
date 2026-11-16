# frozen_string_literal: true

require "prism"
require_relative "../../reflection"
require_relative "../../scope"
require_relative "../../type"
require_relative "../../inference/object_mixins"
require_relative "../diagnostic"
require_relative "receiver_predicates"

module Rigor
  module Analysis
    module CheckRules
      # ADR-116 WD1 — the `call.undefined-method` rule: an explicit-receiver call whose receiver statically resolves
      # to a class the RBS environment declares and whose method name that class's method table lacks, with every
      # exemption the rule has accumulated (open receivers, project patches, refinements, hook-defined methods,
      # plugin-typed receivers, union and safe-navigation shapes).
      #
      # The one entry point is {.diagnostic}, called by `CheckRules.call_node_diagnostics`. It reads the shared
      # predicates through {ReceiverPredicates} and calls nothing else in `CheckRules`.
      # rubocop:disable-next Metrics/ModuleLength
      module UndefinedMethod
        module_function

        def diagnostic(path, call_node, facts, lexical_sites = nil) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          return nil if call_node.receiver.nil?

          scope = facts.scope
          return nil if scope.nil?

          # The exemptions that hold whatever shape the receiver has. Ahead of the receiver-shape
          # branch below because a plugin is consulted ONCE for the whole receiver, union included, so the
          # gate belongs where that one consult is rather than duplicated into each shape's path.
          #
          # The union side of that placement is reachable. The
          # shape needs a non-nil union of at least two RBS-DECLARED classes — an undeclared arm is an
          # ADR-26 open receiver and `union_arm_blocks_undefined_fire?` bails before the method lookup,
          # which is why the earlier probes read silent and were misread as the gate being unreachable.
          # `spec/integration/composite_receiver_plugin_typed_suppression_spec.rb` builds it. What keeps
          # the gate from firing there today is that the dispatcher no longer records a plugin-typed call
          # it declined (#1101), not that no such union can be built.
          #
          # Note what the gate would do if it were reached: the scalar `Ledger#settle` a plugin declares
          # is exempt here, while `(Ledger | Invoice)#settle` is not, because the union rule's own
          # `method_present_anywhere?` reads RBS and project source and never asks the registry. Closing
          # that asymmetry is #653's union coverage, not this rule's placement.
          # See {#call_site_exempt?}.
          return nil if call_site_exempt?(call_node, scope)

          # N3 — a safe-navigation call (`recv&.m`) never dispatches on the
          # nil edge of its receiver: at runtime it short-circuits to nil.
          # A receiver that types as exactly `nil` yields nil with no call at
          # all, so it is silent (no dead-code diagnostic — `&.` is the
          # nil-skip operator by design, and frightening working
          # `@x = nil; @x&.m` code would breach FP discipline). A nil-bearing
          # *union* receiver is left to flow through unchanged: a `T | nil`
          # union has no single concrete class, so the rule already bails
          # below — preserving that keeps `&.` from newly firing on the
          # non-nil constituent (which, for a cross-file project def, would
          # be a working-code false positive).
          receiver_type = safe_navigation_receiver(call_node, facts.receiver_type)

          # #320 — the private-singleton-object idiom (`class << Merger = Object.new`). The body's methods
          # are recorded on the constant's own name, but the receiver reads back as `Object`, so the
          # class-keyed probes below cannot see them. Recover the name from the receiver syntax. Scoped to
          # the recorded name only: `Merger.nope` still fires.
          return nil if Inference::SingletonObjectConstant.recorded?(call_node, receiver_type, call_node.name, scope)

          # Issue #1699 — judged as its one class; the message still names the union. See
          # {#single_class_literal_union}.
          rendered_receiver = receiver_type
          receiver_type = single_class_literal_union(receiver_type)
          class_name = ReceiverPredicates.concrete_class_name(receiver_type)
          # A union receiver has no single concrete class. The scalar path
          # below cannot reason about it, but the call is still definitely
          # undefined when EVERY arm lacks the method — see
          # `union_undefined_method_diagnostic`.
          if class_name.nil?
            return union_undefined_method_diagnostic(path, call_node, receiver_type, scope, lexical_sites)
          end

          # An unbounded receiver surface: either a plugin-declared
          # open receiver (ADR-26 — e.g. `ActiveRecord::Relation`), or
          # a type Rigor synthesized (a missing-namespace module / a
          # stub for a referenced-but-undeclared type) to keep a
          # malformed project signature buildable. A synthesized stub's
          # method table is empty only because Rigor invented it, not
          # because the real type is empty (the real `DRb` has
          # `start_service`), so enumerating it to prove a call
          # "undefined" would be a false positive.
          return nil if unenumerable_receiver?(receiver_type, class_name, scope)

          # Slice 7 phase 12 — suppress when the user has
          # declared the method in source (`def` /
          # `define_method`) OR in a `pre_eval:` monkey-patch
          # file (ADR-17). Both paths are project-side method
          # contributions the dispatcher already resolved; the
          # rule must not surface a false `undefined-method`
          # for them.
          kind = receiver_type.is_a?(Type::Singleton) ? :singleton : :instance
          return nil if ReceiverPredicates.source_declared_method?(scope, class_name, call_node.name, kind,
                                                                   call_node: call_node)

          return nil unless Rigor::Reflection.rbs_class_known?(class_name, scope: scope)

          # When the loader cannot build a class definition for a
          # name it nominally knows (constant-decl aliases such
          # as `YAML` → `Psych`, or RBS-build failures for
          # malformed signatures), we cannot enumerate methods
          # so we MUST NOT emit a false positive. Skip the rule
          # in that case.
          return nil unless ReceiverPredicates.definition_available?(receiver_type, class_name, scope)

          method_def = ReceiverPredicates.lookup_method(receiver_type, class_name, call_node.name, scope)
          return nil if method_def

          return nil if last_resort_surface_answers?(receiver_type, class_name, call_node, scope, kind, lexical_sites)
          return nil if open_project_singleton?(receiver_type, class_name, call_node, scope)
          return nil if subclass_instance_may_answer?(rendered_receiver, class_name, call_node.name, scope,
                                                      call_node.receiver)

          definition_site = project_definition_site(scope, class_name, call_node.name, kind)
          # Issue #735 — a project `def` on a class the project's own sidecar `sig/` declares is not an ADR-17
          # monkey-patch; see {#project_sidecar_owns_method?}.
          return nil if project_sidecar_owns_method?(scope, class_name, call_node.name, kind)

          build_undefined_method_diagnostic(path, call_node, rendered_receiver, definition_site, class_name)
        end

        # Issue #1717 — an explicit `self.m` / `self.m = v` inside a block whose `self` the engine does not know
        # (`Scope#block_self_unknown?`, set where issue #316's opaque mark is). The receiver still types as the
        # ENCLOSING `self`, but the yielding method may `instance_exec` the block on another object
        # (`ActionController::Renderers.add` runs its block on the controller), so a method missing on the
        # enclosing `self` is no evidence. The implicit `m` in the same block is already silent; the explicit
        # spelling must not be stricter. A block
        # whose `self` IS narrowed (`block_as_methods:`, `define_method`, a `Class.new` body) has cleared the
        # mark and keeps being checked, unless the narrowing was read off an unknown enclosing `self`.
        def unknown_block_self_receiver?(call_node, scope)
          call_node.receiver.is_a?(Prism::SelfNode) && scope.block_self_unknown?
        end

        # Issue #1120 — the method exists at THIS call site but not everywhere: a refinement whose `using` is in
        # effect here, or a `def o.m` on the receiver local in this scope. Asked from {#last_resort_surface_answers?},
        # once every project-wide table has come back "absent", so the file walk behind {LexicalMethodSites} runs
        # only for a call about to fire.
        def lexically_defined_method?(class_name, call_node, scope, kind, lexical_sites)
          return false if lexical_sites.nil?
          return true if lexical_sites.singleton_local_def?(call_node)

          ReceiverPredicates.refined_method_in_effect?(class_name, call_node, scope, kind, lexical_sites)
        end

        # The probes that run only once every cheaper answer has come back "absent", kept together
        # because they share that position and nothing else.
        #
        # - Issue #1120 — a method that exists at this call site only: a refinement in effect here, or a
        #   singleton `def` on the receiver local ({#lexically_defined_method?}).
        # - Issue #739 — an instance-side MODULE receiver. A value typed as a mixin module is an instance of
        #   some class that includes it, and that class contributes an arbitrary surface: inside
        #   `module Attachable::InstanceMethods`, `self.project` is defined by the ActiveRecord model that
        #   includes the module, and in RBS a parameter typed `Taggable` means "something whose class
        #   includes Taggable", not "something whose methods are Taggable's". The surface is not
        #   enumerable, so nothing here can prove a method absent. This probe used to RETRY against Object
        #   — enough for `self.inspect` / `self.class`, and nothing else — which left 45 firings on
        #   redmine's `acts_as_*` mixins the moment a `sig/` declared them.
        #
        #   The union twin already declines these arms outright (`union_arm_blocks_undefined_fire?`, "a
        #   module mixin whose Object-inherited methods the per-arm lookup would miss"). The two rules
        #   answering the same question differently about the same receiver is the fork this closes; the
        #   union's reading is the correct one.
        #
        #   Singleton-side module receivers are NOT covered and must not be: `M.typo` on a namespace module
        #   with `module_function` / `def self.` has a real, enumerable surface and keeps firing.
        # - Issue #723 — the project's own ancestry. Everything above answered "the RBS does not have
        #   it"; a project ancestor still might, and the typer has already resolved the site through
        #   exactly this walk. It sits late because it walks the class graph and so records an ADR-46 ancestry
        #   edge (see {#ancestry_declares_method?} for why that placement is load-bearing, not tidiness).
        # - The other probes are described at their own definitions.
        def last_resort_surface_answers?(receiver_type, class_name, call_node, scope, kind, lexical_sites = nil)
          return true if lexically_defined_method?(class_name, call_node, scope, kind, lexical_sites)
          return true if ReceiverPredicates.project_patched_through_ancestors?(scope, class_name, call_node.name, kind,
                                                                               call_node: call_node)
          return true if ReceiverPredicates.module_mixin_receiver?(receiver_type, scope)
          return true if mixin_self_class_receiver?(call_node, scope)
          return true if unknown_mixin_includer?(class_name, scope, kind)
          return true if ReceiverPredicates.object_mixin_may_define?(receiver_type, class_name, call_node.name, scope)
          return true if ReceiverPredicates.ancestry_declares_method?(scope, class_name, call_node.name, kind)
          return true if open_names_through_ancestors?(scope, class_name, kind)
          return true if foreign_singleton_through_ancestors?(scope, class_name, call_node.name, kind)

          rbs_ancestor_may_answer?(class_name, call_node.name, scope, kind)
        end

        # Issue #2793 — the class, or a project class or module on its chain, carries
        # `Scope::DiscoveryIndex::ENVELOPE_OPEN_NAMES_MARK`: a macro there defines methods under names its syntax
        # does not spell (`def_delegators :@x, *NAMES`), so no name is provably missing. A chain cut at its budget
        # never reaches here: {#ancestry_declares_method?} reads the same chain first and declines on the cut.
        # A non-literal `define_method` records its own side's twin of the mark instead, read beside it here.
        OPEN_NAMES_MARKS = {
          instance: [Scope::DiscoveryIndex::ENVELOPE_OPEN_NAMES_MARK,
                     Scope::DiscoveryIndex::ENVELOPE_OPEN_INSTANCE_NAMES_MARK].freeze,
          singleton: [Scope::DiscoveryIndex::ENVELOPE_OPEN_NAMES_MARK,
                      Scope::DiscoveryIndex::ENVELOPE_OPEN_SINGLETON_NAMES_MARK].freeze
        }.freeze
        private_constant :OPEN_NAMES_MARKS

        def open_names_through_ancestors?(scope, class_name, kind)
          side = kind == :singleton ? :singleton : :instance
          marks = OPEN_NAMES_MARKS.fetch(side)
          chain = Scope::ResolutionChain.for(scope, class_name.to_s, side, :methods)
          # A project class with no `def` of its own is held as an external entry (#2094), so an external's
          # candidate names are asked too.
          found = chain.search(scope) do |entry|
            names = entry.external? ? entry.candidates : [entry.name]
            names.any? do |name|
              bucket = scope.parameter_envelopes_of(name)
              marks.any? { |mark| bucket.key?(mark) } ||
                (side == :instance && (computed_definer_called?(scope, name, bucket) ||
                                       hook_block_macro_defines?(scope, name)))
            end
          end
          !found.nil?
        end

        # Issue #3018 — a class object's singleton method that `def Foo.x`, `Foo.define_singleton_method(:x)` or a
        # `Foo.singleton_class.class_eval` def defines outside `Foo`'s body records no `:singleton` row, only an
        # envelope entry. The class-object path reads the definer's own entry
        # (`Scope::DiscoveryIndex::ENVELOPE_OBJECT_SINGLETON_KIND`) on the chain's class-object entries, the class and
        # its superclasses, so a subclass inherits it. An extended module's entry is instance-side: `extend M` adds
        # `M`'s instance methods, not a `def M.x`. It does not read the opaque `[:singleton, x]` entry beside it, which
        # a name-rewriting class-body macro (`my_attr :x`) files too without defining `x` on the class object.
        def foreign_singleton_through_ancestors?(scope, class_name, method_name, kind)
          return false unless kind == :singleton

          key = [Scope::DiscoveryIndex::ENVELOPE_OBJECT_SINGLETON_KIND, method_name.to_sym]
          chain = Scope::ResolutionChain.for(scope, class_name.to_s, :singleton, :methods)
          found = chain.search(scope, side: :singleton) do |entry|
            names = entry.external? ? entry.candidates : [entry.name]
            names.any? { |name| scope.parameter_envelopes_of(name).key?(key) }
          end
          !found.nil?
        end

        # Issue #2901 — the body of `name` calls, on `self`, a method its singleton chain resolves to a computed
        # definer (`Scope::DiscoveryIndex::ENVELOPE_COMPUTED_DEFINER_KIND`): a class macro of its own, a
        # superclass's or an extended module's, which runs `define_method` under a name no table holds. The first
        # entry on that chain carrying the macro's definer entry answers; a closer override that defines nothing is
        # not looked for, so it leaves the class open.
        #
        # Issue #2975 — the definer entry carries its side: the class's own singleton entry answers with a singleton
        # method (`def self.my_attr`), an extended module's entry with an instance method, so an instance `def my_attr`
        # of the class itself opens nothing. A macro patched onto `Module` (or `Class`, `Object`, `Kernel`,
        # `BasicObject`) as an instance method is on every class object's singleton chain past its own classes.
        def computed_definer_called?(scope, name, bucket)
          macros = bucket.each_key.filter_map do |key|
            key.last if key.is_a?(Array) && key.first == Scope::DiscoveryIndex::ENVELOPE_BODY_CALL_KIND
          end
          return false if macros.empty?

          chain = Scope::ResolutionChain.for(scope, name.to_s, :singleton, :methods)
          found = macros.any? do |macro|
            !chain.search(scope) { |entry| macro_entry_defines?(scope, entry, macro) }.nil? ||
              universal_macro_defines?(scope, macro)
          end
          found || hook_extended_macro_defines?(scope, name, macros)
        end

        # Issue #2975 — a module that a class on `name`'s superclass chain includes or prepends directly, and whose
        # `included` / `prepended` hook extends its includer with a module (`def self.included(base) =
        # base.extend(ClassMethods)`), puts that module's instance methods on `name`'s singleton chain, which records no
        # edge for it. Ruby runs the hook for the direct includer only, so a module included through another module does
        # not count; the chain's levels flatten a class's transitive mixins, so each level class's own mixin list is
        # read, one hop, never followed further. Each mixin and each extended constant resolves to the first candidate
        # the project declares, the innermost cref first, whether or not RBS declares the modules; a concern's
        # `ClassMethods` resolves as `const_get` does instead (#2986).
        def hook_extended_macro_defines?(scope, name, macros)
          definers = macro_definers(macros)
          direct_hook_mixins(scope, name).any? { |mixin, _edges| hook_extension_defines?(scope, mixin, definers) }
        end

        # Issue #2986 — an ActiveSupport::Concern's `included do … end` block runs in the class body of a class that
        # includes the concern directly, and its `prepended do … end` block in one that prepends it, so a macro call
        # in the block is read as that class's own, against the module the concern extends it with. A call in the
        # concern's own module body is no includer's: Ruby raises there as the module loads.
        #
        # Issue #2992 — Ruby runs the block in every direct includer, a module included, so the read is made for each
        # entry of the receiver's chain (`owner`) against that entry's own mixins, one hop. A concern included into a
        # concern after its `extend ActiveSupport::Concern` runs no block there: `Concern#append_features` records it as
        # a dependency, and the outer concern's final includer includes it, on that includer's own edge
        # ({#with_concern_dependencies}). Only a mixin whose one `include` / `prepend` statement is such a dependency
        # is left out of `owner`'s own read: one written ahead of the `extend`, or again in a reopening that may load
        # first, is an ordinary include there.
        def hook_block_macro_defines?(scope, owner)
          own_mixin_edges(scope, owner, deferred: true).any? do |mixin, edges|
            macros = scope.parameter_envelopes_of(mixin).each_key.filter_map do |key|
              key[2] if key.is_a?(Array) && key.first == Scope::DiscoveryIndex::ENVELOPE_HOOK_BODY_CALL_KIND &&
                        edges.include?(Scope::ResolutionChain.effective_hook(scope.discovery, mixin, key[1]))
            end
            !macros.empty? && hook_extension_defines?(scope, mixin, macro_definers(macros))
          end
        end

        def macro_definers(macros)
          macros.map { |macro| [Scope::DiscoveryIndex::ENVELOPE_COMPUTED_DEFINER_KIND, :instance, macro] }
        end

        # Each module a class on `name`'s superclass chain includes or prepends directly, resolved, with the hook
        # blocks its edges run: `:included` for an `include`, `:prepended` for a `prepend`; a concern's dependencies
        # follow it on the same edges.
        def direct_hook_mixins(scope, name)
          chain = Scope::ResolutionChain.for(scope, name.to_s, :instance, :methods)
          chain.record(scope) if Analysis::DependencyRecorder.active?
          chain.level_classes.compact.flat_map { |klass| own_mixin_edges(scope, klass) }
        end

        # The modules `owner` itself includes or prepends, as {#direct_hook_mixins} gives them. With `deferred:`, a
        # provable dependency of a concern `owner` is left out ({#hook_block_macro_defines?}).
        def own_mixin_edges(scope, owner, deferred: false)
          mixins = scope.includes_of(owner)
          prepends = scope.prepends_of(owner)
          deferred_mixins = deferred ? deferred_dependencies(scope, owner, mixins) : NO_DEFERRED
          mixins.uniq.flat_map do |raw|
            mixin = declared_constant(scope, owner, raw)
            next [] unless mixin

            edges = []
            edges << :prepended if prepends.include?(raw)
            edges << :included if mixins.count(raw) > prepends.count(raw)
            next [] if deferred_mixins.include?(raw)

            with_concern_dependencies(scope, mixin).map { |member| [member, edges] }
          end
        end

        NO_DEFERRED = [].freeze
        private_constant :NO_DEFERRED

        # The spellings among `owner`'s mixins that name a concern dependency of `owner`, when `owner` is declared in
        # one file: a reopening may write the same `include` without the `extend`, and load first.
        def deferred_dependencies(scope, owner, mixins)
          sites = scope.discovery.discovered_class_sources[owner.to_s]
          return NO_DEFERRED if sites.nil? || sites.size > 1

          resolver = Scope::ResolutionChain.resolver_for(scope, :methods)
          dependencies = Scope::ResolutionChain.concern_dependencies(scope.discovery, resolver, owner)
          return NO_DEFERRED if dependencies.empty?

          Scope::ResolutionChain.dependency_spellings(scope.discovery, owner).select do |raw|
            mixins.include?(raw) && dependencies.include?(resolver.resolve_declared(owner, raw))
          end
        end

        # Issue #2992 — `mixin` and, when it is a concern, the concerns it includes or prepends, at any depth through
        # concerns ({Scope::ResolutionChain.concern_dependencies}): `Concern#append_features` (or `prepend_features`)
        # includes (or prepends) each of them into the final includer ahead of `mixin` itself, on the includer's own
        # edge to `mixin`, whatever edge each was given. A reader files each one's sites as it reads its envelopes.
        def with_concern_dependencies(scope, mixin)
          resolver = Scope::ResolutionChain.resolver_for(scope, :methods)
          [mixin, *Scope::ResolutionChain.concern_dependencies(scope.discovery, resolver, mixin)]
        end

        def hook_extension_defines?(scope, mixin, definers)
          hook_extends(scope, mixin).any? do |written, lookup|
            target = if lookup == :const_get then const_get_constant(scope, mixin, written)
                     else declared_constant(scope, mixin, written)
                     end
            record_hook_target_edges(scope, mixin, written, lookup) if Analysis::DependencyRecorder.active?
            target && definers.any? { |definer| scope.parameter_envelopes_of(target).key?(definer) }
          end
        end

        # Issue #2992 — the read depends on the extended module's files whether or not it resolved: an empty
        # `module ClassMethods; end` is no project class yet, and the edit that gives it the definer makes it one. So
        # every name the lookup tried files its declaring sites, and the constant's last segment its negative class
        # edge, which a NEW file declaring it fires.
        def record_hook_target_edges(scope, mixin, written, lookup)
          candidates = if lookup == :const_get
                         chain = Scope::ResolutionChain.for(scope, mixin, :instance, :methods)
                         chain.entries.flat_map { |entry| entry.external? ? entry.candidates : [entry.name] }
                              .map { |name| "#{name}::#{written}" } << written
                       else
                         own = written.start_with?("::") ? [] : ["#{mixin}::#{written}"]
                         own + scope.ancestor_name_candidates(mixin, written)
                       end
          candidates.each { |candidate| Scope::ResolutionChain.record_class(scope, candidate.delete_prefix("::")) }
          Analysis::DependencyRecorder.read_last_segment(:class, written)
        end

        # The constant `raw`, written in `owner`'s body, as the first candidate the project declares: `Owner::Raw`
        # first, since `owner` is the innermost cref there, then the enclosing namespaces. Nil when none is declared.
        def declared_constant(scope, owner, raw)
          candidates = scope.ancestor_name_candidates(owner, raw)
          candidates = ["#{owner}::#{raw}", *candidates] unless raw.start_with?("::")
          candidates.find { |candidate| scope.known_user_class?(candidate) }
        end

        # Issue #2986 — `owner.const_get(raw)`, as `Concern#append_features` looks `ClassMethods` up: `owner` and its
        # ancestors, then `Object`, never the namespaces enclosing `owner`. Issue #2997 — a `class_methods` block's
        # `Name::ClassMethods` counts only for a concern `Name` ({Scope::ResolutionChain.const_get_candidate?}).
        def const_get_constant(scope, owner, raw)
          chain = Scope::ResolutionChain.for(scope, owner, :instance, :methods)
          found = chain.search(scope) do |entry|
            names = entry.external? ? entry.candidates : [entry.name]
            names.map { |name| [name, "#{name}::#{raw}"] }.find do |name, candidate|
              scope.known_user_class?(candidate) &&
                Scope::ResolutionChain.const_get_candidate?(scope.discovery, name, candidate)
            end&.last
          end
          found || (raw if scope.known_user_class?(raw))
        end

        # The `[written, lookup]` pairs of a module's hook-extend entries; `lookup` is `:const_get` for a concern's.
        # Issue #3005 — a gated concern-block entry counts only for a concern `owner`.
        def hook_extends(scope, owner)
          scope.parameter_envelopes_of(owner).each_key.filter_map do |key|
            next unless key.is_a?(Array) && key.first == Scope::DiscoveryIndex::ENVELOPE_HOOK_EXTEND_KIND
            next unless Scope::ResolutionChain.effective_hook(scope.discovery, owner, key[2])

            key[1, 2]
          end
        end

        # A macro's owner holds the macro's `def`, so it is never an external entry.
        def macro_entry_defines?(scope, entry, macro)
          !entry.external? &&
            scope.parameter_envelopes_of(entry.name).key?([Scope::DiscoveryIndex::ENVELOPE_COMPUTED_DEFINER_KIND,
                                                           entry.side, macro])
        end

        # The classes past a class object's own singleton chain, whose instance methods it answers. A module's chain
        # does not reach `Class`, but a module body calling a `Class` macro raises as it loads, so it is not told apart.
        UNIVERSAL_MACRO_OWNERS = %w[Class Module Object Kernel BasicObject].freeze
        private_constant :UNIVERSAL_MACRO_OWNERS

        def universal_macro_defines?(scope, macro)
          definer = [Scope::DiscoveryIndex::ENVELOPE_COMPUTED_DEFINER_KIND, :instance, macro]
          UNIVERSAL_MACRO_OWNERS.any? { |owner| scope.parameter_envelopes_of(owner).key?(definer) }
        end

        # Issue #1722 — a `method_missing`, or a project mixin, on one of the class's RBS ancestors
        # ({RbsReceiverSurface}). Last for {#ancestry_declares_method?}'s reason: it walks the class graph.
        # Issue #2792 — a `method_missing` RBS declares on the class or an ancestor, other than the universal one.
        def rbs_ancestor_may_answer?(class_name, method_name, scope, kind)
          side = kind == :singleton ? :singleton : :instance
          return true if RbsReceiverSurface.rbs_missing_hook?(scope, class_name, side)

          if kind == :singleton
            RbsReceiverSurface.singleton_hook?(scope, class_name) ||
              RbsReceiverSurface.singleton_mixin_may_answer?(scope, class_name, method_name)
          else
            RbsReceiverSurface.ancestor_may_answer?(scope, class_name, method_name)
          end
        end

        # Issue #1722 — a receiver typed by its class's name, rather than by a literal, may hold an instance of a
        # subclass (a `#: () -> String` signature admits a `MyStr < String`), so a method a project subclass
        # defines, or a subclass's `method_missing`, may be the one that runs. A value the engine built from a
        # literal is exactly its class and keeps firing: a literal type (`"a"`, `1`, a union of them), a shape
        # carrier (`{a: 1}`, `[1, 2]`, `{}`, `[]`, and what folds to one), or a receiver written as a literal
        # (`"a#{x}b"`, which types as plain `String`). A local holding an interpolated String types as plain
        # `String` with no origin, so it still declines. Instance side only.
        def subclass_instance_may_answer?(receiver_type, class_name, method_name, scope, receiver_node = nil)
          return false if receiver_type.is_a?(Type::Singleton)
          return false if exact_literal_receiver?(receiver_type) || LITERAL_RECEIVER_NODES.include?(receiver_node.class)

          RbsReceiverSurface.subclass_may_define?(scope, class_name, method_name)
        end

        EXACT_TYPES = [Type::Constant, Type::Tuple, Type::HashShape].freeze
        LITERAL_RECEIVER_NODES = [
          Prism::StringNode, Prism::InterpolatedStringNode, Prism::XStringNode, Prism::InterpolatedXStringNode,
          Prism::ArrayNode, Prism::HashNode, Prism::RegularExpressionNode, Prism::InterpolatedRegularExpressionNode
        ].to_set.freeze
        private_constant :EXACT_TYPES, :LITERAL_RECEIVER_NODES

        def exact_literal_receiver?(receiver_type)
          members = receiver_type.is_a?(Type::Union) ? receiver_type.members : [receiver_type]
          members.all? { |member| EXACT_TYPES.any? { |kind| member.is_a?(kind) } }
        end

        # Issue #739 — the singleton twin of the module-mixin receiver, and the only shape that reaches the
        # singleton side legitimately. `self.class` inside a mixin's instance method is the INCLUDER's class
        # at runtime; the engine types it `Singleton[<the module>]`, one hop along from the same wrong
        # `self`. redmine's `acts_as_*` mixins reach their configuration that way
        # (`self.class.attachable_options`), 17 sites of it.
        #
        # Keyed on the call-site SYNTAX rather than on the receiver type, because `Singleton[M]` is also
        # what a namespace module's own `M.helper` produces, and that surface is real and enumerable — a
        # type-only test would silence every `M.typo` in the project. Here the question is narrower: was
        # this singleton produced by `.class` on a value whose type is a mixin module?
        def mixin_self_class_receiver?(call_node, scope)
          receiver = call_node.receiver
          return false unless receiver.is_a?(Prism::CallNode) && receiver.name == :class
          return false unless receiver.arguments.nil?

          inner = receiver.receiver
          return false if inner.nil?

          ReceiverPredicates.module_mixin_receiver?(scope.type_of(inner), scope)
        end

        # ADR-17 — when the project itself defines this method on the
        # receiver class somewhere in the analyzed file set (a reopened
        # core/stdlib/gem class the dispatcher does not apply cross-
        # file), return that `"path:line"` site so the diagnostic points
        # at `pre_eval:` instead of reading as a bare unresolved call.
        # Instance-side only (the cross-file def-source index tracks
        # `def` instance methods); the diagnostic still fires — Rigor
        # does not auto-apply project monkey-patches (the full-project
        # pre-pass is deferred per ADR-17 slice 5) — but it is now
        # actionable rather than mistakable for a typo.
        def project_definition_site(scope, class_name, method_name, kind)
          return nil unless kind == :instance

          scope.user_def_site_for(class_name, method_name)
        end

        # Issue #735 — the site is evidence, and whose RBS the class has decides what it is evidence OF. On
        # a BUNDLED declaration (core / stdlib / a gem) the class is not the project's, so a project `def`
        # on it is the ADR-17 monkey-patch this rule surfaces with the `pre_eval:` nudge. On the project's
        # OWN sidecar `sig/` the declaration describes the source being analysed, the "patch" is just
        # another of the project's files, and the nudge is not something a user can act on: it asks them to
        # `pre_eval:` their own application. `rigor sig-gen --write` on redmine turned 29
        # `call.undefined-method` into 171 through exactly this reading, 49 of them here.
        def project_sidecar_owns_method?(scope, class_name, method_name, kind)
          Rigor::Reflection.project_declared_class?(class_name, scope: scope) &&
            ReceiverPredicates.project_defines_method?(scope, class_name, method_name, kind)
        end

        # Issue #742 — the receivers whose method surface this rule cannot enumerate, in one question.
        #
        # {#unbounded_receiver_surface?} covers the ADR-26 open receivers and Rigor's own synthesized stubs.
        # The generic metaclasses join it here: a value typed `Class` or `Module` is SOME class or module
        # object, and its singleton methods cannot be read off the metaclass — `def self.included(base)`
        # receives the includer, so `base.class_attribute :main_menu` and `base.main_menu = true` are calls
        # on whatever included the module. The union twin has declined these arms since it was written
        # (`METACLASS_ARMS`, "a `plugin_class : Class` really holds a `Plugin` subclass with `.manifest`");
        # the scalar rule enumerated `Module`'s own RBS instead and reported them.
        #
        # Kept beside `unbounded_receiver_surface?` rather than folded into it: that predicate has other
        # callers, and #742 had no evidence that any of them spoke on these receivers.
        #
        # Issue #879 supplied it for exactly one — `call.wrong-arity`, which decided `v.hexdigest(1, 2, 3)`
        # against `Digest::Instance`'s declaration on the same run where `v.no_such_method_zzz` was declined
        # as unenumerable. One receiver, one run, two answers about whether that surface can be read. The
        # reporter could make no other caller speak: `raise` on a module- or `Class`-typed operand is silent,
        # and `Class`-typed `.new` with a wrong arity is silent too, so the other callers stay on
        # `unbounded_receiver_surface?` until something demonstrates otherwise.
        #
        # Arity takes {#unenumerable_receiver_shape?}, not this whole predicate: ADR-26's open receivers are
        # handled for the signature-reading rules by {#unauthoritative_inherited_signature?}, which is
        # deliberately narrower — a method the open class DECLARES itself keeps its arity check.
        def unenumerable_receiver?(receiver_type, class_name, scope)
          ReceiverPredicates.unenumerable_receiver_shape?(receiver_type, class_name, scope) ||
            ReceiverPredicates.unbounded_receiver_surface?(class_name, scope)
        end

        # Issue #746 — a class that includes a module the environment does not know. `SudoMode::Form`
        # includes `ActiveModel::Validations`, which no RBS in redmine's environment declares, and `valid?`
        # comes from it: the ancestors are not fully known, so the method table is not enumerable and a
        # verdict read off the part we can see is unsound. Same reasoning `unbounded_receiver_surface?`
        # already applies to an ADR-26 open receiver and to Rigor's own synthesized stubs.
        #
        # Asked LATE, with {#ancestry_declares_method?} and for the same reason: `Scope#includes_of` records
        # an ADR-46 file-level ancestry edge, so running it on the hot path made `Widget.new` — a call RBS
        # answers, that never reaches a verdict — depend on `Widget`'s declaring file.
        # `dependency_recorder_spec` caught it here exactly as it caught #723's walk.
        #
        # A constant the environment does not know is read off the receiver's OWN includes only. Issue #2991 — a
        # mixin no name spells (`include(*MODS)`, `include helper`) opens the receiver when it sits anywhere on its
        # instance-side chain, its own level or an ancestor's: the chain marks it (`ResolutionChain#unnamed_mixin?`),
        # and any name may come from the unlisted module (a hook's `base.include M` is read so too). `self.include M`
        # and a receiverless `send(:include, M)` are recorded as `include M` is (#2995), so the ordinary lookup reads
        # `M`. A mixin whose ORDER alone is unknown (`include M; prepend M`) has its module recorded, so it opens
        # nothing. A class-object receiver reads its singleton chain instead ({#singleton_mixin_may_answer?}).
        def unknown_mixin_includer?(class_name, scope, kind)
          includes = scope.includes_of(class_name)
          return true if includes.any? { |raw| !known_mixin?(raw, class_name, scope) }
          return false if kind == :singleton

          Scope::ResolutionChain.for(scope, class_name.to_s, :instance, :methods).unnamed_mixin?
        end

        def known_mixin?(raw_name, class_name, scope)
          scope.ancestor_name_candidates(class_name, raw_name).any? do |candidate|
            next true if scope.discovered_classes.key?(candidate)

            Rigor::Reflection.rbs_class_known?(candidate, scope: scope) &&
              !ReceiverPredicates.synthesized_stub_receiver?(candidate, scope)
          end
        end

        # Issue #2438 — a class-method call on a class the project's own signatures name but whose source leaves
        # the singleton surface open. Before `rigor sig-gen --write` such a class was source-only and an
        # unresolved call on it was silent; the sidecar must not turn the same call into a finding. Two shapes:
        #
        # - `C.instance` where `C`, or a project class up its superclass chain, `include`s the stdlib `Singleton`:
        #   the answer is `SingletonMixinDispatch.answers?`, the predicate the typer itself uses, so the rule never
        #   reports a call the engine typed. The class's other members are irrelevant: the mixin's hook defines
        #   `instance`.
        # - every project declaration of `C` is member-less (`RbsLoader#memberless_project_class?`) AND the source
        #   leaves `C` open ({#open_source_class?}). A member-less declaration does not describe the class's
        #   surface, but a class whose whole definition Rigor can see in `paths:` is still closed, so a typo on it
        #   keeps firing. Instance-side calls keep being checked; declaring any member re-closes the class.
        def open_project_singleton?(receiver_type, class_name, call_node, scope)
          return false unless receiver_type.is_a?(Type::Singleton)
          return true if Inference::MethodDispatcher::SingletonMixinDispatch.answers?(
            scope, receiver_type, call_node.name, call_node.arguments.nil?
          )

          loader = scope.environment&.rbs_loader
          return false if loader.nil? || !loader.respond_to?(:memberless_project_class?)

          loader.memberless_project_class?(class_name) && open_source_class?(class_name, scope, loader)
        end

        OPENING_HOOKS = %i[inherited included extended prepended method_missing respond_to_missing?].freeze
        private_constant :OPENING_HOOKS

        CLOSED_ROOTS = Set["Object", "BasicObject"].freeze
        private_constant :CLOSED_ROOTS

        # Issue #2438 — whether a class's singleton surface may hold methods its source in `paths:` does not show,
        # read off `Scope::ResolutionChain` (`:constants` flavor, so a project module that holds only constants is
        # still a project entry). Open when the class, or a project class up its superclass chain:
        #
        # 1. `extend`s a module (any singleton-side entry beyond the classes' own singletons), or records an
        #    `inherited` / `included` / `extended` / `prepended` hook or `method_missing` / `respond_to_missing?`.
        #    A plain `include` or `prepend` adds instance methods only, so it leaves the singleton side closed;
        # 2. has no `class` / `module` body of its own inside `paths:` (`class Ext::Foo` names `Ext` without one);
        # 3. or the chain reaches a class the project does not define, other than `Object` / `BasicObject`: an
        #    external superclass (`ApplicationRecord < ActiveRecord::Base`, `MyError < StandardError`), a
        #    superclass written as an expression, or — where the source writes no superclass for the last class —
        #    the superclass its member-less declaration writes, unless that is a project class.
        #
        # A definition or reopening in a file outside `paths:` cannot be seen, so a class whose body is inside
        # `paths:` and whose methods live only outside it counts as closed.
        def open_source_class?(class_name, scope, loader)
          name = class_name.to_s.delete_prefix("::")
          instance = Scope::ResolutionChain.for(scope, name, :instance, :constants)
          singleton = Scope::ResolutionChain.for(scope, name, :singleton, :constants)
          [instance, singleton].each { |chain| chain.record(scope) }
          classes = instance.level_classes.compact
          return true if classes.empty? || instance.truncated?

          sources = scope.discovered_class_sources
          return true if classes.any? { |klass| (sources[klass] || []).empty? || opening_hook?(klass, scope) }
          return true if opening_entry?(instance, classes, mixins: false) ||
                         opening_entry?(singleton, classes, mixins: true)

          open_tail?(instance, classes.last, scope, loader)
        end

        # An external superclass other than `Object` / `BasicObject` opens either side; a module entry opens the
        # chain only where `mixins` is set (the singleton side, where it is an `extend`).
        def opening_entry?(chain, classes, mixins:)
          chain.entries.any? do |entry|
            if entry.external? && entry.superclass_edge
              !CLOSED_ROOTS.include?(entry.raw.to_s.delete_prefix("::"))
            else
              mixins && !classes.include?(entry.name)
            end
          end
        end

        def opening_hook?(klass, scope)
          OPENING_HOOKS.any? do |hook|
            scope.discovered_method?(klass, hook, :singleton) || scope.discovered_method?(klass, hook, :instance)
          end
        end

        # The last class's own superclass, which the chain does not name: an expression the tables cannot resolve,
        # or one only the member-less declaration writes (the chain ends at the implicit `Object` exactly when
        # the source writes none).
        def open_tail?(chain, last, scope, loader)
          return true if chain.opaque_tail?(scope)

          raw = loader.memberless_project_superclass(last)
          return false if raw.nil? || CLOSED_ROOTS.include?(raw.delete_prefix("::"))

          !scope.discovered_classes.key?(raw.delete_prefix("::"))
        end

        # The `call.undefined-method` exemptions that depend only on the CALL SITE, never on the receiver's
        # type or class — so they are decided before the rule looks at the receiver at all:
        #
        # - ADR-67 WD6b — an inferred-parameter receiver's type is an open-call-site lower bound, so firing
        #   undefined-method against it is a false positive by construction.
        # - Issue #653 — a plugin answered this call site ({#plugin_typed_call?}).
        # - Issue #1717 — an explicit `self` receiver in a block whose `self` is unmodelled
        #   ({#unknown_block_self_receiver?}).
        def call_site_exempt?(call_node, scope)
          ReceiverPredicates.inferred_param_receiver?(call_node, scope) ||
            ReceiverPredicates.plugin_typed_call?(call_node, scope) ||
            unknown_block_self_receiver?(call_node, scope)
        end

        # The receiver type the `call.undefined-method` existence check
        # should reason about. For a safe-navigation call whose receiver
        # types as exactly `nil`, this is `Type::Bot` — the call is
        # statically skipped at runtime, and `concrete_class_name(Bot)` is
        # nil so the rule bails (silent). Every other receiver (including a
        # `T | nil` union, which already has no single concrete class) flows
        # through unchanged.
        def safe_navigation_receiver(call_node, receiver_type)
          return receiver_type unless call_node.safe_navigation?
          return receiver_type unless ReceiverPredicates.nil_member?(receiver_type)

          Type::Combinator.bot
        end

        # Teeth on a *union* receiver. The scalar `undefined_method_diagnostic`
        # bails when the receiver has no single concrete class; here we fire
        # when EVERY non-nil arm is a fully-known, bounded, instance class on
        # which the method is absent — the call is then undefined regardless of
        # which arm the value takes at runtime (`A | B` responds to `m` only if
        # both `A` and `B` do). FP-safe by construction: `method_present_anywhere?`
        # returns "present" for any Dynamic / unknown / unbuildable /
        # source-declared arm, so the `any?` short-circuits and we never fire on
        # uncertainty; `union_arm_blocks_undefined_fire?` additionally bails on
        # any open (ADR-26) / synthesized / singleton / module-mixin arm. This is
        # no more aggressive than the scalar rule — it just applies the same
        # certainty test to each arm.
        #
        # Nil-bearing unions are deferred: their nil arm interacts with the
        # `possible-nil-receiver` rule, safe-navigation, and ADR-58
        # declaration-sourced nil. Slice 1 handles pure non-nil unions
        # (e.g. `String | Symbol`).
        def union_undefined_method_diagnostic(path, call_node, receiver_type, scope, lexical_sites = nil)
          return nil unless receiver_type.is_a?(Type::Union)
          return nil if call_node.safe_navigation?

          members = receiver_type.members
          # Nil-bearing unions (`T | nil`) stay silent — the deliberate N3
          # decision (`safe_navigation_undefined_method_spec.rb`). A corpus FP
          # study of a bundled-arm-narrowed candidate (12 projects incl.
          # ActiveSupport-heavy) found ~zero real firings yet a demonstrated
          # loss-of-specificity false positive, so the silence is kept. See
          # ADR-62 and `docs/notes/20260613-mutation-teeth-harness.md`.
          return nil if members.any? { |member| ReceiverPredicates.nil_member?(member) }
          return nil if members.any? { |member| union_arm_blocks_undefined_fire?(member, scope) }
          # Only a genuinely multi-class union ("the value is an A or a B") gains
          # from this rule. A union whose arms all resolve to ONE class
          # (`Hash[K1, V1] | Hash[K2, V2]`) is a shape-join artifact — checking
          # method existence there is the scalar rule's job, and when the join is
          # a misinference it is a false positive (a corpus probe caught mail's
          # `compose_codepoints` typed `Hash | Hash` for an `Array`, flagging
          # `.pack`). Require at least two distinct arm classes.
          return nil if members.map { |member| ReceiverPredicates.concrete_class_name(member) }.uniq.size < 2
          return nil if union_may_answer?(members, call_node, scope, lexical_sites)

          build_undefined_method_diagnostic(path, call_node, receiver_type)
        end

        # Whether some arm of a non-nil union of classes may answer the call, which keeps the union rule silent.
        def union_may_answer?(members, call_node, scope, lexical_sites)
          return true if members.any? do |member|
            ReceiverPredicates.method_present_anywhere?(member, call_node.name, scope)
          end
          return true if members.any? { |member| arm_surface_may_answer?(member, call_node.name, scope) }
          # Issue #1722 — `def o.m`, `o.extend(M)` and their kin give the one object the method, whatever its class.
          return true if lexical_sites&.singleton_local_def?(call_node)

          refined_on_some_arm?(members, call_node, scope, lexical_sites)
        end

        # Issue #1722 — the scalar rule's RBS-ancestor and subclass declines, asked of one arm. Kept out of
        # {#method_present_anywhere?}, which `call.possible-nil-receiver` also asks: there a "present" answer is
        # what lets the rule fire, and a `method_missing` on `Object` answers on the `nil` arm too.
        def arm_surface_may_answer?(member, method_name, scope)
          class_name = ReceiverPredicates.concrete_class_name(member)
          rbs_ancestor_may_answer?(class_name, method_name, scope, :instance) ||
            subclass_instance_may_answer?(member, class_name, method_name, scope)
        end

        # ADR-121 WD7 — a refinement in effect (or one Rigor cannot read) may define the name on one arm's class.
        def refined_on_some_arm?(members, call_node, scope, lexical_sites)
          members.any? do |member|
            kind = member.is_a?(Type::Singleton) ? :singleton : :instance
            ReceiverPredicates.refined_method_in_effect?(ReceiverPredicates.concrete_class_name(member), call_node,
                                                         scope, kind, lexical_sites)
          end
        end

        # Issue #1699 — a union of one class's literals, alone or beside that class's plain nominal
        # (`0 | Integer`, which `gets.to_i` types; `"a" | "b"`; `1 | 2`), holds nothing but instances of
        # that class, so it answers a method-existence question exactly as the class does. The union rule
        # above declines it through its distinct-class guard, which exists for SHAPE joins
        # (`Hash[K1, V1] | Hash[K2, V2]`, a corpus misinference on mail), and the scalar rule declined it
        # for having no single concrete class, so neither judged it. Returns that class's nominal, or `type`
        # itself. Literal-and-plain-nominal arms only: a generic, shape or refinement arm keeps the union
        # declined, and so does a union spanning two classes.
        def single_class_literal_union(type)
          return type unless type.is_a?(Type::Union)

          members = type.members
          return type unless members.any?(Type::Constant)
          return type unless members.all? do |member|
            member.is_a?(Type::Constant) || (member.is_a?(Type::Nominal) && member.type_args.empty?)
          end

          class_names = members.map { |member| ReceiverPredicates.concrete_class_name(member) }.uniq
          return type unless class_names.size == 1

          class_name = class_names.first
          return type if class_name.nil? || class_name == "NilClass"

          Type::Combinator.nominal_of(class_name)
        end

        def union_arm_blocks_undefined_fire?(member, scope)
          class_name = ReceiverPredicates.concrete_class_name(member)
          return true if class_name.nil?
          return true if member.is_a?(Type::Singleton)
          return true if ReceiverPredicates::METACLASS_ARMS.include?(class_name)
          return true if ReceiverPredicates.unbounded_receiver_surface?(class_name, scope)

          ReceiverPredicates.module_mixin_receiver?(member, scope)
        end

        def build_undefined_method_diagnostic(path, call_node, receiver_type, definition_site = nil, class_name = nil)
          rendered_receiver = receiver_type.describe
          message = "undefined method `#{call_node.name}' for #{rendered_receiver}"
          # ADR-17 — when the project itself defines this method on the
          # receiver class somewhere in the file set, name the site and
          # point at `pre_eval:`. Rigor does not apply project monkey-
          # patches cross-file automatically, so the diagnostic still
          # fires, but the enriched message makes it actionable (and
          # `rigor triage` keys on the structured `project_definition_site`
          # field to recommend `pre_eval:` with high confidence).
          if definition_site
            def_owner = class_name || rendered_receiver
            message += "; the project defines `#{def_owner}##{call_node.name}' at " \
                       "#{definition_site} — Rigor does not apply project monkey-patches " \
                       "cross-file; list that file in `.rigor.yml`'s `pre_eval:` (ADR-17)"
          end
          Diagnostic.from_message_loc(
            call_node,
            rule: RULE_UNDEFINED_METHOD,
            path: path,
            message: message,
            severity: :error,
            receiver_type: rendered_receiver,
            method_name: call_node.name.to_s,
            project_definition_site: definition_site
          )
        end

        private_class_method :unknown_block_self_receiver?, :lexically_defined_method?, :last_resort_surface_answers?,
                             :open_names_through_ancestors?, :foreign_singleton_through_ancestors?,
                             :computed_definer_called?, :hook_extended_macro_defines?, :hook_block_macro_defines?,
                             :macro_definers, :direct_hook_mixins, :own_mixin_edges, :deferred_dependencies,
                             :with_concern_dependencies, :hook_extension_defines?, :record_hook_target_edges,
                             :declared_constant, :const_get_constant, :hook_extends, :macro_entry_defines?,
                             :universal_macro_defines?, :rbs_ancestor_may_answer?, :subclass_instance_may_answer?,
                             :exact_literal_receiver?, :mixin_self_class_receiver?, :project_definition_site,
                             :project_sidecar_owns_method?, :unenumerable_receiver?, :unknown_mixin_includer?,
                             :known_mixin?, :open_project_singleton?, :open_source_class?, :opening_entry?,
                             :opening_hook?, :open_tail?, :call_site_exempt?, :safe_navigation_receiver,
                             :union_undefined_method_diagnostic, :union_may_answer?, :arm_surface_may_answer?,
                             :refined_on_some_arm?, :single_class_literal_union, :union_arm_blocks_undefined_fire?,
                             :build_undefined_method_diagnostic
      end
    end
  end
end
