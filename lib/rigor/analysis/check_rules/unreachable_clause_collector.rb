# frozen_string_literal: true

require "prism"

require_relative "../../source/node_children"
require_relative "../../inference/narrowing"
require_relative "inferred_param_guard"
require_relative "clause_coverage"

module Rigor
  module Analysis
    module CheckRules
      # ADR-47 — collects `case`/`when` clauses proven unreachable. The flow engine already narrows the case
      # subject across `when` branches (`Narrowing.case_when_scopes`), and the per-clause `body_scope` it
      # produces is recorded in `scope_index` keyed on the `WhenNode` (the evaluator enters the clause under
      # that scope). So a clause whose narrowed subject local is `Type::Bot` is one the engine's own
      # narrowing proves no reaching value can match — a stale `when`, mis-ordered clauses, or a type that
      # moved out from under a branch.
      #
      # WD1 (per-clause disjointness) — the narrow, high-value core. Fires ONLY on the safe shape:
      #
      # - the subject is a `case <local>` (a `LocalVariableReadNode`, the only shape `case_when_scopes`
      #   narrows — no narrowing ⇒ no firing),
      # - every `when` condition is a class/module constant (`when String` / `when MyClass`), the shape the
      #   narrowing recognises — `when nil` / ranges / regexps / arbitrary expressions are out of scope here,
      # - the subject's type at case entry is a concrete carrier, never `Type::Dynamic` (disjointness is
      #   never provable under gradual `Dynamic`, preserving the gradual guarantee) and never already
      #   `Type::Bot` (dead code, not a clause error),
      # - and the clause's narrowed `body_scope` subject is `Type::Bot`.
      #
      # The false-positive envelope mirrors `flow.always-truthy-condition`: clauses inside loops / blocks are
      # skipped (mutation tracking through those is incomplete), and the rule reads the engine's own
      # narrowing rather than recomputing it, so the diagnostic and the body typing can never diverge.
      #
      # Issue #1429 — a `:disjoint` clause is not reported when its `Bot` rests on a `Nominal` subject member whose
      # class is disjoint from a condition's ({Inference::Narrowing.disjoint_nominal_guard?}): the `when C` or `in C`
      # is code evidence that the subject can hold such an object (`io = STDOUT; case io when StringIO`), and Rigor's
      # reading of the subject's type is what the evidence contradicts. The body scope stays `Bot`, so no call on the
      # subject in it is checked. A subject that is a literal carrier (`x = 1; case x when String`) is still reported.
      #
      # Issue #1485 — the same holds for a `:prior_exhaustion` clause: on a subject that is not a literal carrier it is
      # reported only when every class it names is at or below a class an earlier clause names ({ClauseCoverage}), so
      # `io = STDOUT; case io when IO … when StringIO` is quiet and `when IO … when File` still reports.
      class UnreachableClauseCollector
        LOOP_OR_BLOCK_NODE_CLASSES = [
          Prism::WhileNode, Prism::UntilNode, Prism::ForNode, Prism::BlockNode
        ].freeze

        # A trailing `else` whose body only re-raises / aborts is a deliberate defensive guard ("this should
        # be unreachable — shout if it ever isn't"), NOT dead code the author wants removed. Flagging it
        # would push the author to delete a safety net, which the false-positive discipline forbids. WD1's
        # `when` shapes don't carry this idiom (a stale `when` is a real redundancy), so the skip is
        # `else`-only.
        DEFENSIVE_EXIT_CALLS = %i[raise fail throw abort exit].freeze

        # Issue #2071 — core classes whose idiomatic stand-ins are not their subclasses: a `StringIO` answers the
        # IO protocol without being an `IO`, a `Tempfile` delegates to a `File` without being one (or an `IO`),
        # and a `Pathname` stands in for a path `String`. A subject Rigor types as one of these classes may hold
        # such a stand-in, which no `when IO` / `in String` matches, so the `else` still runs for it.
        DUCK_STAND_INS = {
          "IO" => %w[StringIO Tempfile].freeze,
          "File" => %w[Tempfile].freeze,
          "String" => %w[Pathname].freeze
        }.freeze

        # The classes every object is: a clause naming one matches a stand-in too.
        UNIVERSAL_CLASSES = %w[Object BasicObject Kernel].freeze

        # @!attribute kind
        #   @return `:disjoint` (this clause's type is disjoint
        #     from the still-possible subject), `:prior_exhaustion` (an
        #     earlier clause already covered the subject), or
        #     `:exhausted_else` (every subject value is covered, so the
        #     `else` never runs).
        Result = Data.define(:clause, :body, :subject_name, :condition_source, :kind, :keyword)

        # ADR-53 Track B — the node classes the shared {RuleWalk} dispatches to this collector, and the
        # context gate under which the walk suppresses it (loop / block bodies — see the envelope above).
        # The legacy walk's `!in_loop_or_block` guard is now the walk's `:loop_or_block` gate, applied
        # before `#visit`.
        NODE_CLASSES = [Prism::CaseNode, Prism::CaseMatchNode].freeze
        RULE_WALK_GATES = [:loop_or_block].freeze

        def initialize(scope_index)
          @scope_index = scope_index
          @results = []
        end

        # Legacy single-collector walk — kept as the oracle the ADR-53 Track B equivalence harness compares
        # {RuleWalk} against; deleted when Track B completes.
        # @return one entry per provably-dead `when` clause.
        def collect(root)
          walk(root, in_loop_or_block: false)
          @results.freeze
        end

        # {RuleWalk} entry point: the per-node logic of the legacy walk, invoked under the same traversal
        # contract. The `context` is unused — the loop / block suppression this collector relied on is the
        # walk's `:loop_or_block` gate now.
        def visit(node, _context = nil)
          collect_case(node)
        end

        def results
          @results.freeze
        end

        private

        def walk(node, in_loop_or_block:)
          return unless node.is_a?(Prism::Node)

          visit(node) if case_like?(node) && !in_loop_or_block

          child_in_loop_or_block = in_loop_or_block || enters_loop_or_block?(node)
          node.rigor_each_child { |child| walk(child, in_loop_or_block: child_in_loop_or_block) }
        end

        # `case/when` is a `CaseNode`; `case/in` is a `CaseMatchNode`. Both carry `predicate` + `conditions`
        # + `else_clause` and the engine narrows both through `eval_case_when_branches`.
        def case_like?(node)
          node.is_a?(Prism::CaseNode) || node.is_a?(Prism::CaseMatchNode)
        end

        def enters_loop_or_block?(node)
          LOOP_OR_BLOCK_NODE_CLASSES.any? { |klass| node.is_a?(klass) }
        end

        def collect_case(node)
          subject = node.predicate
          return unless subject.is_a?(Prism::LocalVariableReadNode)

          # ADR-67 WD6b — a `case` subject that is an inferred parameter narrows to `Bot` in the non-matching
          # clauses only because its seeded type is a lower bound; a wider real caller could match them. Decline
          # the whole case so no clause fires unreachable.
          scope = @scope_index[node]
          return if scope && InferredParamGuard.rooted?(subject, scope)

          entry_type = entry_subject_type(node, subject.name)
          # Only meaningful for a concrete subject type: a `Dynamic` subject can never be proven disjoint
          # (the gradual guarantee), and an already-`Bot` subject is dead code, not a clause-ordering error.
          return if entry_type.nil? || entry_type.is_a?(Type::Bot) || entry_type.is_a?(Type::Dynamic)

          keyword = node.is_a?(Prism::CaseMatchNode) ? "in" : "when"
          coverage = ClauseCoverage.new(scope, entry_type)
          node.conditions.each do |clause|
            case clause
            when Prism::WhenNode then collect_when(clause, subject.name, coverage)
            when Prism::InNode then collect_in(clause, subject.name, coverage)
            end
            coverage.record(clause)
          end
          return if stand_in_reaches_else?(node, entry_type, scope)

          collect_else(node.else_clause, subject.name, keyword)
        end

        # Issue #2071 — whether the subject, as the `case` binds it, has a `Nominal` member of a {DUCK_STAND_INS}
        # class with a stand-in no clause names (the stand-in itself or a class above it). `io = STDOUT; case io
        # when IO then … else … end` runs the `else` for a `StringIO`, which the type `IO` stands for in idiomatic
        # Ruby; a literal subject (`"a"`) is a `Constant`, not a `Nominal`, and keeps its verdict. Asked of the
        # `else` only: a dead `when` has its own evidence rules (#1429, #1485).
        def stand_in_reaches_else?(node, entry_type, scope)
          members = entry_type.is_a?(Type::Union) ? entry_type.members : [entry_type]
          pairs = members.flat_map do |member|
            next [] unless member.is_a?(Type::Nominal)

            base = member.class_name.delete_prefix("::")
            DUCK_STAND_INS.fetch(base, []).map { |stand_in| [base, stand_in] }
          end
          return false if pairs.empty?

          named = clause_class_names(node)
          pairs.any? { |base, stand_in| named.none? { |name| covers_stand_in?(name, base, stand_in, scope) } }
        end

        # Whether a clause naming `name` matches `stand_in`: the stand-in itself, a class every object is, or a class
        # RBS places above the stand-in and not above `base`. The last test leaves out what RBS gets wrong about a
        # stand-in: stdlib RBS declares `class Tempfile < File`, while Ruby's `Tempfile` is a `Delegator`, so `when
        # File` (or `IO`) does not match one.
        def covers_stand_in?(name, base, stand_in, scope)
          return true if name == stand_in || UNIVERSAL_CLASSES.include?(name)
          return false if scope.nil? || name == base

          environment = scope.environment
          environment.class_ordering(stand_in, name) == :subclass && environment.class_ordering(base, name) != :subclass
        end

        # The classes the clauses name as bare constants (`when A, B`, `in A`, `in A => x`).
        def clause_class_names(node)
          node.conditions.flat_map do |clause|
            patterns = clause.is_a?(Prism::WhenNode) ? clause.conditions : [bare_pattern(clause.pattern)]
            patterns.filter_map do |pattern|
              entry = @scope_index[pattern]
              entry && Inference::Narrowing.lexical_class_name(pattern, entry)
            end
          end
        end

        def bare_pattern(pattern)
          pattern.is_a?(Prism::CapturePatternNode) ? pattern.value : pattern
        end

        def entry_subject_type(case_node, subject_name)
          scope = @scope_index[case_node]
          scope&.local(subject_name)
        end

        def collect_when(clause, subject_name, coverage)
          return if clause.statements.nil? # empty body → no useful location
          return unless all_constant_conditions?(clause)

          scope = @scope_index[clause]
          return if scope.nil?
          return unless scope.local(subject_name).is_a?(Type::Bot)

          kind = when_clause_kind(clause, subject_name)
          return if kind == :disjoint &&
                    disjoint_nominal_subject?(@scope_index[clause.conditions.first], subject_name, clause.conditions)
          return if kind == :prior_exhaustion && !coverage.proven?(clause)

          @results << Result.new(
            clause: clause, body: clause.statements, subject_name: subject_name,
            condition_source: clause.conditions.map(&:slice).join(", "),
            kind: kind, keyword: "when"
          )
        end

        # True when the subject, as `entry` binds it, holds a non-literal `Nominal` whose class the class one of
        # `patterns` names is disjoint from (issue #1429, see the class comment).
        def disjoint_nominal_subject?(entry, subject_name, patterns)
          subject_type = entry&.local(subject_name)
          return false if subject_type.nil?

          patterns.any? do |condition|
            class_name = Inference::Narrowing.lexical_class_name(condition, entry)
            class_name &&
              Inference::Narrowing.disjoint_nominal_guard?(subject_type, class_name, environment: entry.environment)
          end
        end

        # A dead `when` is `:prior_exhaustion` when the subject was already narrowed to `bot` BEFORE this
        # clause (an earlier clause covered it) — read from the entry scope the engine recorded on the
        # clause's first condition node (ADR-47 WD2). Otherwise the subject was still concrete entering the
        # clause and THIS clause's type is disjoint from it.
        def when_clause_kind(clause, subject_name)
          entry = @scope_index[clause.conditions.first]
          return :prior_exhaustion if entry && entry.local(subject_name).is_a?(Type::Bot)

          :disjoint
        end

        # ADR-47 WD3a — a dead `case/in` clause. The body scope reaches `bot` either because a bare class
        # pattern (`in C` / `in C => x`) is disjoint from the still-possible subject (the engine narrows
        # those soundly, like `when C`), or because an earlier clause already exhausted the subject
        # (prior-exhaustion — true for ANY pattern downstream of a covering set). Non-bare patterns are not
        # narrowed, so their body is `bot` ONLY under prior-exhaustion; they never produce a spurious
        # `:disjoint`.
        def collect_in(clause, subject_name, coverage)
          return if clause.statements.nil?

          scope = @scope_index[clause]
          return if scope.nil?
          return unless scope.local(subject_name).is_a?(Type::Bot)

          kind = in_clause_kind(clause, subject_name)
          return if kind == :disjoint && disjoint_nominal_pattern?(clause, subject_name)
          return if kind == :prior_exhaustion && !coverage.proven?(clause)

          @results << Result.new(
            clause: clause, body: clause.statements, subject_name: subject_name,
            condition_source: clause.pattern.slice,
            kind: kind, keyword: "in"
          )
        end

        # {#disjoint_nominal_subject?} for a bare class pattern, `in C` or `in C => x`.
        def disjoint_nominal_pattern?(clause, subject_name)
          pattern = clause.pattern
          pattern = pattern.value if pattern.is_a?(Prism::CapturePatternNode)
          disjoint_nominal_subject?(@scope_index[clause.pattern], subject_name, [pattern])
        end

        def in_clause_kind(clause, subject_name)
          entry = @scope_index[clause.pattern]
          return :prior_exhaustion if entry && entry.local(subject_name).is_a?(Type::Bot)

          :disjoint
        end

        # The trailing `else` is dead when every subject value is covered by the `when` clauses — the final
        # falsey scope (recorded on the `else` node) narrows the subject to `bot`. Defensive `else` bodies (a
        # bare `raise` / `fail` / `throw`) are deliberate guards, not removable dead code, so they are
        # skipped.
        def collect_else(else_clause, subject_name, keyword)
          return if else_clause.nil? || else_clause.statements.nil?
          return if defensive_else?(else_clause)

          scope = @scope_index[else_clause]
          return if scope.nil?
          return unless scope.local(subject_name).is_a?(Type::Bot)

          @results << Result.new(
            clause: else_clause, body: else_clause.statements, subject_name: subject_name,
            condition_source: nil, kind: :exhausted_else, keyword: keyword
          )
        end

        def defensive_else?(else_clause)
          body = else_clause.statements.body
          return false unless body.size == 1

          stmt = body.first
          stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? &&
            DEFENSIVE_EXIT_CALLS.include?(stmt.name)
        end

        def all_constant_conditions?(clause)
          conditions = clause.conditions
          !conditions.empty? &&
            conditions.all? { |c| c.is_a?(Prism::ConstantReadNode) || c.is_a?(Prism::ConstantPathNode) }
        end
      end
    end
  end
end
