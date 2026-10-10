# frozen_string_literal: true

require "prism"

require_relative "../source/constant_path"
require_relative "../source/node_children"
require_relative "in_effect_refinements/proc_literals"
require_relative "in_effect_refinements/scope_reads"
require_relative "in_effect_refinements/refine_defs"
require_relative "in_effect_refinements/walk"

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
      include Walk

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
        @refine_defs&.lookup(module_name, class_name, method_name)
      end

      # `{refine-body DefNode => Module.nesting where it is written}` for the defs {#refinement_def} answers, which a
      # body re-typed from another file's parse reads its constants by (`DefNodeResolver.refinement_query`).
      def refine_def_nestings
        build
        @refine_defs ? @refine_defs.nestings : {}
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
      private_constant :EMPTY_OFFSET, :EMPTY_SET

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
        @refine_defs = nil
        @chained_refined_calls = nil
        @unresolved_using = false
        return if @root.nil? || !mentions_refinements?

        @activations = []
        @refinement_defs = Set.new
        @refine_defs = RefineDefs.new
        @nesting = EMPTY
        location = @root.location
        walk(@root, [], [location.start_offset, location.end_offset], false, nil)
        sort_activations
        @activations.freeze
      end
    end
  end
end
