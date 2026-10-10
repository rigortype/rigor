# frozen_string_literal: true

require "prism"

require_relative "../source/constant_path"
require_relative "../source/node_children"
require_relative "in_effect_refinements/proc_literals"
require_relative "in_effect_refinements/scope_reads"

module Rigor
  module Inference
    # ADR-121 WD1 (issue #1673) — the in-effect refinements of one file: at each program point, the ORDERED list of
    # refining modules whose refinements Ruby applies there (`CONTEXT.md` § in-effect refinements). A later entry
    # wins over an earlier one. The check rules ({Analysis::CheckRules::LexicalMethodSites}) and the typer
    # ({Scope#in_effect_refinements}) both read the one `Inference::ScopeIndexer` stamps for the file, so a call
    # cannot be silenced as refined and typed as unrefined.
    #
    # The list is built from activations, each in effect over a span of the file and placed by its activation
    # offset:
    #
    # - **Lexical `using M`**, from the end of the call to the end of the body that holds it: the file's top level
    #   or a `class` / `module` / `class << …` body, including everything nested in it. An outer body's `using`s
    #   precede an inner body's, and a body's own `using`s keep their textual order. A `using` inside a `def`
    #   raises in Ruby and activates nothing. `M` is resolved lexically: each name its spelling can denote sits at
    #   the `using`'s position, innermost LAST, so where several are declared the one Ruby's lookup finds wins.
    #   The caller's expansion block puts `M`'s included modules ahead of `M` and its prepended modules after it
    #   (issue #1671), as CRuby activates them.
    # - **A `refine X do … end` block**, over the block: its own refining module, after the enclosing `using`s.
    #   The module is named where the block's `self` is: the innermost `module` / `class` body, or the constant a
    #   `M = Module.new do … end` write names. Anywhere else (another block, a `def`, `class << …`, the top
    #   level) the module is not named, and the block contributes {UNKNOWN}.
    # - **A `using` whose argument is not a constant** (`using Module.new { … }`) names no module. It contributes
    #   {UNKNOWN} throughout its file, which is broader than Ruby's scoping and the declining direction.
    # - **Block sources** (ADR-121 WD1's third and fourth). A Proc literal that is directly the receiver of
    #   `Proc#refined` (#1666) — a lambda literal, or the literal block of a bare `proc` / `lambda` call or of
    #   `Proc.new` — puts each `.refined` argument in effect over the literal's body, after the literal's lexical
    #   list and in call order along a `.refined(A).refined(B)` chain (CRuby duplicates the block's cref and appends).
    #   Nested blocks and literals inherit it, being inside the span. An argument that is not a constant names no
    #   module and contributes {UNKNOWN} over that literal's body only. A plugin-declared refined block (#1667) is
    #   typing-time knowledge, so its declared modules arrive as the `declared` argument of {#at} and {#for_node} and
    #   are appended after the block site's lexical list. Both expand through includes as a `using` does.
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

      extend ScopeReads

      def initialize(root)
        @root = root
        @built = false
      end

      # The in-effect refinements at `offset` of this file, ordered so a later activation comes later, each module
      # once at its first position, then `declared` (a block source's modules) on the same terms. The block, when
      # given, answers the modules `using name` puts in effect, in CRuby's activation order, or nil when it cannot
      # tell, which contributes {UNKNOWN}; without it a `using` contributes its own name.
      # The caller vouches that `offset` is in this file; {#for_node} checks.
      def at(offset, declared = EMPTY, &expand)
        build
        return EMPTY if @activations.empty? && declared.empty?

        list = []
        @activations.each do |activation|
          append_activation(list, activation, expand) if activation.covers?(offset)
        end
        declared.each { |name| append_expanded(list, name, expand) }
        list.empty? ? EMPTY : list.freeze
      end

      # {#at} for a node, or only `declared` when `node` is not this file's: a callee body another file wrote,
      # typed under this file's scope, finds no lexical refinement here. Its own file's are not consulted.
      def for_node(node, declared = EMPTY, &)
        return at(EMPTY_OFFSET, declared, &) unless member?(node)

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

      # Does the file activate no refinement anywhere? A consumer asks first, so a file without one pays no list.
      def empty?
        build
        @activations.empty?
      end

      # Issue #1664 — the `Prism::DefNode` a `refine class_name do … end` body in this file defines `method_name` with,
      # for the refining module `module_name`, or nil. The last such `def` wins, as Ruby's method table keeps it. The
      # refined class is matched by any name its spelling can denote, as the refinement table records it.
      def refinement_def(module_name, class_name, method_name)
        build
        @refine_def_nodes.dig(module_name, class_name, method_name)
      end

      # `{refine-body DefNode => Module.nesting where it is written}` for the defs {#refinement_def} answers, which a
      # body re-typed from another file's parse reads its constants by (`DefNodeResolver.refinement_query`).
      def refine_def_nestings
        build
        @refine_def_nestings
      end

      # Is this the query over `root`'s tree?
      def over?(root) = @root.equal?(root)

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
      EMPTY_SET = Set.new.freeze
      EMPTY_TABLE = {}.freeze
      private_constant :EMPTY_OFFSET, :EMPTY_SET, :EMPTY_TABLE

      def append_activation(list, activation, expand)
        names = activation.names
        if names.nil?
          list << UNKNOWN unless list.include?(UNKNOWN)
          return
        end

        # A spelling's candidates are alternatives, innermost first; Ruby's lexical lookup finds the innermost one
        # that exists, so it goes last and wins where several are declared.
        names.reverse_each { |name| append_expanded(list, name, activation.expand && expand) }
      end

      def append_expanded(list, name, expand)
        expanded = expand ? expand.call(name) : [name]
        if expanded.nil?
          list << UNKNOWN unless list.include?(UNKNOWN)
        else
          expanded.each { |entry| list << entry unless list.include?(entry) }
        end
      end

      # Is `node` one this file's parse holds? Prism gives every node of one parse the same `Prism::Source`, so a
      # node another file's parse made answers false in O(1); a node synthesised over this parse's source counts.
      def member?(node)
        node.send(:source).equal?(@root.send(:source))
      end

      def build
        return if @built

        @built = true
        @activations = EMPTY
        @refinement_defs = EMPTY_SET
        @refine_def_nodes = EMPTY_TABLE
        @refine_def_nestings = EMPTY_TABLE
        @chained_refined_calls = nil
        @unresolved_using = false
        return if @root.nil? || !mentions_refinements?

        @activations = []
        @refinement_defs = Set.new
        @refine_def_nodes = {}
        @refine_def_nestings = {}.compare_by_identity
        @nesting = EMPTY
        location = @root.location
        walk(@root, [], [location.start_offset, location.end_offset], false, nil)
        sort_activations
        @activations.freeze
      end

      # `Module.nesting` inside `node`'s body while the block runs, for the refine-body defs recorded there.
      def within_nesting(node)
        outer = @nesting
        @nesting = Source::ConstantPath.pushed_nesting(outer, node.constant_path) || outer
        yield
      ensure
        @nesting = outer
      end

      # A file whose text names neither `using` nor `refine` (`refined` among it) holds none of the activations the walk
      # records, so the scan of the source string spares it the tree walk.
      def mentions_refinements?
        text = @root.send(:source).source
        text.include?("using") || text.include?("refine")
      end

      # `body` is the `[start, end]` of the body a `using` here stays in effect to the end of; `owner` is the name of
      # the module `self` is here, or nil where this walk cannot name it.
      def walk(node, prefix, body, in_def, owner)
        case node
        when Prism::ClassNode, Prism::ModuleNode
          inner = Source::ConstantPath.declaration_prefix(prefix, node.constant_path) || prefix
          return within_nesting(node) do
            walk_children(node.body, inner, span_of(node), false, inner.empty? ? nil : inner.join("::"))
          end
        when Prism::SingletonClassNode
          walk(node.expression, prefix, body, in_def, owner)
          return walk_children(node.body, prefix, span_of(node), false, nil)
        when Prism::DefNode
          return walk_children(node.body, prefix, body, true, nil)
        when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
             Prism::ConstantPathOrWriteNode
          return if walked_meta_new_write?(node, prefix, body, in_def, owner)
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
      def walked_meta_new_write?(node, prefix, body, in_def, owner)
        call = ScopeIndexer.meta_new_block_call(node)
        return false if call.nil? || !ScopeIndexer.module_new_call?(call)

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
        if (target = ScopeIndexer.refine_target(node))
          record_refine_block(node, owner, ScopeIndexer.constant_receiver_candidates(target, prefix))
        elsif using_call?(node) && !in_def
          record_using(node, prefix, body)
        elsif node.name == :refined
          record_refined_chain(node, prefix)
        end
      end

      # By `order`; activations a `.refined` chain recorded share the literal's offset and keep their recording (call)
      # order, so only then does the sort carry the index.
      def sort_activations
        if @chained_refined_calls.nil?
          @activations.sort_by!(&:order)
        else
          @activations = @activations.sort_by.with_index { |activation, index| [activation.order, index] }
        end
      end

      # ADR-121 WD1's `Proc#refined` source (#1666). The walk meets a chain's outermost `.refined` first, so it records
      # the whole chain from the literal outwards — the call order — and marks the inner calls done.
      def record_refined_chain(node, prefix)
        return if @chained_refined_calls&.include?(node)

        @chained_refined_calls ||= Set.new.compare_by_identity
        literal, chain = ProcLiterals.refined_chain(node)
        chain.each { |call| @chained_refined_calls << call }
        return if literal.nil?

        chain.each do |call|
          (call.arguments&.arguments || EMPTY).each do |argument|
            record_block_activation(literal, refined_argument_candidates(argument, prefix))
          end
        end
      end

      # A constant argument's lexical candidates, or nil ({UNKNOWN}) for any other argument: a local, a splat, a call.
      def refined_argument_candidates(argument, prefix)
        return nil unless argument.is_a?(Prism::ConstantReadNode) || argument.is_a?(Prism::ConstantPathNode)

        candidates = ScopeIndexer.constant_receiver_candidates(argument, prefix)
        candidates.empty? ? nil : candidates
      end

      # An activation over a block's body (`block` a `Prism::BlockNode` or `Prism::LambdaNode`) that puts `names` in
      # effect after the block site's lexical list, each expanded through its includes as a `using`'s is; nil names
      # contribute {UNKNOWN}.
      def record_block_activation(block, names)
        start, stop = span_of(block)
        @activations << Activation.new(order: start, start: start, stop: stop, names: names, expand: true,
                                       refine_block: false)
      end

      def record_refine_block(node, owner, targets)
        start, stop = span_of(node.block)
        @activations << Activation.new(order: start, start: start, stop: stop, names: owner && [owner],
                                       expand: false, refine_block: true)
        body = node.block.body
        return if body.nil?

        ScopeIndexer.each_refinement_def(body) do |def_node|
          @refinement_defs << def_node.location.start_offset
          record_refine_def_node(owner, targets, def_node) if owner
        end
      end

      def record_refine_def_node(owner, targets, def_node)
        by_class = (@refine_def_nodes[owner] ||= {})
        targets.each { |class_name| (by_class[class_name] ||= {})[def_node.name] = def_node }
        @refine_def_nestings[def_node] = @nesting
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
