# frozen_string_literal: true

require "prism"

require_relative "../source/constant_path"
require_relative "../source/node_children"

module Rigor
  module Inference
    # ADR-121 WD1 (issue #1673) — the in-effect refinements of one file: at each program point, the ORDERED list of
    # refining modules whose refinements Ruby applies there (`CONTEXT.md` § in-effect refinements). A later entry
    # wins over an earlier one. The check rules ({Analysis::CheckRules::LexicalMethodSites}) and the typer
    # ({Scope#in_effect_refinements}) both read this one object, so a call cannot be silenced as refined and typed
    # as unrefined.
    #
    # The list is built from activations, each in effect over a span of the file and placed by its activation
    # offset:
    #
    # - **Lexical `using M`**, from the end of the call to the end of the body that holds it: the file's top level
    #   or a `class` / `module` / `class << …` body, including everything nested in it. An outer body's `using`s
    #   precede an inner body's, and a body's own `using`s keep their textual order. A `using` inside a `def`
    #   raises in Ruby and activates nothing. `M` is resolved lexically, and each name its spelling can denote
    #   sits at the `using`'s position, innermost first. The caller's expansion block puts `M`'s included modules
    #   ahead of `M` (issue #1671), so the includer wins.
    # - **A `refine X do … end` block**, over the block: its own refining module, after the enclosing `using`s.
    #   The module is named where the block's `self` is: the innermost `module` / `class` body, or the constant a
    #   `M = Module.new do … end` write names. Anywhere else (another block, a `def`, `class << …`, the top
    #   level) the module is not named, and the block contributes {UNKNOWN}.
    # - **A `using` whose argument is not a constant** (`using Module.new { … }`, or a path on a computed base,
    #   `using mod::Refinements`) names no module. It contributes {UNKNOWN} throughout its file, which is broader
    #   than Ruby's scoping and the declining direction.
    # - **Block sources** (ADR-121 WD1's third and fourth): a `Proc#refined` literal (#1666) records an activation
    #   over the literal's body from {#block_activation}, which answers none yet; a plugin-declared refined block
    #   (#1667) is typing-time knowledge, so its declared modules arrive as the `declared` argument of {#at} and
    #   {#for_node} and are appended after the block site's lexical list.
    #
    # Activating a module that is already listed changes nothing: it keeps its first position
    # (`rb_using_refinement` returns early, CRuby `eval.c`; `using A; using B; using A` answers B's method).
    #
    # Built lazily: the walk runs the first time a consumer asks, so a file nobody asks about pays one small object.
    class InEffectRefinements
      # The marker an activation contributes when it may put any refinement in effect: a non-constant `using`, a
      # `using` whose include expansion is unknown, or a `refine` block whose module this walk cannot name. A list
      # that carries it answers "any refinement may be in effect"; its position carries no meaning.
      UNKNOWN = :unknown_refinement
      EMPTY = [].freeze

      # One activation: in effect over `[start, stop)`, ordered by `order`. `names` is the module names (several
      # when a lexical spelling can denote several), or nil for {UNKNOWN}; `expand` says whether the caller's
      # include expansion applies (a `using`'s, not a `refine` block's own module).
      Activation = Data.define(:order, :start, :stop, :names, :expand, :refine_block) do
        def covers?(offset) = offset >= start && offset < stop
      end
      private_constant :Activation

      class << self
        # The in-effect refinements at `node` as {Scope#in_effect_refinements} answers them: the file's list from
        # the query `Inference::ScopeIndexer` stamps on the discovery index, each `using` expanded through
        # {.activated_modules}, then `declared`. A scope no index stamped answers `declared` alone.
        def for_node(scope, node, declared = EMPTY)
          query = scope.discovery.in_effect_refinements
          return query.for_node(node, declared) { |name| activated_modules(scope, name) } if query

          declared.empty? ? EMPTY : declared.uniq.freeze
        end

        # Issue #1671 — the modules whose refinements `using name` puts in effect, in activation order: every
        # project module on `name`'s instance-side `Scope::ResolutionChain` (what a module includes and prepends,
        # transitively) deepest first, then `name`, so the includer wins. CRuby's `using_module_recursive` walks
        # the superclass chain to its end before the module itself. Nil, read as "any module may be in effect",
        # when the chain may hold a module it does not list: it was cut at its limit, or a module on it records a
        # mixin the tables cannot name.
        #
        # ADR-46 — the answer reads include edges declared in other files, so it depends on every file that
        # declares a module on the chain, and on the existence of each one's name: a new file reopening `name`, or
        # declaring an included module the project did not declare before, re-checks the consumer through
        # `class:<name>`.
        def activated_modules(scope, name)
          chain = Scope::ResolutionChain.for(scope, name, :instance, :constants)
          record_chain(scope, name, chain) if Analysis::DependencyRecorder.active?
          return nil if chain.truncated? || chain.wildcard_mixin?

          modules = chain.entries.reverse_each.filter_map do |entry|
            entry.name unless entry.external? || entry.name == name
          end
          modules << name
        end

        # Issue #1120 — every module that refines `method_name` into `class_name` or one of its ancestors (a
        # refinement of `Object` reaches a `String` receiver), or nil when none does. The table is empty on a
        # project that refines nothing, which answers without a lookup.
        #
        # ADR-46 — the answer is a function of every refinement of this name in the project, so the consumer
        # depends on the name whichever way it answers; a refine body edited in another file must re-check it
        # (`IncrementalSession#refinement_affected`).
        def refining_modules(scope, class_name, method_name)
          Analysis::DependencyRecorder.read_name(:refinement, method_name) if Analysis::DependencyRecorder.active?
          refinements = scope.discovered_refinements
          return nil if refinements.empty?

          modules = nil
          refinements.each do |refined, methods|
            names = methods[method_name]
            next if names.nil? || !refined_receiver_class?(scope, class_name, refined)

            (modules ||= []).concat(names)
          end
          modules
        end

        private

        def refined_receiver_class?(scope, class_name, refined)
          return true if class_name == refined

          environment = scope.environment
          !environment.nil? && environment.class_ordering(class_name, refined) == :subclass
        end

        def record_chain(scope, name, chain)
          chain.record(scope)
          Analysis::DependencyRecorder.read_last_segment(:class, name)
          chain.entries.each do |entry|
            if entry.external?
              entry.candidates.each { |candidate| Analysis::DependencyRecorder.read_last_segment(:class, candidate) }
            else
              Analysis::DependencyRecorder.read_missing(:class, entry.last_segment)
            end
          end
        end
      end

      def initialize(root)
        @root = root
        @built = false
        @members = nil
      end

      # The in-effect refinements at `offset` of this file, ordered so a later activation comes later, each module
      # once at its first position, then `declared` (a block source's modules) on the same terms. The block, when
      # given, answers the modules `using name` puts in effect, `name` last and its included modules ahead of it,
      # or nil when it cannot tell, which contributes {UNKNOWN}; without it a `using` contributes its own name.
      # The caller vouches that `offset` is in this file; {#for_node} checks.
      def at(offset, declared = EMPTY, &expand)
        build
        list = []
        @activations.each do |activation|
          append_activation(list, activation, expand) if activation.covers?(offset)
        end
        declared.each { |name| list << name unless list.include?(name) }
        list.empty? ? EMPTY : list.freeze
      end

      # {#at} for a node, or only `declared` when `node` is not this file's: a callee body another file wrote,
      # typed under this file's scope, finds no lexical refinement here. Its own file's are not consulted.
      def for_node(node, declared = EMPTY, &)
        build
        return at(EMPTY_OFFSET, declared) unless member?(node)

        at(node.location.start_offset, declared, &)
      end

      # Issue #1120 — is a refinement from one of `modules` (refining-module names) in effect at `offset`? The
      # silencing answer is broader than the list in two places, both the declining direction: a {UNKNOWN} entry
      # counts as every module, and inside a `refine` block every module counts, not only the block's own.
      def refinement_active?(offset, modules, &)
        build
        return true if @unresolved_using
        return true if @activations.any? { |activation| activation.refine_block && activation.covers?(offset) }

        at(offset, &).any? { |name| name == UNKNOWN || modules.include?(name) }
      end

      # Issue #1367 — is any refinement in effect at `offset`?
      def any_at?(offset) = !at(offset).empty?

      # Is `def_node` one of the defs a `refine X do … end` body defines on X? Such a def redefines X's method by
      # design, so X's declared signature for the name is not its contract (issue #1120, maintainer ruling a′).
      def refinement_def?(def_node)
        build
        @refinement_defs.include?(def_node.location.start_offset)
      end

      private

      EMPTY_OFFSET = -1
      private_constant :EMPTY_OFFSET

      def append_activation(list, activation, expand)
        names = activation.names
        if names.nil?
          list << UNKNOWN unless list.include?(UNKNOWN)
          return
        end

        names.each do |name|
          expanded = activation.expand && expand ? expand.call(name) : [name]
          if expanded.nil?
            list << UNKNOWN unless list.include?(UNKNOWN)
          else
            expanded.each { |entry| list << entry unless list.include?(entry) }
          end
        end
      end

      # Is `node` one this file's tree holds? Only nodes inside some activation can answer anything, so only those
      # are collected, by identity, on the first ask.
      def member?(node)
        return false if @activations.empty?

        @members ||= collect_members
        @members.include?(node)
      end

      def collect_members
        members = Set.new.compare_by_identity
        collect_members_in(@root, members)
        members.freeze
      end

      def collect_members_in(node, members)
        location = node.location
        inside = @activations.any? do |activation|
          location.end_offset > activation.start && location.start_offset < activation.stop
        end
        return unless inside

        members << node
        node.rigor_each_child { |child| collect_members_in(child, members) }
      end

      def build
        return if @built

        @built = true
        @activations = []
        @refinement_defs = Set.new
        @unresolved_using = false
        return if @root.nil?

        location = @root.location
        walk(@root, [], [location.start_offset, location.end_offset], false, nil)
        @activations.sort_by!(&:order)
        @activations.freeze
      end

      # `body` is the `[start, end]` of the body a `using` here stays in effect to the end of; `owner` is the name of
      # the module `self` is here, or nil where this walk cannot name it.
      def walk(node, prefix, body, in_def, owner)
        case node
        when Prism::ClassNode, Prism::ModuleNode
          inner = Source::ConstantPath.declaration_prefix(prefix, node.constant_path) || prefix
          return walk_children(node.body, inner, span_of(node), false, inner.empty? ? nil : inner.join("::"))
        when Prism::SingletonClassNode
          walk(node.expression, prefix, body, in_def, owner)
          return walk_children(node.body, prefix, span_of(node), false, nil)
        when Prism::DefNode
          return walk_children(node.body, prefix, body, true, nil)
        when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
             Prism::ConstantPathOrWriteNode
          return if walk_meta_new_write(node, prefix, body, in_def, owner)
        when Prism::BlockNode, Prism::LambdaNode
          return walk_children(node, prefix, body, in_def, nil)
        when Prism::CallNode
          record_call(node, prefix, body, in_def, owner)
        end

        walk_children(node, prefix, body, in_def, owner)
      end

      def walk_children(node, prefix, body, in_def, owner)
        return if node.nil?

        node.rigor_each_child { |child| walk(child, prefix, body, in_def, owner) }
      end

      # `M = Module.new do … end`: the block's `self` is the module the write names, so a `refine` in it refines
      # for `M`. The write's other parts walk as they would anyway.
      def walk_meta_new_write(node, prefix, body, in_def, owner)
        call = ScopeIndexer.meta_new_block_call(node)
        return false if call.nil?

        named = meta_new_owner(node, prefix)
        walk(call.receiver, prefix, body, in_def, owner) if call.receiver
        walk_children(call.arguments, prefix, body, in_def, owner)
        record_call(call, prefix, body, in_def, owner)
        walk_children(call.block, prefix, body, in_def, named)
        true
      end

      def meta_new_owner(node, prefix)
        case node
        when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode then (prefix + [node.name.to_s]).join("::")
        else Source::ConstantPath.declaration_prefix(prefix, node.target)&.join("::")
        end
      end

      def record_call(node, prefix, body, in_def, owner)
        if ScopeIndexer.refine_target(node)
          record_refine_block(node, owner)
        elsif using_call?(node) && !in_def
          record_using(node, prefix, body)
        elsif (names = block_activation(node))
          start, stop = span_of(node.block)
          @activations << Activation.new(order: start, start: start, stop: stop, names: names, expand: true,
                                         refine_block: false)
        end
      end

      # ADR-121 WD1's `Proc#refined` source (#1666): the modules a call whose receiver is a Proc literal activates
      # over the literal's body, in call order, or nil. None yet.
      def block_activation(_node) = nil

      def record_refine_block(node, owner)
        start, stop = span_of(node.block)
        @activations << Activation.new(order: start, start: start, stop: stop, names: owner && [owner],
                                       expand: false, refine_block: true)
        body = node.block.body
        return if body.nil?

        ScopeIndexer.each_refinement_def(body) { |def_node| @refinement_defs << def_node.location.start_offset }
      end

      def using_call?(node)
        node.name == :using && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) &&
          node.arguments&.arguments&.size == 1
      end

      def record_using(node, prefix, body)
        argument = node.arguments.arguments.first
        order = node.location.end_offset
        candidates =
          if argument.is_a?(Prism::ConstantReadNode) || argument.is_a?(Prism::ConstantPathNode)
            ScopeIndexer.constant_receiver_candidates(argument, prefix)
          end
        if candidates && !candidates.empty?
          @activations << Activation.new(order: order, start: order, stop: body.last, names: candidates,
                                         expand: true, refine_block: false)
        else
          @unresolved_using = true
          location = @root.location
          @activations << Activation.new(order: order, start: location.start_offset, stop: location.end_offset,
                                         names: nil, expand: false, refine_block: false)
        end
      end

      def span_of(node)
        location = node.location
        [location.start_offset, location.end_offset]
      end
    end
  end
end
