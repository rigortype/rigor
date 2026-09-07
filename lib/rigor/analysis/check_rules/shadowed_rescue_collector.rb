# frozen_string_literal: true

require "prism"

require_relative "../../reflection"
require_relative "../../source/constant_path"
require_relative "../../source/node_children"

module Rigor
  module Analysis
    module CheckRules
      # `flow.shadowed-rescue-clause` — a `rescue` clause that can never run because an EARLIER clause of the
      # same `begin` / `def` rescue chain already catches a superclass (or the same class) of every exception
      # class the later clause names (`rescue StandardError => e … rescue ArgumentError => e` — the
      # ArgumentError arm is dead; a bare `rescue` counts as `StandardError` on either side). Modeled on the
      # shadowed-arm half of PHPStan's `CatchWithUnthrownExceptionRule`; the never-thrown half is deliberately
      # out of scope (unprovable in Ruby).
      #
      # The false-positive envelope is ancestry-certainty, not flow analysis — the rule is purely syntactic
      # plus class-hierarchy lookups, so it fires ONLY when:
      #
      # - every exception reference in BOTH the earlier and the later clause is a constant path that resolves
      #   (against the clause's lexical namespace) to a CLASS with known ancestry — an RBS / registry core
      #   class, or a project class whose `class Foo < Bar` superclass chain is discovered. Any unresolved
      #   constant, dynamic expression (`rescue klass_var`), or splat (`rescue *ERRORS`) makes its clause
      #   opaque: an opaque earlier clause contributes no coverage, an opaque later clause never fires.
      # - no reference resolves to a MODULE (the `rescue MyGem::Error` module-tag mixin pattern — module
      #   `===` semantics are custom, so any clause naming one stays out of every comparison). A
      #   project-discovered constant is certified as a class only via the `class Foo < Bar` superclass
      #   table; a plain `class Foo` / `module Foo` declaration is indistinguishable in the discovery table
      #   and stays silent.
      # - a multi-class arm (`rescue A, B => e`) is shadowed only when EVERY class it names is covered by
      #   some earlier comparable clause — one diagnostic per clause, naming the covering earlier clause(s).
      #
      # A later clause naming a SUPERCLASS of an earlier one is the normal narrow-to-wide rescue order and
      # never fires. `retry` in an earlier arm does not un-shadow (the re-raise re-enters from the top).
      # Nested `begin` / `rescue` inside a rescue body compares only clauses of its OWN `BeginNode` — the
      # walk dispatches per `BeginNode` and never crosses into another chain.
      class ShadowedRescueCollector
        # One shadowed clause. `clause` is the dead `Prism::RescueNode`; `clause_source` its rendered
        # `rescue A, B` condition list (`"rescue"` for a bare rescue); `earlier_sources` /
        # `earlier_lines` name the earlier clause(s) whose classes cover it.
        Result = Data.define(:clause, :clause_source, :earlier_sources, :earlier_lines)

        NODE_CLASSES = [Prism::BeginNode].freeze

        # Cycle / depth bound for the project `class Foo < Bar` superclass-chain walk.
        SUPERCLASS_WALK_LIMIT = 32

        # The implicit class of a bare `rescue` / `rescue => e`.
        IMPLICIT_RESCUE_CLASS = "StandardError"

        def initialize(scope_index)
          @scope_index = scope_index
          @results = []
        end

        # Legacy single-collector walk — the oracle the shadow harness (`RIGOR_SHADOW_RULE_WALK=1`) compares
        # the shared {RuleWalk} traversal against. Tracks the lexical class / module prefix itself, exactly
        # as {RuleWalk} threads `qualified_prefix`.
        # @rbs return: Array[Result] -- One entry per provably-shadowed rescue clause.
        def collect(root)
          walk(root, [])
          @results.freeze
        end

        # {RuleWalk} entry point. `context.qualified_prefix` carries the enclosing class / module names the
        # exception constants resolve against.
        def visit(node, context = nil)
          prefix = context.respond_to?(:qualified_prefix) ? context.qualified_prefix : []
          collect_begin(node, prefix)
        end

        def results
          @results.freeze
        end

        private

        def walk(node, prefix)
          return unless node.is_a?(Prism::Node)

          collect_begin(node, prefix) if node.is_a?(Prism::BeginNode)
          child_prefix = extend_prefix(node, prefix)
          node.rigor_each_child { |child| walk(child, child_prefix) }
        end

        def extend_prefix(node, prefix)
          return prefix unless node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)

          Source::ConstantPath.declaration_prefix(prefix, node.constant_path) || prefix
        end

        def collect_begin(node, prefix)
          clauses = rescue_chain(node.rescue_clause)
          return if clauses.size < 2

          scope = scope_for(node)
          return if scope.nil?

          infos = clauses.map { |clause| clause_info(clause, prefix, scope) }
          infos.each_with_index do |info, index|
            next if index.zero? || info.nil?

            check_shadowed(info, infos.first(index), scope)
          end
        end

        # The ordered `rescue` clauses of one `begin` node (the `subsequent` chain).
        def rescue_chain(clause)
          chain = []
          while clause
            chain << clause
            clause = clause.subsequent
          end
          chain
        end

        # A `Scope` for the environment / discovery lookups. Every scope of the file shares the discovery
        # index and environment, so any scope recorded on the begin node's neighbourhood serves; nil (no
        # scope recorded) keeps the whole chain silent.
        def scope_for(node)
          @scope_index[node] || @scope_index[node.statements] || @scope_index[node.rescue_clause]
        end

        # Resolves one clause to `{clause:, names: [String, …]}` where `names` are the certified exception
        # CLASS names it rescues, or nil when the clause is opaque (any entry unresolved / dynamic / splat /
        # module — the comparisons involving it stay silent). A bare `rescue` names the implicit
        # `StandardError`.
        def clause_info(clause, prefix, scope)
          exceptions = clause.exceptions
          if exceptions.empty?
            return unless certified_class?(IMPLICIT_RESCUE_CLASS, scope)

            return { clause: clause, names: [IMPLICIT_RESCUE_CLASS] }
          end

          names = exceptions.map { |exc| certified_exception_class(exc, prefix, scope) }
          return if names.any?(&:nil?)

          { clause: clause, names: names }
        end

        # The resolved, certified class name for one exception reference, or nil (opaque). Only constant
        # reads / constant paths participate; the name must resolve lexically and certify as a class with
        # known ancestry.
        def certified_exception_class(node, prefix, scope)
          name = resolve_constant(node, prefix, scope)
          return nil if name.nil?

          certified_class?(name, scope) ? name : nil
        end

        # Lexical constant resolution: innermost enclosing namespace first, then outward, then top-level —
        # first candidate any knowledge source (project discovery or RBS / registry) recognises wins. An
        # absolute path (`::Foo`) skips the lexical ladder. Returns nil for a non-constant node or a path
        # with a dynamic base.
        def resolve_constant(node, prefix, scope)
          name = Source::ConstantPath.qualified_name_or_nil(node)
          return nil if name.nil?

          return name if Source::ConstantPath.rooted?(node)

          candidates = []
          prefix.size.downto(1) { |i| candidates << (prefix.first(i) + [name]).join("::") }
          candidates << name
          candidates.find { |candidate| known_name?(candidate, scope) }
        end

        # Presence check used to pick the lexical candidate — deliberately broader than certification, so a
        # name that resolves to a project module is FOUND here and then rejected by {#certified_class?}
        # (rather than mis-resolving outward to a same-named core class).
        def known_name?(name, scope)
          scope.discovered_superclasses.key?(name) ||
            scope.discovered_classes.key?(name) ||
            scope.environment.class_known?(name)
        end

        # A name is a certified exception-comparable class when it is either a project class with a
        # discovered `class Foo < Bar` superclass entry, or an RBS / registry class that is not a module.
        # A project-discovered name WITHOUT a superclass entry cannot be told apart from a module (the
        # discovery table records both), so it stays uncertified — conservative, per the FP discipline.
        def certified_class?(name, scope)
          return true if scope.discovered_superclasses.key?(name)
          return false if scope.discovered_classes.key?(name)

          environment = scope.environment
          environment.class_known?(name) && !environment.rbs_module?(name)
        end

        # Fires when EVERY class the later clause names is covered by some earlier comparable clause.
        def check_shadowed(info, earlier_infos, scope)
          comparable_earlier = earlier_infos.compact
          return if comparable_earlier.empty?

          covering = info[:names].map do |name|
            comparable_earlier.find { |earlier| earlier[:names].any? { |e| covered_by?(name, e, scope) } }
          end
          return if covering.any?(&:nil?)

          clauses = covering.uniq
          @results << Result.new(
            clause: info[:clause],
            clause_source: clause_source(info[:clause]),
            earlier_sources: clauses.map { |c| clause_source(c[:clause]) },
            earlier_lines: clauses.map { |c| c[:clause].location.start_line }
          )
        end

        def clause_source(clause)
          exceptions = clause.exceptions
          return "rescue" if exceptions.empty?

          "rescue #{exceptions.map(&:slice).join(', ')}"
        end

        # Is `later` the same class as, or a subclass of, `earlier`? RBS / registry ancestry answers first;
        # `:unknown` (a project-defined class on either side) falls through to the discovered
        # `class Foo < Bar` superclass-chain walk. `:superclass` / `:disjoint` are definitive "no".
        def covered_by?(later, earlier, scope)
          return true if later == earlier

          case Reflection.class_ordering(later, earlier, scope: scope)
          when :equal, :subclass then true
          when :unknown then project_chain_covered?(later, earlier, scope)
          else false
          end
        end

        # Walks `later`'s discovered superclass chain (each parent recorded AS WRITTEN at its
        # `class Foo < Bar` site, resolved against the child's namespace) looking for `earlier` — directly,
        # or through an RBS-known ancestor that orders at-or-below `earlier`. Cycle-guarded and depth-capped;
        # a chain that leaves both knowledge sources stays silent.
        def project_chain_covered?(later, earlier, scope)
          supers = scope.discovered_superclasses
          current = later
          seen = {}
          SUPERCLASS_WALK_LIMIT.times do
            parent = supers[current.to_s]
            return false if parent.nil?

            resolved = resolve_parent(current, parent.to_s, scope)
            return false if seen[resolved]

            seen[resolved] = true
            return true if resolved == earlier

            case Reflection.class_ordering(resolved, earlier, scope: scope)
            when :equal, :subclass then return true
            when :unknown then current = resolved
            else return false
            end
          end
          false
        end

        # Resolves a superclass name as written (`Error`) against the child's namespace (`Mail::POP3` →
        # `Mail::Error`), longest prefix first; falls back to the as-written name (which RBS may know, e.g.
        # `StandardError`).
        def resolve_parent(child, parent, scope)
          # Issue #722 residue 1 — a rooted parent is anchored at the top level; the namespace walk below
          # is Ruby's lexical lookup, which `::` opts out of.
          return parent.delete_prefix("::") if parent.start_with?("::")

          segments = child.to_s.split("::")[0...-1]
          until segments.empty?
            candidate = "#{segments.join('::')}::#{parent}"
            return candidate if known_name?(candidate, scope)

            segments.pop
          end
          parent
        end
      end
    end
  end
end
