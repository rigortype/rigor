# frozen_string_literal: true

require "prism"

require_relative "../reflection"
require_relative "../source/node_walker"
require_relative "../source/constant_path"
require_relative "../inference/singleton_object_constant"
require_relative "../type"
require_relative "diagnostic"
require_relative "dependency_recorder"
require_relative "check_rules/rule_ids"
require_relative "check_rules/inferred_param_guard"
require_relative "check_rules/declaration_sourced_guard"
require_relative "check_rules/rule_walk"
require_relative "check_rules/always_truthy_condition_collector"
require_relative "check_rules/unreachable_clause_collector"
require_relative "check_rules/shadowed_rescue_collector"
require_relative "check_rules/dead_assignment_collector"
require_relative "check_rules/duplicate_hash_key_collector"
require_relative "check_rules/return_in_ensure_collector"
require_relative "check_rules/ivar_write_collector"
require_relative "check_rules/main_pass_collector"
require_relative "check_rules/void_value_use_collector"
require_relative "check_rules/self_closedness_scanner"

module Rigor
  module Analysis
    # Catalogue of `rigor check` diagnostic rules.
    #
    # Rules fire ONLY when the engine is confident enough to make a
    # useful claim and MUST NOT raise on unrecognised AST shapes,
    # RBS gaps, or missing scope information. Each rule consumes
    # the per-node scope index produced by
    # `Rigor::Inference::ScopeIndexer.index` and yields zero or
    # more `Rigor::Analysis::Diagnostic` values.
    #
    # The primary rule (`call.undefined-method`) flags an
    # explicit-receiver `Prism::CallNode` whose receiver statically
    # resolves to a class known to the RBS environment and whose
    # method name does not appear on that class's method table.
    # It does NOT fire for:
    #
    # - implicit-self calls (no `node.receiver`) — too noisy
    #   without per-method RBS for every helper in the class.
    # - dynamic / unknown receivers (`Dynamic[T]`, `Top`, `Union`)
    #   — by definition we cannot enumerate the method set.
    # - shape carriers: `Tuple` → "Array", `HashShape` → "Hash",
    #   `Constant` → the constant's class — `concrete_class_name`
    #   resolves these to their runtime class for dispatch.
    # - receivers whose class name is NOT registered in the
    #   loader (RBS-blind environments, unknown stdlib).
    # rubocop:disable Metrics/ModuleLength
    module CheckRules
      # ADR-87 WD4 — the canonical rule-id table lives in the light `check_rules/rule_ids.rb` (required at the
      # top of this file) so {Analysis::RuleCatalog} can read it without loading the engine.

      # ADR-35 slice 1 — bound for the `def.override-visibility-reduced`
      # ancestor walk, and the public > protected > private ordering
      # used to decide whether an override reduces visibility.
      OVERRIDE_ANCESTOR_WALK_LIMIT = 100
      VISIBILITY_RANK = { public: 2, protected: 1, private: 0 }.freeze

      # Resolves a user-supplied rule token (`undefined-method`,
      # `call.undefined-method`, or the family wildcard `call`)
      # to the set of canonical rule identifiers it disables.
      # Returns `nil` for `"all"` (the existing wildcard meaning
      # "every rule"), or for unknown tokens.
      def self.resolve_rule_token(token)
        return nil if token == "all"
        return [LEGACY_RULE_ALIASES.fetch(token)] if LEGACY_RULE_ALIASES.key?(token)
        return ALL_RULES.select { |r| r.start_with?("#{token}.") } if RULE_FAMILIES.include?(token)

        ALL_RULES.include?(token) ? [token] : []
      end

      module_function

      # Yields diagnostics for every unrecognised method call on
      # a typed receiver in `root`'s subtree. The caller MUST
      # have already produced `scope_index` through
      # `Rigor::Inference::ScopeIndexer.index(root, default_scope:)`.
      #
      # @param path [String] used to populate
      #   `Diagnostic#path`; the rule does not open files.
      # @param root [Prism::Node]
      # @param scope_index [Hash{Prism::Node => Rigor::Scope}]
      # @return [Array<Rigor::Analysis::Diagnostic>]
      #
      # ADR-53 B4 — when `node_collectors` is supplied, the converged
      # {Plugin::NodeRuleWalk} traversal has already populated the built-in
      # collectors (including the main pass) in one shared walk with the
      # plugin node-rules, so they are consumed as-is. When it is nil (a
      # direct caller with no plugin walk, e.g. a unit test), the standalone
      # {RuleWalk} walk runs here instead, so `diagnose` stays correct
      # without the converged path.
      def diagnose(path:, root:, scope_index:, self_call_misses: [], comments: [], disabled_rules: [],
                   node_collectors: nil)
        collectors = node_collectors || run_node_collectors(path, root, scope_index)
        diagnostics = collectors[:main_pass].results.dup
        diagnostics.concat(self_undefined_method_diagnostics(path, self_call_misses, root, scope_index))
        COLLECTOR_DIAGNOSTIC_BUILDERS.each do |role, builder|
          diagnostics.concat(send(builder, path, collectors[role].results))
        end
        # Suppression-marker validation (`suppression.*`) runs BEFORE the filter so its own diagnostics are
        # suppressible like any other rule — `# rigor:disable suppression.unknown-rule` on the offending
        # comment's line works, with no regress (the token itself is known, so it never re-fires).
        diagnostics.concat(suppression_marker_diagnostics(path, comments))
        filter_suppressed(diagnostics, comments: comments, disabled_rules: disabled_rules)
      end

      # The per-collector diagnostic builders {.diagnose} folds over, in the historical emission order
      # (value-use-void → always-truthy → unreachable-clause → shadowed-rescue → ivar-write →
      # dead-assignment → duplicate-hash-key → return-in-ensure). Keys match {.build_node_collectors}'
      # roles; each value is a `(path, results)` module_function on this module. `void_value_use` leads
      # because its standalone walk used to run before this fold, and the emission order is byte-identical
      # output, not an implementation detail.
      COLLECTOR_DIAGNOSTIC_BUILDERS = {
        void_value_use: :void_value_use_diagnostics,
        always_truthy: :always_truthy_condition_diagnostics,
        unreachable_clauses: :unreachable_clause_diagnostics,
        shadowed_rescues: :shadowed_rescue_diagnostics,
        ivar_writes: :ivar_write_mismatch_diagnostics,
        dead_assignments: :dead_assignment_diagnostics,
        duplicate_hash_keys: :duplicate_hash_key_diagnostics,
        return_in_ensure: :return_in_ensure_diagnostics
      }.freeze
      private_constant :COLLECTOR_DIAGNOSTIC_BUILDERS

      # The verbatim per-node dispatch of the former inline main pass
      # (`diagnose`'s `Source::NodeWalker.each` `case`), now invoked by
      # {MainPassCollector} on the shared {RuleWalk}. Returns the
      # diagnostics for one node, in the same emission order as before.
      def main_pass_node_diagnostics(path, node, scope_index)
        case node
        when Prism::CallNode
          call_node_diagnostics(path, node, scope_index)
        when Prism::DefNode
          [
            return_type_mismatch_diagnostic(path, node, scope_index),
            override_visibility_diagnostic(path, node, scope_index),
            override_return_widened_diagnostic(path, node, scope_index),
            override_param_narrowed_diagnostic(path, node, scope_index)
          ].compact
        when Prism::IfNode, Prism::UnlessNode
          [unreachable_branch_diagnostic(path, node, scope_index)].compact
        else
          []
        end
      end

      # Constructs the fresh, unpopulated built-in collector set keyed by
      # role, including the main pass. Split out so the converged walk
      # (ADR-53 B4) can build the collectors, drive them via a
      # {RuleWalk::CollectorDriver} inside the single {Plugin::NodeRuleWalk}
      # traversal, and hand the populated set back to {.diagnose} as
      # `node_collectors:`. The main pass needs `path` because its per-node
      # diagnostics carry it (ADR-53 B3c hosts it on the same walk).
      def build_node_collectors(path, scope_index)
        {
          main_pass: MainPassCollector.new(->(node) { main_pass_node_diagnostics(path, node, scope_index) }),
          void_value_use: VoidValueUseCollector.new(scope_index),
          always_truthy: AlwaysTruthyConditionCollector.new(scope_index),
          unreachable_clauses: UnreachableClauseCollector.new(scope_index),
          shadowed_rescues: ShadowedRescueCollector.new(scope_index),
          ivar_writes: IvarWriteCollector.new(scope_index),
          dead_assignments: DeadAssignmentCollector.new(scope_index),
          duplicate_hash_keys: DuplicateHashKeyCollector.new(scope_index),
          return_in_ensure: ReturnInEnsureCollector.new(scope_index)
        }
      end

      # A {RuleWalk::CollectorDriver} over a built-in collector set, for a
      # foreign traversal to drive (ADR-53 B4). The driver visits each node
      # and derives child contexts exactly as the standalone {RuleWalk}
      # walk would.
      def node_collector_driver(collectors)
        RuleWalk::CollectorDriver.new(collectors.values)
      end

      # ADR-53 Track B — the {RuleWalk}-hosted built-in collectors (the main
      # pass and the four fact collectors) all ride one traversal of the
      # file instead of one walk each. Returns the populated collectors
      # keyed by role so the caller can build the diagnostics from each
      # collector's `results`. Used on the standalone path (no converged
      # plugin walk); the converged path populates the same collector set
      # via {.node_collector_driver} instead.
      #
      # Under `RIGOR_SHADOW_RULE_WALK=1` each hosted collector's legacy
      # single-collector `#collect` walk also runs as the oracle and any
      # divergence aborts the run — the corpus-scale half of the
      # equivalence harness (the curated half is `rule_walk_equivalence_spec`).
      def run_node_collectors(path, root, scope_index)
        collectors = build_node_collectors(path, scope_index)
        RuleWalk.run(root, collectors.values)
        shadow_verify_node_collectors(path, root, scope_index, collectors) if ENV["RIGOR_SHADOW_RULE_WALK"]
        collectors
      end

      def shadow_verify_node_collectors(path, root, scope_index, collectors)
        divergences = collectors.filter_map do |role, collector|
          legacy = oracle_results(role, collector, path, root, scope_index)
          next if comparable(legacy) == comparable(collector.results)

          "#{role} legacy=#{legacy.size} walk=#{collector.results.size}"
        end
        return if divergences.empty?

        raise "RIGOR_SHADOW_RULE_WALK divergence: #{divergences.join('; ')}"
      end

      # Normalises a collector's result for value comparison. The fact
      # collectors return `Data` / Hash structures that already compare by
      # value; the main pass returns {Diagnostic} objects (plain objects
      # with identity `==`), so serialise those to hashes first.
      def comparable(results)
        return results.map(&:to_h) if results.is_a?(Array) && results.first.is_a?(Diagnostic)

        results
      end

      # The oracle each hosted collector's walk result is checked against.
      # The fact collectors re-run their legacy single-collector `#collect`
      # walk; the main pass re-runs the former inline `Source::NodeWalker`
      # `case` (`main_pass_oracle`) since its diagnostics are the result.
      def oracle_results(role, collector, path, root, scope_index)
        return main_pass_oracle(path, root, scope_index) if role == :main_pass

        collector.class.new(scope_index).collect(root)
      end

      # The former inline main pass, kept as the shadow oracle: walks the
      # tree with `Source::NodeWalker.each` and accumulates the same
      # per-node diagnostics in the same order {MainPassCollector} now
      # produces them on the shared walk.
      def main_pass_oracle(path, root, scope_index)
        diagnostics = []
        Source::NodeWalker.each(root) do |node|
          diagnostics.concat(main_pass_node_diagnostics(path, node, scope_index))
        end
        diagnostics
      end

      # ADR-53 B4 — corpus-scale oracle for the CONVERGED walk: the
      # collectors (including the main pass, ADR-53 B3c) were populated by
      # the {Plugin::NodeRuleWalk} traversal, not by `RuleWalk.run`, so
      # re-run each collector's legacy oracle (the fact collectors'
      # `#collect` walk, the main pass's inline `Source::NodeWalker` `case`)
      # and assert the converged walk produced byte-identical results. Same
      # divergence contract as {.shadow_verify_node_collectors}; nil
      # collectors (caller without built-in collection) is a no-op. `path`
      # is threaded because the main pass's oracle carries it.
      def shadow_verify_converged_collectors(path, root, scope_index, collectors)
        return if collectors.nil?

        shadow_verify_node_collectors(path, root, scope_index, collectors)
      end

      def call_node_diagnostics(path, node, scope_index)
        [
          undefined_method_diagnostic(path, node, scope_index),
          unresolved_toplevel_diagnostic(path, node, scope_index),
          wrong_arity_diagnostic(path, node, scope_index),
          argument_type_diagnostic(path, node, scope_index),
          nil_receiver_diagnostic(path, node, scope_index),
          dump_type_diagnostic(path, node, scope_index),
          assert_type_diagnostic(path, node, scope_index),
          always_raises_diagnostic(path, node, scope_index),
          raise_non_exception_diagnostic(path, node, scope_index),
          visibility_mismatch_diagnostic(path, node, scope_index)
        ].compact
      end

      # v0.1.2 — `def.ivar-write-mismatch`. Walks every
      # ClassNode / ModuleNode body, gathers per-class ivar
      # writes with their rvalue types, and emits a diagnostic
      # when a later write's concrete class disagrees with the
      # first write's. The first write per (class, ivar) is
      # treated as the "declared" type; subsequent writes that
      # land on a different concrete class trigger.
      #
      # Conservative envelope:
      # - Only fires when both the first and the offending
      #   write resolve to a `concrete_class_name` (Nominal /
      #   Singleton / Constant / Tuple → "Array" / HashShape →
      #   "Hash"). Unions / Dynamic / IntegerRange / shape-
      #   varied carriers fall through.
      # - `NilClass` is an intentional widening idiom (`@x =
      #   "value"` then later `@x = nil` to "clear") — skipped.
      # - Singleton-method (`def self.foo`) bodies are skipped.
      #   Class-level ivars (`@x = 1` outside any def, in the
      #   class body) are also skipped — they're a separate
      #   surface (`Module#@var`) the engine doesn't yet model.
      def ivar_write_mismatch_diagnostics(path, ivar_writes)
        ivar_writes.flat_map do |class_name, writes_by_ivar|
          writes_by_ivar.flat_map do |ivar_name, writes|
            ivar_mismatch_diagnostics_for(path, class_name, ivar_name, writes)
          end
        end
      end

      # v0.1.2 — `flow.dead-assignment`. Walks every `DefNode`
      # body and emits a diagnostic for each plain
      # `LocalVariableWriteNode` whose target name is never
      # read in the same body. The
      # `Analysis::CheckRules::DeadAssignmentCollector` describes
      # the conservative envelope.
      def dead_assignment_diagnostics(path, dead_assignments)
        dead_assignments.map do |result|
          build_dead_assignment_diagnostic(path, result[:write_node], result[:def_node])
        end
      end

      # v0.3.0 — `flow.duplicate-hash-key`. Emits a diagnostic for each LATER occurrence of a repeated
      # LITERAL key within one Hash literal (braced or bare-kwargs) — Ruby keeps the last entry silently
      # at runtime, so the earlier value is dead. The
      # `Analysis::CheckRules::DuplicateHashKeyCollector` describes the value-pinned-literal-only
      # envelope (symbols / plain strings / integers / floats / true / false / nil; never
      # cross-kind, never interpolation / constants / calls / splats).
      def duplicate_hash_key_diagnostics(path, duplicate_keys)
        duplicate_keys.map do |result|
          build_duplicate_hash_key_diagnostic(path, result)
        end
      end

      # v0.3.0 — `flow.return-in-ensure`. One diagnostic per explicit
      # `return` lexically inside an `ensure` clause body: it silently
      # discards the method's in-flight return value and swallows any
      # in-flight exception. Purely syntactic; the
      # `Analysis::CheckRules::ReturnInEnsureCollector` describes the
      # frame-aware envelope (nested def / lambda / `define_method`
      # blocks are excluded, plain blocks are not).
      def return_in_ensure_diagnostics(path, results)
        results.map do |result|
          build_return_in_ensure_diagnostic(path, result[:return_node])
        end
      end

      # v0.1.2 — `flow.always-truthy-condition`. Fires on
      # `if` / `unless` / ternary predicates whose inferred
      # type is a `Type::Constant` AND that don't fall in
      # the literal-only / inside-loop-or-block / defensive-
      # predicate skip envelope (see
      # `Analysis::CheckRules::AlwaysTruthyConditionCollector`
      # for the full triage rationale).
      def always_truthy_condition_diagnostics(path, results)
        results.map do |result|
          build_always_truthy_condition_diagnostic(path, result.node, result.polarity)
        end
      end

      # ADR-47 — `flow.unreachable-clause`. One diagnostic per `when` clause
      # the flow engine's narrowing proves can never match (its narrowed
      # subject is `bot`). The squiggle lands on the dead clause's body,
      # mirroring `flow.unreachable-branch`.
      def unreachable_clause_diagnostics(path, results)
        results.map do |result|
          build_unreachable_clause_diagnostic(path, result)
        end
      end

      # ADR-100 WD2 — `static.value-use.void`. Its value-context slot inspection rides the shared per-node
      # {RuleWalk} like the other collectors, so the file is not re-traversed for it. Each result is a
      # value-context use of a call whose author-declared `-> void` return the engine recovered to `top`.
      def void_value_use_diagnostics(path, results)
        results.map do |result|
          build_void_value_use_diagnostic(path, result)
        end
      end

      # `flow.shadowed-rescue-clause` — one diagnostic per rescue clause every earlier-comparable class of
      # which is already caught by an earlier clause of the same chain (see {ShadowedRescueCollector} for
      # the ancestry-certainty envelope).
      def shadowed_rescue_diagnostics(path, results)
        results.map do |result|
          build_shadowed_rescue_diagnostic(path, result)
        end
      end

      def ivar_mismatch_diagnostics_for(path, class_name, ivar_name, writes)
        return [] if writes.size < 2

        # Skip past leading `NilClass` writes when establishing
        # the canonical type. The common nullable-slot idiom
        # (`@x = nil` placeholder in `initialize` / a default
        # state slot, then `@x = :foo` on first concrete state)
        # would otherwise fire a false positive on every
        # concrete write because `first_class` was `NilClass`
        # and every subsequent `Symbol` / `String` / `Hash`
        # write triggered the divergence rule. The first
        # concrete (non-nil) write is the canonical type;
        # additional `NilClass` writes are still tolerated
        # downstream by the existing `other_class == "NilClass"`
        # check (the nullable-slot resets to nil between work).
        canonical = writes.find { |w| ivar_class_for(w[:type]) != "NilClass" }
        return [] if canonical.nil?

        first_class = ivar_class_for(canonical[:type])
        return [] if first_class.nil?

        canonical_index = writes.index(canonical)
        writes[(canonical_index + 1)..].filter_map do |write|
          other_class = ivar_class_for(write[:type])
          next nil if other_class.nil? || other_class == "NilClass" || other_class == first_class

          build_ivar_write_mismatch_diagnostic(path, write[:node], class_name, ivar_name, first_class, other_class)
        end
      end

      # v0.0.2 #6 — diagnostic suppression. Three kinds of
      # suppression compose:
      #
      # - **Project-level**: `disabled_rules` is the
      #   project's `.rigor.yml` `disable:` list. Any
      #   diagnostic whose `rule` is in the list is dropped.
      # - **File-level** (v0.1.2): `# rigor:disable-file <rule1>,
      #   <rule2>` anywhere in the file suppresses the matching
      #   diagnostic for every line. `# rigor:disable-file all`
      #   suppresses every rule across the file. Convention is
      #   to put the comment near the top, but Rigor accepts it
      #   anywhere — the comment scope is "this file" regardless
      #   of position.
      # - **In-source line**: `# rigor:disable <rule1>, <rule2>`
      #   on the same line as the offending expression
      #   suppresses the matching diagnostic for that line
      #   only. `# rigor:disable all` on a line suppresses
      #   every rule on that line.
      #
      # Both in-source forms are recognised only when the
      # marker is the FIRST thing in the comment, so a
      # directive quoted inside ordinary prose — as the bullets
      # above quote it — is not a directive. See the pattern
      # constants below.
      #
      # Diagnostics with `rule == nil` (parse errors, path
      # errors, internal analyzer errors) are NEVER
      # suppressed — they represent failures the user cannot
      # silence away.
      def filter_suppressed(diagnostics, comments:, disabled_rules:)
        line_suppressions, file_suppressions = parse_suppression_comments(comments)
        disabled = expand_rule_tokens(disabled_rules)

        diagnostics.reject do |diagnostic|
          rule = diagnostic.rule
          next false if rule.nil?
          next true if disabled.include?(rule)
          next true if file_suppressions.include?("all") || file_suppressions.include?(rule)

          line_rules = line_suppressions[diagnostic.line]
          line_rules && (line_rules.include?("all") || line_rules.include?(rule))
        end
      end

      # Every suppression-recognition pattern below is anchored with `\A` against the COMMENT SLICE —
      # Prism hands us a slice that starts at the `#`, so `\A#` means "the marker is the first thing in
      # the comment". A real directive always has that shape, in both the whole-line form and the
      # trailing `code # rigor:disable <rule>` form; prose that merely quotes a directive
      # (`... like `# rigor:disable-file all` ...`) has text before the inner `#` and no longer
      # activates anything. Two consequences worth naming: a doc-tool `##` comment never activates (the
      # second `#` is neither whitespace nor the marker word), and an `=begin`/`=end` block comment
      # never activates either (its slice starts at `=begin`). Unanchored, these patterns silently
      # file-suppressed this very file — see issue #306.
      LINE_SUPPRESSION_PATTERN = /\A#\s*rigor:disable(?!-file)\s+(?<rules>[\w.,\s-]+)/
      private_constant :LINE_SUPPRESSION_PATTERN

      FILE_SUPPRESSION_PATTERN = /\A#\s*rigor:disable-file\s+(?<rules>[\w.,\s-]+)/
      private_constant :FILE_SUPPRESSION_PATTERN

      # A `rigor:disable[-file]` marker word regardless of whether any rule tokens follow. Used only by the
      # `suppression.empty` detection — the two suppression patterns above require at least one token
      # character, so a bare `# rigor:disable` never reaches them. The lookahead keeps
      # `rigor:disable-something-else` from counting as a marker.
      BARE_SUPPRESSION_MARKER = /\A#\s*rigor:disable(?<file>-file)?(?![\w-])(?<rest>.*)/
      private_constant :BARE_SUPPRESSION_MARKER

      # A `rigor:` marker word that is NOT part of Rigor's suppression grammar but reads like an attempted
      # suppression — the RuboCop-reflex spellings `rigor:disable-next-line <rules>` and
      # `rigor:enable <rules>`. These are invisible to both suppression patterns above (the hyphenated
      # suffix fails LINE_SUPPRESSION_PATTERN's `\s+` and BARE_SUPPRESSION_MARKER's lookahead), so without
      # surveillance they silently suppress nothing. Matches `disable-<suffix>` for any suffix other than
      # `file`, and `enable` with or without a suffix.
      UNKNOWN_SUPPRESSION_MARKER =
        /\A#\s*rigor:(?<marker>disable-(?!file(?![\w-]))[\w-]+|enable(?:-[\w-]+)?)(?![\w-])(?<rest>.*)/
      private_constant :UNKNOWN_SUPPRESSION_MARKER

      # @return [Array<(Hash{Integer => Set}, Set)>] pair of
      #   `(line_suppressions, file_suppressions)`. Line
      #   suppressions are keyed by source line number; file
      #   suppressions apply to every line.
      def parse_suppression_comments(comments)
        line_suppressions = Hash.new { |h, k| h[k] = Set.new }
        file_suppressions = Set.new
        comments.each do |comment|
          source = comment.location.slice
          if (match = FILE_SUPPRESSION_PATTERN.match(source))
            absorb_suppression_tokens(match[:rules], file_suppressions)
          elsif (match = LINE_SUPPRESSION_PATTERN.match(source))
            absorb_suppression_tokens(match[:rules], line_suppressions[comment.location.start_line])
          end
        end
        [line_suppressions, file_suppressions]
      end

      def absorb_suppression_tokens(raw, target)
        raw.to_s.split(/[\s,]+/).reject(&:empty?).each do |token|
          target.merge(expand_token(token))
        end
      end

      # PHPStan-`IgnoreParseErrorRule`-modelled surveillance over the suppression markers themselves: a
      # malformed or ineffective `# rigor:disable` / `# rigor:disable-file` comment must not silently no-op
      # (the typo'd `# rigor:disable call.undefined-metod` suppresses nothing and the user never learns).
      # Emits `suppression.unknown-rule` for every marker token that resolves to no known identifier, and
      # `suppression.empty` for a marker that lists no rules at all. The MATCHING semantics are deliberately
      # unchanged — an unknown token is still kept verbatim per the diagnostic-policy spec — so this is
      # additive surveillance only. Both diagnostics run before {.filter_suppressed} and flow through it,
      # so they are themselves suppressible (`# rigor:disable suppression.unknown-rule`) with no regress:
      # that token is known, so acknowledging it never re-fires the rule.
      def suppression_marker_diagnostics(path, comments)
        comments.each_with_object([]) do |comment, diagnostics|
          source = comment.location.slice
          if (match = FILE_SUPPRESSION_PATTERN.match(source))
            validate_suppression_tokens(match[:rules], "rigor:disable-file", path, comment, diagnostics)
          elsif (match = LINE_SUPPRESSION_PATTERN.match(source))
            validate_suppression_tokens(match[:rules], "rigor:disable", path, comment, diagnostics)
          else
            diagnose_bare_suppression_marker(path, comment, source, diagnostics)
          end
        end
      end

      def validate_suppression_tokens(raw, marker, path, comment, diagnostics)
        tokens = raw.to_s.split(/[\s,]+/).reject(&:empty?)
        if tokens.empty?
          diagnostics << empty_suppression_diagnostic(path, comment, marker)
          return
        end

        tokens.each do |token|
          next if known_suppression_token?(token)

          diagnostics << unknown_suppression_rule_diagnostic(path, comment, marker, token)
        end
      end

      # A comment carrying the marker word but not the token-bearing suppression grammar. A remainder of
      # nothing but whitespace / commas is a genuinely empty marker (`# rigor:disable`); anything else is
      # left alone as an ordinary comment, matching the parse path, which never treats it as a
      # suppression either. Prose that merely quotes a marker is already excluded a step earlier by the
      # `\A` anchor, since the quotation is not at the start of the comment.
      def diagnose_bare_suppression_marker(path, comment, source, diagnostics)
        bare = BARE_SUPPRESSION_MARKER.match(source)
        if bare
          return unless bare[:rest].match?(/\A[\s,]*\z/)

          marker = bare[:file] ? "rigor:disable-file" : "rigor:disable"
          diagnostics << empty_suppression_diagnostic(path, comment, marker)
          return
        end

        diagnose_unknown_suppression_marker(path, comment, source, diagnostics)
      end

      # `# rigor:disable-next-line <rule>` / `# rigor:enable <rule>` — a marker word Rigor's grammar does
      # not recognise but that reads as an attempted suppression (the RuboCop reflex). Fires only when the
      # marker opens the comment and the remainder is empty or looks like a rule list, so prose mentioning
      # the spelling in backticks stays an ordinary comment — the same escape the empty-marker detection
      # observes.
      def diagnose_unknown_suppression_marker(path, comment, source, diagnostics)
        unknown = UNKNOWN_SUPPRESSION_MARKER.match(source)
        return if unknown.nil?

        rest = unknown[:rest]
        return unless rest.match?(/\A[\s,]*\z/) || rest.match?(/\A\s+[\w.,\s-]+\z/)

        diagnostics << unknown_suppression_marker_diagnostic(path, comment, unknown[:marker])
      end

      # True when a suppression token resolves to a diagnostic identifier some producer can emit: a
      # canonical CheckRules id, a legacy alias, the `all` wildcard, a family wildcard, a bare
      # non-catalogue engine id, or a dotted id under a known non-check family (`rbs_extended.*`,
      # `dynamic.*`, `rbs.*`, `pre-eval.*`, and any `plugin.`-prefixed id — plugins load dynamically, so
      # their rule vocabulary cannot be enumerated here and under-warning is the FP-safe direction).
      def known_suppression_token?(token)
        return true if token == "all"
        return true if ALL_RULES.include?(token) || LEGACY_RULE_ALIASES.key?(token) ||
                       RULE_FAMILIES.include?(token) || NON_CHECK_DIAGNOSTIC_IDS.include?(token)

        family, rest = token.split(".", 2)
        !rest.nil? && NON_CHECK_DIAGNOSTIC_FAMILIES.include?(family)
      end

      def unknown_suppression_rule_diagnostic(path, comment, marker, token)
        Diagnostic.new(
          path: path,
          line: comment.location.start_line,
          column: comment.location.start_column + 1,
          message: "unknown rule `#{token}` in `# #{marker}` — the token matches no known rule, alias, " \
                   "or family, so this suppression has no effect. Likely a typo; `rigor explain <rule>` " \
                   "lists the canonical ids.",
          severity: :warning,
          rule: RULE_SUPPRESSION_UNKNOWN_RULE,
          source_family: :builtin
        )
      end

      def unknown_suppression_marker_diagnostic(path, comment, marker)
        Diagnostic.new(
          path: path,
          line: comment.location.start_line,
          column: comment.location.start_column + 1,
          message: "unrecognised suppression marker `rigor:#{marker}` — Rigor's markers are " \
                   "`# rigor:disable <rules>` (suppresses on its own line) and " \
                   "`# rigor:disable-file <rules>`, so this comment suppresses nothing.",
          severity: :warning,
          rule: RULE_SUPPRESSION_UNKNOWN_MARKER,
          source_family: :builtin
        )
      end

      def empty_suppression_diagnostic(path, comment, marker)
        Diagnostic.new(
          path: path,
          line: comment.location.start_line,
          column: comment.location.start_column + 1,
          message: "`# #{marker}` lists no rules, so this suppression has no effect. Name the rules to " \
                   "suppress (`# #{marker} call.undefined-method`) or use `# #{marker} all`.",
          severity: :warning,
          rule: RULE_SUPPRESSION_EMPTY,
          source_family: :builtin
        )
      end

      # Expands a list of user-supplied rule tokens into the
      # canonical-id set per ADR-8 § "Backward compatibility".
      # `disabled_rules` accepts unprefixed legacy names
      # (`undefined-method`), canonical names
      # (`call.undefined-method`), and family wildcards (`call`).
      def expand_rule_tokens(tokens)
        Array(tokens).each_with_object(Set.new) do |token, set|
          set.merge(expand_token(token.to_s))
        end
      end

      def expand_token(token)
        return ["all"] if token == "all"

        resolved = resolve_rule_token(token)
        resolved.nil? || resolved.empty? ? [token] : resolved
      end

      # rubocop:disable Metrics/ClassLength
      class << self
        private

        def undefined_method_diagnostic(path, call_node, scope_index) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          return nil if call_node.receiver.nil?

          scope = scope_index[call_node]
          return nil if scope.nil?

          # ADR-67 WD6b — an inferred-parameter receiver's type is an open-call-site lower bound; firing
          # undefined-method against it is an FP by construction. Decline.
          return nil if inferred_param_receiver?(call_node, scope)

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
          receiver_type = safe_navigation_receiver(call_node, scope)

          # #320 — the private-singleton-object idiom (`class << Merger = Object.new`). The body's methods
          # are recorded on the constant's own name, but the receiver reads back as `Object`, so the
          # class-keyed probes below cannot see them. Recover the name from the receiver syntax. Scoped to
          # the recorded name only: `Merger.nope` still fires.
          return nil if Inference::SingletonObjectConstant.recorded?(call_node, receiver_type, call_node.name, scope)

          class_name = concrete_class_name(receiver_type)
          # A union receiver has no single concrete class. The scalar path
          # below cannot reason about it, but the call is still definitely
          # undefined when EVERY arm lacks the method — see
          # `union_undefined_method_diagnostic`.
          return union_undefined_method_diagnostic(path, call_node, receiver_type, scope) if class_name.nil?

          # ADR-26 — a plugin may declare a class "open": one
          # known to respond beyond its RBS-declared method
          # surface (e.g. `ActiveRecord::Relation`, which
          # delegates an unbounded set of user-defined scopes to
          # its model). Flagging an undefined method on a class
          # with an open dynamic surface is unsound, so the rule
          # skips it.
          # An unbounded receiver surface: either a plugin-declared
          # open receiver (ADR-26 — e.g. `ActiveRecord::Relation`), or
          # a type Rigor synthesized (a missing-namespace module / a
          # stub for a referenced-but-undeclared type) to keep a
          # malformed project signature buildable. A synthesized stub's
          # method table is empty only because Rigor invented it, not
          # because the real type is empty (the real `DRb` has
          # `start_service`), so enumerating it to prove a call
          # "undefined" would be a false positive.
          return nil if unbounded_receiver_surface?(class_name, scope)

          # Slice 7 phase 12 — suppress when the user has
          # declared the method in source (`def` /
          # `define_method`) OR in a `pre_eval:` monkey-patch
          # file (ADR-17). Both paths are project-side method
          # contributions the dispatcher already resolved; the
          # rule must not surface a false `undefined-method`
          # for them.
          kind = receiver_type.is_a?(Type::Singleton) ? :singleton : :instance
          return nil if source_declared_method?(scope, class_name, call_node.name, kind)

          return nil unless Rigor::Reflection.rbs_class_known?(class_name, scope: scope)

          # When the loader cannot build a class definition for a
          # name it nominally knows (constant-decl aliases such
          # as `YAML` → `Psych`, or RBS-build failures for
          # malformed signatures), we cannot enumerate methods
          # so we MUST NOT emit a false positive. Skip the rule
          # in that case.
          return nil unless definition_available?(receiver_type, class_name, scope)

          method_def = lookup_method(receiver_type, class_name, call_node.name, scope)
          return nil if method_def

          # Module-mixin fallback (mirror of
          # `MethodDispatcher#user_class_fallback_receiver`'s module
          # path): an instance method on a module-mixin like
          # `PP::ObjectMixin` observes Kernel / Object methods
          # through every concrete includer's ancestor chain, so an
          # unresolved `self.inspect` / `self.respond_to?` /
          # `self.class` MUST NOT fire `undefined-method`. Retry
          # against Object before the rule fires.
          return nil if module_mixin_receiver?(receiver_type, scope) &&
                        lookup_method(receiver_type, "Object", call_node.name, scope)

          definition_site = project_definition_site(scope, class_name, call_node.name, kind)
          build_undefined_method_diagnostic(path, call_node, receiver_type, definition_site, class_name)
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

        def module_mixin_receiver?(receiver_type, scope)
          return false unless receiver_type.is_a?(Type::Nominal)
          return false if scope.environment.nil?

          scope.environment.rbs_module?(receiver_type.class_name)
        end

        # Combined suppression probe for `undefined-method` /
        # `unresolved-toplevel`. Returns true when the method is
        # declared by any project-side contributor the dispatcher
        # already resolves: an in-source `def` / `define_method`
        # (`scope.discovered_method?`) OR an ADR-17 `pre_eval:`
        # monkey-patch (`Environment#project_patched_methods`).
        # Both paths sit at the same dispatcher precedence; the
        # check must hold them together so neither rule fires a
        # false positive.
        def source_declared_method?(scope, class_name, method_name, kind)
          return true if scope.discovered_method?(class_name, method_name, kind)

          project_patched_method?(scope, class_name, method_name, kind)
        end

        # ADR-17 § "Inference contract" — consults
        # `Environment#project_patched_methods` so a `def` declared
        # in a `pre_eval:` file suppresses the diagnostic at the
        # same dispatcher precedence the registry holds for type
        # inference (between plugins and dependency-source).
        # Returns false when the environment carries no registry
        # (legacy path) or the lookup misses.
        def project_patched_method?(scope, class_name, method_name, kind)
          environment = scope.environment
          registry = environment&.project_patched_methods
          return false if registry.nil? || registry.empty?

          !registry.lookup(class_name: class_name.to_s, method_name: method_name.to_sym, kind: kind).nil?
        end

        # ADR-34 — `call.unresolved-toplevel`. Fires on an
        # implicit-self call (no explicit receiver) at toplevel
        # scope (`scope.toplevel?`, i.e. outside any class /
        # module body) whose name does not resolve against:
        #
        # 1. A same-file toplevel `def` via
        #    {Scope#top_level_def_for}.
        # 2. The ADR-17 `ProjectPatchedMethods` registry under
        #    `(Object, name, :instance)` — projects declare
        #    their toplevel-injecting monkey-patches in
        #    `.rigor.yml`'s `pre_eval:` array as the canonical
        #    opt-out per ADR-34 WD2.
        # 3. The standard `Kernel` / `Object` private-method
        #    surface (`puts`, `p`, `require`, `loop`, `raise`,
        #    …) drawn from the loaded RBS environment.
        #
        # The rule deliberately does NOT generalise to
        # implicit-self calls inside `def` / `class` / `module`
        # bodies — ADR-24 WD3's lenient-on-unresolved default
        # stays in force there. ADR-24 WD4's gated class-body
        # diagnostic is a separate decision this ADR does not
        # open.
        #
        # Authored severity is `:warning`; the severity profile
        # remaps it (`strict` → `:error`, `balanced` →
        # `:warning`, `lenient` → `:off` / suppressed).
        def unresolved_toplevel_diagnostic(path, call_node, scope_index)
          return nil unless call_node.receiver.nil?

          scope = scope_index[call_node]
          return nil if scope.nil?
          return nil unless scope.toplevel?

          name = call_node.name
          return nil if scope.top_level_def_for(name)
          return nil if source_declared_method?(scope, "Object", name, :instance)
          return nil if Rigor::Reflection.instance_method_definition("Object", name, scope: scope)

          build_unresolved_toplevel_diagnostic(path, call_node)
        end

        def build_unresolved_toplevel_diagnostic(path, call_node)
          Diagnostic.from_message_loc(
            call_node,
            path: path,
            message: "unresolved toplevel call to `#{call_node.name}`. " \
                     "If a project file defines `#{call_node.name}` via a toplevel " \
                     "`def` or a monkey-patch on Object/Kernel, list that file in " \
                     "`.rigor.yml`'s `pre_eval:` (ADR-17) so the analyzer sees it.",
            severity: :warning,
            rule: RULE_UNRESOLVED_TOPLEVEL,
            method_name: call_node.name.to_s
          )
        end

        # Returns a qualified class name for the in-scope check.
        # Nominal / Singleton carry a single-class identity
        # directly. Constant projects to its value's class.
        # Tuple projects to "Array" and HashShape to "Hash" so
        # arity / dispatch checks against the underlying class
        # still apply. Dynamic / Top / Union / Bot do not name a
        # single class and return nil to skip the rule.
        def concrete_class_name(type)
          case type
          when Type::Nominal, Type::Singleton then type.class_name
          when Type::Tuple then "Array"
          when Type::HashShape then "Hash"
          when Type::Constant then constant_class_name(type.value)
          # A refinement IS its base class for method dispatch — its method
          # surface is the base's. Resolve to the base so the call rules
          # (undefined-method / wrong-arity / argument-type-mismatch) reason
          # about it instead of bailing. `Type::Refined` carries string-family
          # refinements (`lowercase-string`, …) over an explicit `.base`;
          # `Type::IntegerRange` carries the bounded-int refinements
          # (`non-negative-int`, `positive-int`, `int<1,5>`), every one an
          # Integer; `Type::Difference` (`A - B`) carries the non-empty /
          # non-zero refinements (`non-empty-string` = `String - ""`,
          # `non-empty-array` = `Array - []`, `non-zero-int` = `Integer - 0`)
          # — subtracting values never changes the method surface, so the
          # base (minuend) class dispatches.
          when Type::Refined, Type::Difference then concrete_class_name(type.base)
          when Type::IntegerRange then "Integer"
          end
        end

        CONSTANT_CLASSES = {
          Integer => "Integer", Float => "Float", String => "String",
          Symbol => "Symbol", Range => "Range",
          TrueClass => "TrueClass", FalseClass => "FalseClass",
          NilClass => "NilClass"
        }.freeze
        private_constant :CONSTANT_CLASSES

        # ADR-67 WD6b — true when this call's receiver is *rooted at* a pristine inferred-parameter local (the
        # call-site union seeded at method entry). Every negative in-body rule (`call.undefined-method`,
        # wrong-arity, argument-type-mismatch, possible-nil, visibility) declines on such a receiver: an open
        # call-site set makes the inferred type a *lower bound*, so a diagnostic against it is a false positive
        # by construction (the same reasoning that keeps ADR-67 WD1 non-negotiable at the parameter boundary,
        # carried into the body). No-op on a normal `check` run — `inferred_param?` is false unless the
        # `parameter_inference:` gate seeded the table.
        def inferred_param_receiver?(call_node, scope)
          inferred_param_rooted?(call_node.receiver, scope)
        end

        # ADR-67 WD6b — the argument-position analogue: true when `arg` is rooted at an inferred-parameter
        # local. The argument-type-mismatch rule declines on it for the same lower-bound reason.
        def inferred_param_argument?(arg, scope)
          inferred_param_rooted?(arg, scope)
        end

        # ADR-67 WD6b — see {CheckRules::InferredParamGuard} for the shared root-walk contract.
        def inferred_param_rooted?(node, scope)
          InferredParamGuard.rooted?(node, scope)
        end

        def constant_class_name(value)
          CONSTANT_CLASSES.each { |klass, name| return name if value.is_a?(klass) }
          nil
        end

        # ADR-26 — whether `class_name` is declared "open" by a
        # loaded plugin (manifest `open_receivers:`). An open
        # class responds beyond its RBS surface, so the
        # `call.undefined-method` rule must not fire for it.
        # True when the receiver class responds beyond an enumerable
        # RBS method table, so proving a call "undefined" against it is
        # unsound: a plugin-declared open receiver, or a Rigor-
        # synthesized stub type (see `RbsLoader#synthesized_type_names`).
        def unbounded_receiver_surface?(class_name, scope)
          open_receiver?(class_name, scope) || synthesized_stub_receiver?(class_name, scope)
        end

        def open_receiver?(class_name, scope)
          registry = scope.environment&.plugin_registry
          return false if registry.nil?

          registry.open_receiver?(class_name)
        end

        def synthesized_stub_receiver?(class_name, scope)
          loader = scope.environment&.rbs_loader
          return false if loader.nil? || !loader.respond_to?(:synthesized_type_names)

          loader.synthesized_type_names.include?(class_name.to_s.sub(/\A::/, ""))
        end

        def definition_available?(receiver_type, class_name, scope)
          if receiver_type.is_a?(Type::Singleton)
            !Rigor::Reflection.singleton_definition(class_name, scope: scope).nil?
          else
            !Rigor::Reflection.instance_definition(class_name, scope: scope).nil?
          end
        end

        # ADR-24 slice 4 — `call.self-undefined-method`. Consumes the engine's
        # recorded unresolved implicit-self calls
        # ({Analysis::SelfCallResolutionRecorder}) and adds only the
        # closedness POLICY — it NEVER recomputes resolution (the reverted
        # attempt-1 mistake that produced 135 FPs). A miss reaches here only
        # because the engine's real resolution found the method nowhere.
        #
        # The v1 gate is deliberately the most conservative "confidently
        # closed" shape: a STANDALONE project class — no superclass and no
        # `include`/`prepend` (so its in-file method surface is complete) —
        # that is not a module / mixin contract, defines no `method_missing`,
        # has no dynamic `attr_*(*splat)` accessor, and is not an ADR-26 open
        # receiver. Widening to superclass / include chains is a later slice,
        # each behind the external corpus FP gate. Authored `:warning` but
        # mapped to `:off` in every shipped profile until that gate is green
        # (ADR-24 § "Slice 4"); a project opts in via `severity_overrides:`.
        def self_undefined_method_diagnostics(path, self_call_misses, root, scope_index)
          return [] if self_call_misses.empty?

          open_names = SelfClosednessScanner.new(root).open_class_names
          self_call_misses.filter_map do |miss|
            next if open_names.include?(miss.class_name)

            scope = scope_index[miss.node]
            next if scope.nil?
            next unless confidently_closed_self_class?(miss.class_name, scope)
            next if method_defined_on_known_subclass?(miss.class_name, miss.method_name, scope)

            build_self_undefined_method_diagnostic(path, miss)
          end
        end

        # ADR-24 slice 4 — subclass-aware gating (the abstract / template-method
        # base-class false positive the WD4 corpus eval surfaced). A base class
        # legitimately calls a method its subclasses implement
        # (`Mail::CommonField#decoded` calls `do_decode`, which
        # `Mail::UnstructuredField < CommonField` and its siblings define; the
        # same shape covers `Mail::Retriever#find` → POP3 / IMAP). When the
        # missed method is discovered on ANY known subclass of the self-class,
        # the call is a template-method hook, not a typo — suppress. Walks the
        # project subclass closure (the `discovered_superclasses` child→parent
        # map inverted, cycle-guarded). A pure narrowing — it only ever
        # suppresses a firing the closed-class gate would otherwise emit.
        def method_defined_on_known_subclass?(class_name, method_name, scope)
          supers = scope.discovered_superclasses
          seen = {}
          queue = direct_subclasses(class_name, supers)
          until queue.empty?
            subclass = queue.shift
            next if seen[subclass]

            seen[subclass] = true
            return true if method_known_on_class?(subclass, method_name, scope)

            queue.concat(direct_subclasses(subclass, supers))
          end
          false
        end

        # The directly-recorded subclasses of `class_name`. `discovered_superclasses`
        # keys the child fully-qualified (`Mail::POP3`) but records the parent
        # *as written* (`Retriever`), so a qualified miss class (`Mail::Retriever`)
        # is matched by resolving the parent name in the child's namespace.
        def direct_subclasses(class_name, discovered_superclasses)
          discovered_superclasses.filter_map { |child, parent| child if parent_matches?(child, parent, class_name) }
        end

        # Ruby constant lookup: a recorded parent `Retriever` on child
        # `Mail::POP3` resolves to `Mail::Retriever` (walk the child's namespace
        # prefixes, longest first), matched against the miss's fully-qualified
        # class name. Namespace-anchored, so it cannot match a same-named base in
        # an unrelated namespace.
        def parent_matches?(child, parent, class_name)
          parent_name = parent.to_s
          return true if parent_name == class_name

          segments = child.to_s.split("::")[0...-1]
          until segments.empty?
            return true if "#{segments.join('::')}::#{parent_name}" == class_name

            segments.pop
          end
          false
        end

        # Whether `method_name` is defined on `class_name` in the project — a
        # plain `def` (the def-node table) or a dynamic definition
        # (`define_method` / `attr_*` / `alias`). `discovered_method?` alone
        # misses plain defs, which is exactly what the abstract hooks are.
        def method_known_on_class?(class_name, method_name, scope)
          !scope.user_def_for(class_name, method_name).nil? ||
            scope.discovered_method?(class_name, method_name, :instance)
        end

        # ADR-24 slice 4 — the universal bases. A recorded self-call miss tagged
        # with one of these means the engine fell back to the root self-type
        # because it could NOT resolve the real class (a class-body macro context
        # where self is the Class object, top-level `main`, `instance_eval`, an
        # FFI / `define_method` metaprogramming surface). Their instance method
        # set is never "project-known and complete" — every object also responds
        # to whatever the unresolved real class adds — so a miss there is a
        # resolution gap, not a typo. This is the dominant false-positive class
        # the WD4 corpus eval surfaced (protobuf 73 / tdiary 199 / pycall 10 /
        # … FFI + class-macro calls, 287 firings across the corpus); excluding
        # it is a pure narrowing.
        SELF_UNDEFINED_UNIVERSAL_BASES = %w[Object BasicObject Kernel].to_set.freeze
        private_constant :SELF_UNDEFINED_UNIVERSAL_BASES

        def confidently_closed_self_class?(class_name, scope)
          return false if SELF_UNDEFINED_UNIVERSAL_BASES.include?(class_name)
          return false if unbounded_receiver_surface?(class_name, scope)
          return false if scope.discovered_method?(class_name, :method_missing, :instance)
          # A superclass or mixin extends the surface beyond what this file
          # declares; the engine's ancestor walk may have hit an unresolvable
          # ancestor, so a miss is not provably a typo. Defer to a later slice.
          return false if scope.superclass_of(class_name)
          return false unless scope.includes_of(class_name).empty?

          true
        end

        def build_self_undefined_method_diagnostic(path, miss)
          Diagnostic.new(
            path: path,
            line: miss.line || 1,
            column: miss.column || 1,
            message: "implicit-self call to `#{miss.method_name}` resolves to no method on " \
                     "`#{miss.class_name}` (a standalone class with a complete, project-known " \
                     "method surface). Likely a typo or a missing `def`.",
            severity: :warning,
            rule: RULE_SELF_UNDEFINED_METHOD,
            source_family: :builtin,
            receiver_type: miss.class_name,
            method_name: miss.method_name
          )
        end

        def lookup_method(receiver_type, class_name, method_name, scope)
          if receiver_type.is_a?(Type::Singleton)
            Rigor::Reflection.singleton_method_definition(class_name, method_name, scope: scope)
          else
            Rigor::Reflection.instance_method_definition(class_name, method_name, scope: scope)
          end
        rescue StandardError
          # The Reflection facade catches loader exceptions and
          # returns nil. The wrapper here treats failures as
          # "method exists" so we do NOT emit a false positive
          # when our knowledge of the receiver class is
          # structurally incomplete (Reflection's own rescue
          # already returns nil; this catch is a defensive
          # double-net for any future call shape that might
          # raise).
          true
        end

        # Slice 7 phase 11 — wrong-arity diagnostic. Fires when
        # an explicit-receiver `Prism::CallNode` resolves to a
        # method whose declared overloads do not admit the
        # supplied positional argument count. The rule applies
        # ONLY to the simplest overload shape (single overload,
        # no `rest_positionals`, no keyword parameters, no
        # block-required positionals); calls with `*splat`
        # arguments, keyword arguments, or block-pass arguments
        # are silently skipped to avoid false positives. The
        # check piggybacks on the same scope-index lookup used
        # by `undefined_method_diagnostic`; it returns nil
        # when the call's receiver / RBS coverage / call shape
        # disqualifies the rule.
        # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/AbcSize
        def wrong_arity_diagnostic(path, call_node, scope_index)
          return nil if call_node.receiver.nil?
          return nil unless plain_positional_call?(call_node)

          scope = scope_index[call_node]
          return nil if scope.nil?

          # ADR-67 WD6b — an inferred-parameter receiver's type is an open-call-site lower bound; a wrong-arity
          # firing against it is an FP by construction. Decline.
          return nil if inferred_param_receiver?(call_node, scope)

          receiver_type = scope.type_of(call_node.receiver)
          class_name = concrete_class_name(receiver_type)
          return nil if class_name.nil?

          kind = receiver_type.is_a?(Type::Singleton) ? :singleton : :instance
          # `Struct.new(:a, :b).new(...)` chained: the inner
          # `Struct.new(...)` is an anonymous Struct *subclass* whose
          # `.new` accepts any positional arity (one slot per member,
          # all defaulting to nil) — including zero. The receiver types
          # as `Singleton[Struct]` (so the call-site `.new` dispatches,
          # per the dispatcher's `struct_new_lift`), but validating that
          # `.new` against the real `Struct.new(*Symbol)` signature is a
          # false positive. Skip arity-checking the chained position.
          return nil if anonymous_struct_new_call?(call_node, class_name, kind)
          return nil if scope.discovered_method?(class_name, call_node.name, kind)

          return nil unless Rigor::Reflection.rbs_class_known?(class_name, scope: scope)
          return nil unless definition_available?(receiver_type, class_name, scope)

          method_def = lookup_method(receiver_type, class_name, call_node.name, scope)
          return nil if method_def.nil? || method_def == true

          arity_envelope = compute_arity_envelope(method_def)
          return nil if arity_envelope.nil?

          actual = (call_node.arguments&.arguments || []).size
          min, max = arity_envelope
          return nil if actual.between?(min, max)

          build_arity_diagnostic(path, call_node, class_name, min, max, actual)
        end
        # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/AbcSize

        # True for the outer `.new` of a chained `Struct.new(...).new`:
        # `class_name`/`kind` already pin the receiver to
        # `Singleton[Struct]`, and the receiver node is itself a
        # `Struct.new` (or `::Struct.new`) call — the anonymous subclass.
        def anonymous_struct_new_call?(call_node, class_name, kind)
          return false unless class_name == "Struct" && kind == :singleton
          return false unless call_node.name == :new

          receiver = call_node.receiver
          return false unless receiver.is_a?(Prism::CallNode) && receiver.name == :new

          inner = receiver.receiver
          return true if inner.is_a?(Prism::ConstantReadNode) && inner.name == :Struct

          # `::Struct.new(...).new` — a top-level constant path.
          inner.is_a?(Prism::ConstantPathNode) && inner.parent.nil? && inner.name == :Struct
        end

        def plain_positional_call?(call_node)
          arguments = call_node.arguments
          return true if arguments.nil?

          arguments.arguments.all? { |arg| simple_positional?(arg) }
        end

        def simple_positional?(arg)
          return false if arg.is_a?(Prism::SplatNode)
          return false if arg.is_a?(Prism::KeywordHashNode)
          return false if arg.is_a?(Prism::BlockArgumentNode)
          return false if arg.is_a?(Prism::ForwardingArgumentsNode)

          true
        end

        # Returns `[min, max]` positional-argument arity for the
        # method (across all overloads), or nil when the rule
        # does not apply. We disqualify only when the method
        # uses required keyword arguments (which the caller MUST
        # pass at the call site, and our plain-positional check
        # would not have caught) or trailing positionals (rare,
        # complex). `optional_keywords` and `rest_keywords` do
        # NOT affect positional arity. `rest_positionals` raises
        # `max` to `Float::INFINITY`.
        def compute_arity_envelope(method_def)
          mins = []
          maxes = []
          method_def.method_types.each do |mt|
            function = mt.type
            return nil unless arity_eligible?(function)

            min_arity = function.required_positionals.size
            max_arity =
              if function.rest_positionals
                Float::INFINITY
              else
                min_arity + function.optional_positionals.size
              end
            mins << min_arity
            maxes << max_arity
          end
          return nil if mins.empty?

          [mins.min, maxes.max]
        end

        def arity_eligible?(function)
          # `RBS::Types::UntypedFunction` (used for `(?) ->`
          # untyped sigs) does not expose the per-arity
          # accessors. Treating it as ineligible is the
          # correct conservative move: an untyped function
          # has no static arity to enforce.
          return false unless function.respond_to?(:required_keywords)

          function.required_keywords.empty? && function.trailing_positionals.empty?
        end

        # Slice 7 phase 14 — nil-receiver diagnostic. Fires when
        # the receiver type is a `Type::Union` containing a
        # nil-bearing member (`Constant[nil]` or
        # `Nominal[NilClass]`) AND the called method does not
        # exist on `NilClass`. This is the canonical "you forgot
        # to nil-check before calling X" signal: the engine has
        # proved that on at least one execution path the receiver
        # is nil, and the call would raise NoMethodError.
        #
        # The rule deliberately ignores receivers that are
        # exactly `Constant[nil]` / `Nominal[NilClass]` (those
        # are already covered by `undefined_method_diagnostic`)
        # and union receivers where every member already
        # disqualifies the call (avoid duplicating the
        # undefined-method diagnostic).
        def nil_receiver_diagnostic(path, call_node, scope_index)
          return nil if call_node.receiver.nil?
          # Safe-navigation calls (`recv&.method`) already
          # short-circuit on nil at runtime, so a nil-bearing
          # receiver is not a bug for them.
          return nil if call_node.safe_navigation?
          # Restrict to direct local-variable reads. Local
          # narrowing (Slice 6 phase 1) is the only narrowing
          # surface that can prove a guard like
          # `return if x.nil?` removed nil from the union, so
          # firing on chained / method-call receivers would
          # produce false positives we cannot suppress.
          return nil unless call_node.receiver.is_a?(Prism::LocalVariableReadNode)

          scope = scope_index[call_node]
          return nil if scope.nil?

          # ADR-58 WD1 — a receiver whose `nil` constituent is purely
          # declaration-sourced (the class-ivar index seed of a ctor
          # `@x = nil` written in another method, possibly copied into a
          # local via `r = @right`) does not fire by default: the working
          # program's cross-method invariant is assumed per the robustness
          # principle. The nil stays in the displayed type; only its use as
          # diagnostic fuel is withheld. Any flow-live touch (method-local
          # nil write, failed-guard narrowing) drops the mark upstream, so
          # flow-observed nil keeps firing exactly as before. The receiver
          # is already narrowed to a local read above, so this asks
          # {DeclarationSourcedGuard} exactly what it asked before — but it
          # now asks it through the predicate the argument-type gates share
          # (issue #324), which is what keeps the two rules from drifting.
          return nil if DeclarationSourcedGuard.marked?(call_node.receiver, scope)

          # ADR-67 WD6b — an inferred-parameter receiver's type (incl. any nil constituent unioned in from a
          # nil call site) is an open-call-site lower bound; a possible-nil firing against it is an FP by
          # construction. Decline.
          return nil if scope.inferred_param?(call_node.receiver.name)

          receiver_type = scope.type_of(call_node.receiver)
          return nil unless receiver_type.is_a?(Type::Union)

          # The rule only fires when the analyzer has access to
          # an RBS loader; without it, the per-member method-
          # presence checks below cannot rule out a sound call.
          return nil unless Rigor::Reflection.rbs_class_known?("NilClass", scope: scope)

          return nil unless nil_bearing_union_witnesses?(receiver_type, call_node.name, scope)

          build_nil_receiver_diagnostic(path, call_node)
        end

        # The receiver-type half of the rule, factored out of the node-shape
        # guards above: the union must carry nil, must carry a non-nil arm the
        # presence question can be asked of, must support the method on every
        # non-nil arm (so the call is only wrong on the nil path), and the
        # method must be absent from `NilClass` (so the nil path really raises).
        def nil_bearing_union_witnesses?(receiver_type, method_name, scope)
          union_contains_nil?(receiver_type) &&
            union_has_nameable_non_nil_arm?(receiver_type) &&
            union_method_present_on_non_nil?(receiver_type, method_name, scope) &&
            !nil_class_has_method?(method_name, scope)
        end

        def union_contains_nil?(union)
          union.members.any? { |member| nil_member?(member) }
        end

        # The receiver type the `call.undefined-method` existence check
        # should reason about. For a safe-navigation call whose receiver
        # types as exactly `nil`, this is `Type::Bot` — the call is
        # statically skipped at runtime, and `concrete_class_name(Bot)` is
        # nil so the rule bails (silent). Every other receiver (including a
        # `T | nil` union, which already has no single concrete class) flows
        # through unchanged.
        def safe_navigation_receiver(call_node, scope)
          receiver_type = scope.type_of(call_node.receiver)
          return receiver_type unless call_node.safe_navigation?
          return receiver_type unless nil_member?(receiver_type)

          Type::Combinator.bot
        end

        def nil_member?(member)
          (member.is_a?(Type::Constant) && member.value.nil?) ||
            (member.is_a?(Type::Nominal) && member.class_name == "NilClass")
        end

        # Possible-nil may witness only where the presence question below is
        # ANSWERABLE. `method_present_anywhere?` reports "present" for a
        # nameless arm (Dynamic / Top / Bot) — the permissive polarity the
        # union-undefined-method rule's FP safety rests on — so a union whose
        # non-nil arms are ALL nameless satisfied that gate vacuously and fired
        # on every method name, including names defined on no class anywhere.
        # That inverted the intent: the gate suppressed exactly where knowledge
        # exists (`String | nil` calling a nonexistent method stays silent) and
        # permitted exactly where none does. Requiring one nameable concrete
        # arm restores the polarity without touching the shared helper:
        # `String | nil` keeps firing, and so does `Dynamic | String | nil` —
        # the nameless arm stays permissive inside the all-arms check, which is
        # only about the arms' method surface.
        def union_has_nameable_non_nil_arm?(union)
          union.members.any? { |m| !nil_member?(m) && !concrete_class_name(m).nil? }
        end

        # The non-nil members must collectively support the
        # method (i.e. for every non-nil member, the method
        # exists on its class via RBS or in-source discovery).
        # Without this guard, the rule would also fire on calls
        # that are unsound on the non-nil branch — that is the
        # `undefined_method_diagnostic` rule's job, and we want
        # exactly one diagnostic per offending call site.
        def union_method_present_on_non_nil?(union, method_name, scope)
          non_nil_members = union.members.reject { |m| nil_member?(m) }
          return false if non_nil_members.empty?

          non_nil_members.all? { |m| method_present_anywhere?(m, method_name, scope) }
        end

        def method_present_anywhere?(member, method_name, scope)
          class_name = concrete_class_name(member)
          return true if class_name.nil? # Dynamic / Top / Bot — be permissive.
          return true if scope.discovered_method?(class_name, method_name, :instance)
          return true unless Rigor::Reflection.rbs_class_known?(class_name, scope: scope)
          return true unless definition_available?(member, class_name, scope)

          !lookup_method(member, class_name, method_name, scope).nil?
        end

        def nil_class_has_method?(method_name, scope)
          definition = Rigor::Reflection.instance_definition("NilClass", scope: scope)
          return false if definition.nil?

          !definition.methods[method_name.to_sym].nil?
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
        def union_undefined_method_diagnostic(path, call_node, receiver_type, scope)
          return nil unless receiver_type.is_a?(Type::Union)
          return nil if call_node.safe_navigation?

          members = receiver_type.members
          # Nil-bearing unions (`T | nil`) stay silent — the deliberate N3
          # decision (`safe_navigation_undefined_method_spec.rb`). A corpus FP
          # study of a bundled-arm-narrowed candidate (12 projects incl.
          # ActiveSupport-heavy) found ~zero real firings yet a demonstrated
          # loss-of-specificity false positive, so the silence is kept. See
          # ADR-62 and `docs/notes/20260613-mutation-teeth-harness.md`.
          return nil if members.any? { |member| nil_member?(member) }
          return nil if members.any? { |member| union_arm_blocks_undefined_fire?(member, scope) }
          # Only a genuinely multi-class union ("the value is an A or a B") gains
          # from this rule. A union whose arms all resolve to ONE class
          # (`Hash[K1, V1] | Hash[K2, V2]`) is a shape-join artifact — checking
          # method existence there is the scalar rule's job, and when the join is
          # a misinference it is a false positive (a corpus probe caught mail's
          # `compose_codepoints` typed `Hash | Hash` for an `Array`, flagging
          # `.pack`). Require at least two distinct arm classes.
          return nil if members.map { |member| concrete_class_name(member) }.uniq.size < 2
          return nil if members.any? { |member| method_present_anywhere?(member, call_node.name, scope) }

          build_undefined_method_diagnostic(path, call_node, receiver_type)
        end

        # An arm that makes a sound "undefined on every arm" verdict impossible: a non-class surface
        # (Dynamic / Top / Bot), a singleton (slice 1 reasons about instance arms only), the generic
        # metaclass `Class` / `Module` (a value typed as one is *some* class/module object whose singleton
        # methods cannot be enumerated from the metaclass — e.g. `plugin_class : Class` really holds a
        # `Plugin` subclass with `.manifest`), an unbounded receiver (ADR-26 open class or a synthesized
        # stub), or a module mixin whose Object-inherited methods the per-arm lookup would miss.
        METACLASS_ARMS = %w[Class Module].to_set.freeze
        private_constant :METACLASS_ARMS

        def union_arm_blocks_undefined_fire?(member, scope)
          class_name = concrete_class_name(member)
          return true if class_name.nil?
          return true if member.is_a?(Type::Singleton)
          return true if METACLASS_ARMS.include?(class_name)
          return true if unbounded_receiver_surface?(class_name, scope)

          module_mixin_receiver?(member, scope)
        end

        # Slice 7 phase 19 — PHPStan-style `dump_type(value)`. When the engine recognises a call to
        # `dump_type` (with any of the supported receiver shapes — implicit self after `include
        # Rigor::Testing`, `Rigor::Testing.dump_type`, or `Rigor.dump_type`), it emits an `:info` diagnostic
        # showing the inferred type of the argument expression. The diagnostic does NOT count toward
        # `Result#error_count` so a fixture peppered with `dump_type` calls still passes `rigor check`.
        def dump_type_diagnostic(path, call_node, scope_index)
          return nil unless rigor_testing_call?(call_node, :dump_type)
          return nil if call_node.arguments.nil? || call_node.arguments.arguments.empty?

          arg = call_node.arguments.arguments.first
          scope = scope_index[arg] || scope_index[call_node]
          return nil if scope.nil?
          return nil if inside_rigor_testing?(scope)

          type = scope.type_of(arg)
          Diagnostic.from_message_loc(
            call_node,
            path: path,
            message: "dump_type: #{type.describe(:short)}",
            severity: :info,
            rule: RULE_DUMP_TYPE
          )
        end

        # Slice 7 phase 19 — PHPStan-style `assert_type("...", value)`. The first argument MUST be a
        # string literal containing the expected `Type#describe(:short)` rendering. When the inferred
        # type's short description does not equal the expected literal, an `:error`-severity diagnostic is
        # emitted; matching calls produce no output. This lets a fixture document its expected types
        # inline: subsequent `rigor check` runs flag any drift.
        def assert_type_diagnostic(path, call_node, scope_index)
          return nil unless rigor_testing_call?(call_node, :assert_type)
          return nil if call_node.arguments.nil? || call_node.arguments.arguments.size < 2

          expected_node = call_node.arguments.arguments.first
          return nil unless expected_node.is_a?(Prism::StringNode)

          value_node = call_node.arguments.arguments[1]
          scope = scope_index[value_node] || scope_index[call_node]
          return nil if scope.nil?
          return nil if inside_rigor_testing?(scope)

          actual = scope.type_of(value_node).describe(:short)
          expected = expected_node.unescaped.to_s
          return nil if actual == expected

          build_assert_type_diagnostic(path, call_node, expected, actual)
        end

        # Recognises any of:
        #   `dump_type(x)`        (implicit self after `include Rigor::Testing`)
        #   `Testing.dump_type(x)`
        #   `Rigor.dump_type(x)`
        #   `Rigor::Testing.dump_type(x)`
        # The receiver check is purely structural — we do not consult RBS — because the helpers are no-op
        # stubs the user MAY shadow with their own definition; a name clash is the deliberate trade-off for
        # ergonomic invocation.
        RIGOR_TESTING_RECEIVERS = ["Rigor", "Rigor::Testing", "Testing"].freeze
        private_constant :RIGOR_TESTING_RECEIVERS

        # The dump/assert helpers' own implementation methods call back into `Testing.dump_type` /
        # `assert_type` to share the no-op runtime stub. We do NOT want those internal calls to surface
        # diagnostics — they are reflexive plumbing, not user assertions. This filter skips diagnostics
        # when the call site's `self_type` is the `Rigor` or `Rigor::Testing` module itself.
        SELF_REFERENTIAL_SCOPES = ["Rigor", "Rigor::Testing"].freeze
        private_constant :SELF_REFERENTIAL_SCOPES

        def inside_rigor_testing?(scope)
          self_type = scope.self_type
          return false if self_type.nil?
          return false unless self_type.respond_to?(:class_name)

          SELF_REFERENTIAL_SCOPES.include?(self_type.class_name)
        end

        def rigor_testing_call?(call_node, method_name)
          return false unless call_node.name == method_name

          receiver = call_node.receiver
          return true if receiver.nil?

          name = Source::ConstantPath.qualified_name_or_nil(receiver)
          return false if name.nil?

          RIGOR_TESTING_RECEIVERS.include?(name)
        end

        def build_assert_type_diagnostic(path, call_node, expected, actual)
          Diagnostic.from_message_loc(
            call_node,
            rule: RULE_ASSERT_TYPE,
            path: path,
            message: "assert_type mismatch: expected #{expected.inspect}, got #{actual.inspect}",
            severity: :error
          )
        end

        def build_nil_receiver_diagnostic(path, call_node)
          Diagnostic.from_message_loc(
            call_node,
            rule: RULE_NIL_RECEIVER,
            path: path,
            message: "possible nil receiver: `#{call_node.name}' is undefined on NilClass",
            severity: :error,
            method_name: call_node.name.to_s
          )
        end

        # Diagnoses calls that the analyzer can prove will always raise. Today the only triggering shape is
        # integer division/modulo by a literal zero divisor:
        #
        #   5 / 0          # => ZeroDivisionError
        #   x.modulo(0)    # => ZeroDivisionError when x: Integer
        #   xs.size % 0    # same — non_negative_int / Constant[0]
        #
        # Float divmod by zero returns Infinity/NaN at runtime, so the rule restricts to Integer-rooted
        # receivers (`Constant`, `IntegerRange`, `Nominal[Integer]`). The argument MUST be a
        # `Constant<Integer>` whose value is exactly zero — a `Union[Constant[0], Constant[2]]` divisor
        # "may" raise, which we surface separately (future slice).
        INTEGER_RAISING_OPERATORS = %i[/ % div modulo divmod].freeze
        private_constant :INTEGER_RAISING_OPERATORS

        def always_raises_diagnostic(path, call_node, scope_index)
          return nil unless integer_zero_division?(call_node, scope_index)

          build_always_raises_diagnostic(path, call_node)
        end

        def integer_zero_division?(call_node, scope_index)
          return false unless raising_call_shape?(call_node)

          scope = scope_index[call_node]
          return false if scope.nil?
          return false unless integer_rooted_for_diagnostic?(scope.type_of(call_node.receiver))

          arg = single_argument(call_node)
          arg && integer_zero_constant?(scope.type_of(arg))
        end

        def raising_call_shape?(call_node)
          !call_node.receiver.nil? && INTEGER_RAISING_OPERATORS.include?(call_node.name)
        end

        def single_argument(call_node)
          args = call_node.arguments&.arguments || []
          args.size == 1 ? args.first : nil
        end

        def integer_rooted_for_diagnostic?(type)
          case type
          when Type::Constant then type.value.is_a?(Integer)
          when Type::IntegerRange then true
          when Type::Nominal then type.class_name == "Integer" && type.type_args.empty?
          else false
          end
        end

        def integer_zero_constant?(type)
          type.is_a?(Type::Constant) && type.value.is_a?(Integer) && type.value.zero?
        end

        def build_always_raises_diagnostic(path, call_node)
          Diagnostic.from_message_loc(
            call_node,
            rule: RULE_ALWAYS_RAISES,
            path: path,
            message: "always raises ZeroDivisionError: `#{call_node.name}' by zero on Integer receiver",
            severity: :error
          )
        end

        # `call.raise-non-exception` — `raise x` / `fail x` where the first argument's statically-inferred
        # type is provably NOT a legal raise operand (PHPStan ThrowExprTypeRule analogue). Legal operands:
        # an Exception class object, an Exception instance, a String (raises RuntimeError), or any object
        # whose class defines `#exception` (the duck protocol `raise` consults at runtime). Anything else
        # (`raise 42`, `raise :sym`, `raise nil` — an explicit nil argument is a TypeError, unlike bare
        # `raise` which re-raises `$!`) raises TypeError at runtime.
        #
        # Conservative envelope (FP discipline):
        # - Implicit-self `raise` / `fail` only; an explicit-receiver call is a user method, not Kernel#raise.
        # - Silent when the project redefines `raise` / `fail` anywhere the call could resolve (a same-file
        #   toplevel def, an Object/Kernel monkey-patch, or a def on the enclosing class — in source or via
        #   `pre_eval:`).
        # - Only the first positional argument is checked; splat / kwargs / forwarded first args bail.
        # - Fires only on a concrete verdict: Dynamic / Top / unknown / unresolved types are silent, and a
        #   Union fires only when EVERY arm is independently illegal.
        # - A Class operand (`Type::Singleton`) is exact, so both `:disjoint` and `:superclass` orderings
        #   against Exception are provably illegal — but only when the class is RBS-known, not an ADR-26
        #   open receiver / synthesized stub, and its singleton defines no `exception` method.
        # - An instance operand's nominal class is NOT exact (a runtime subclass could define `#exception`
        #   or be an Exception), so only `:disjoint` fires, and the generic carriers (`Class` / `Module` /
        #   `Object` / `BasicObject`) plus module-typed values (any includer could be an Exception) bail.
        RAISE_METHOD_NAMES = %i[raise fail].freeze
        private_constant :RAISE_METHOD_NAMES

        # Instance types whose nominal class subsumes exception values (or class objects), so a "disjoint
        # from Exception" ordering proves nothing about the runtime value. `Object` / `BasicObject` order as
        # `:superclass` (already silent) but are listed for explicitness.
        RAISE_UNEXACT_INSTANCE_CLASSES = %w[Class Module Object BasicObject].freeze
        private_constant :RAISE_UNEXACT_INSTANCE_CLASSES

        def raise_non_exception_diagnostic(path, call_node, scope_index)
          return nil unless call_node.receiver.nil?
          return nil unless RAISE_METHOD_NAMES.include?(call_node.name)
          return nil unless call_node.block.nil?

          arg = first_positional_raise_operand(call_node)
          return nil if arg.nil?

          scope = scope_index[arg] || scope_index[call_node]
          return nil if scope.nil?
          return nil if raise_redefined_in_scope?(scope, call_node.name)

          operand_type = scope.type_of(arg)
          return nil unless raise_operand_verdict(operand_type, scope) == :illegal

          build_raise_non_exception_diagnostic(path, call_node, operand_type)
        end

        def first_positional_raise_operand(call_node)
          args = call_node.arguments&.arguments
          return nil if args.nil? || args.empty?

          first = args.first
          return nil if first.is_a?(Prism::SplatNode) || first.is_a?(Prism::KeywordHashNode) ||
                        first.is_a?(Prism::BlockArgumentNode) || first.is_a?(Prism::ForwardingArgumentsNode)

          first
        end

        # True when a project-side definition of `raise` / `fail` could shadow Kernel's at this call site:
        # a same-file toplevel def, a monkey-patch on Object / Kernel (in source or `pre_eval:`), or a def
        # on the enclosing class (instance or singleton side — implicit self dispatches to either depending
        # on context, and being silent for both is the cheap conservative answer).
        def raise_redefined_in_scope?(scope, name)
          return true if scope.top_level_def_for(name)
          return true if source_declared_method?(scope, "Object", name, :instance)
          return true if source_declared_method?(scope, "Kernel", name, :instance)

          self_type = scope.self_type
          return false unless self_type.respond_to?(:class_name)

          class_name = self_type.class_name
          return false if class_name.nil?

          source_declared_method?(scope, class_name, name, :instance) ||
            source_declared_method?(scope, class_name, name, :singleton)
        end

        # Trinary verdict — `:legal` / `:illegal` / `:unknown`. Only `:illegal` fires; anything the engine
        # cannot prove stays `:unknown` (silent).
        def raise_operand_verdict(type, scope)
          case type
          when Type::Union
            verdicts = type.members.map { |member| raise_operand_verdict(member, scope) }
            return :illegal if verdicts.all?(:illegal)

            verdicts.all?(:legal) ? :legal : :unknown
          when Type::Singleton
            raise_class_operand_verdict(type.class_name, scope)
          else
            raise_instance_operand_verdict(type, scope)
          end
        end

        # A `Type::Singleton` names ONE exact class / module object, so an ordering that places it outside
        # Exception's ancestry (`:disjoint`, or `:superclass` — e.g. `raise Object`) is a proof, provided
        # the singleton also lacks an `exception` method (`raise Klass` calls `Klass.exception`). A module
        # constant orders `:disjoint` and fires unless its singleton defines `exception`.
        def raise_class_operand_verdict(class_name, scope)
          return :unknown if class_name.nil? || scope.environment.nil?
          return :unknown if unbounded_receiver_surface?(class_name, scope)
          return :unknown if Rigor::Reflection.discovered_class?(class_name, scope: scope)
          return :unknown unless Rigor::Reflection.rbs_class_known?(class_name, scope: scope)

          case Rigor::Reflection.class_ordering(class_name, "Exception", scope: scope)
          when :equal, :subclass then :legal
          when :superclass, :disjoint
            raise_duck_exception?(class_name, :singleton, scope) ? :legal : :illegal
          else
            :unknown
          end
        end

        # An instance operand: legal when its class is String-family (raises RuntimeError) or an Exception
        # descendant; illegal only when the class is fully known, exact enough (not a generic metaclass /
        # module carrier), provably disjoint from BOTH, and defines no `#exception`. `:superclass` stays
        # silent — a value typed `Object` may well BE an Exception at runtime.
        def raise_instance_operand_verdict(type, scope)
          class_name = concrete_class_name(type)
          return :unknown if class_name.nil? || scope.environment.nil?
          return :unknown if RAISE_UNEXACT_INSTANCE_CLASSES.include?(class_name)
          return :unknown if unbounded_receiver_surface?(class_name, scope)
          # A project-declared class's ancestry must not be proven from RBS alone: a `sig/` declaration that
          # omits the superclass (`class Conflict` for a source-side `class Conflict < StandardError`)
          # defaults to Object in the RBS env, which would read as "disjoint from Exception" for a class
          # that IS one at runtime (the rule's first self-check firing, `Plugin::FactStore::Conflict`).
          # Source-discovered classes stay silent.
          return :unknown if Rigor::Reflection.discovered_class?(class_name, scope: scope)
          return :unknown unless Rigor::Reflection.rbs_class_known?(class_name, scope: scope)
          return :unknown if scope.environment.rbs_module?(class_name)

          string_ordering = Rigor::Reflection.class_ordering(class_name, "String", scope: scope)
          return :legal if %i[equal subclass].include?(string_ordering)

          case Rigor::Reflection.class_ordering(class_name, "Exception", scope: scope)
          when :equal, :subclass then :legal
          when :disjoint
            raise_duck_exception?(class_name, :instance, scope) ? :legal : :illegal
          else
            :unknown
          end
        end

        # Whether the class carries an `exception` method on the given side — from RBS, an in-source `def`,
        # or a `pre_eval:` patch. An unbuildable definition returns true (assume the duck) so structural
        # RBS gaps never manufacture a firing.
        def raise_duck_exception?(class_name, kind, scope)
          return true if source_declared_method?(scope, class_name, :exception, kind)

          definition = if kind == :singleton
                         Rigor::Reflection.singleton_definition(class_name, scope: scope)
                       else
                         Rigor::Reflection.instance_definition(class_name, scope: scope)
                       end
          return true if definition.nil?

          !definition.methods[:exception].nil?
        end

        def build_raise_non_exception_diagnostic(path, call_node, operand_type)
          Diagnostic.from_message_loc(
            call_node,
            rule: RULE_RAISE_NON_EXCEPTION,
            path: path,
            message: "`#{call_node.name}' operand types as #{operand_type.describe(:short)}, which is not " \
                     "an Exception class, an Exception instance, a String, or an object defining " \
                     "`#exception' — this raises TypeError at runtime",
            severity: :error,
            method_name: call_node.name.to_s
          )
        end

        # v0.1.2 — `flow.unreachable-branch`. Fires when an `IfNode` / `UnlessNode` whose predicate is a
        # literal `true` / `false` / `nil` (or a literal numeric / string / symbol whose Ruby truthiness is
        # known at-a-glance) has an observable dead branch. The diagnostic points at the dead branch (not
        # the predicate) so the squiggle lands on the code that never runs.
        #
        # Conservative envelope — by deliberate v0.1.2 design:
        # - Only **literal-shaped** predicates fire. Inferred-constant predicates (`x.method?` that happens
        #   to fold to `Constant<bool>`) are intentionally skipped — Rigor's loop / mutation /
        #   RBS-strictness modelling is incomplete enough that an inferred constant can be a false positive
        #   (e.g. accumulator `arr << x` doesn't widen the carrier; defensive `module.name.nil?` checks
        #   against anonymous-class nil that the RBS `Module#name -> String` sig hides). The literal-only
        #   envelope captures the clear "user wrote `if false`" case without false alarms.
        # - Empty dead branches (e.g. `if false; end` with no body) are skipped — there is no useful
        #   location to point at.
        # - Postfix-`if` / `unless` modifiers with a literal predicate ARE flagged (`expr if false` body
        #   never runs, exactly like the block form).
        # - Elsif chains (`subsequent` is itself an `IfNode`) ARE flagged — the entire downstream chain is
        #   unreachable when the outer predicate is a constant literal.
        #
        # Broadening to inferred-constant predicates is queued for a later v0.1.x release once the loop /
        # mutation gaps named above are closed.
        def unreachable_branch_diagnostic(path, node, scope_index)
          scope = scope_index[node]
          return nil if scope.nil?

          polarity = literal_predicate_polarity(node.predicate)
          return nil if polarity.nil?

          dead_branch = unreachable_branch_for(node, polarity == :truthy)
          return nil if dead_branch.nil?

          build_unreachable_branch_diagnostic(path, dead_branch, polarity)
        end

        # Returns `:truthy` / `:falsey` for a syntactically-literal predicate, or nil for anything else.
        # `TrueNode`, `FalseNode`, `NilNode` are the unambiguous cases. Numeric / string / symbol literals
        # are always truthy in Ruby (any non-`false` / non-`nil` value is truthy, including `0` and `""`).
        TRUTHY_LITERAL_NODES = [
          Prism::TrueNode, Prism::IntegerNode, Prism::FloatNode,
          Prism::StringNode, Prism::SymbolNode, Prism::RegularExpressionNode
        ].freeze
        private_constant :TRUTHY_LITERAL_NODES

        FALSEY_LITERAL_NODES = [Prism::FalseNode, Prism::NilNode].freeze
        private_constant :FALSEY_LITERAL_NODES

        def literal_predicate_polarity(predicate)
          return :truthy if TRUTHY_LITERAL_NODES.any? { |klass| predicate.is_a?(klass) }
          return :falsey if FALSEY_LITERAL_NODES.any? { |klass| predicate.is_a?(klass) }

          nil
        end

        # v0.1.2 — `def.method-visibility-mismatch`. Fires when an explicit-receiver `Prism::CallNode`
        # targets a user-class method whose `discovered_method_visibilities` entry is `:private`. The rule
        # is intentionally narrow:
        #
        # - Only `:private`. `:protected` access depends on subclass tracking the engine does not yet
        #   model; broadening waits for that surface.
        # - Only user classes whose visibility table the indexer built. RBS-known classes (stdlib, gems)
        #   are NOT consulted yet — RBS visibility is reliable but surfacing it would broaden the rule to a
        #   level the per-rule false-positive triage hasn't covered.
        # - Implicit-self calls are skipped (always allowed for private). Calls whose receiver is
        #   `Prism::SelfNode` are also skipped — Ruby 2.7+ permits `self.foo` for private methods.
        # - Receiver MUST resolve to a `Type::Nominal` so the rule has a single class identity to query.
        #   Unions / Dynamic / shape carriers are skipped.
        def visibility_mismatch_diagnostic(path, call_node, scope_index)
          return nil unless explicit_non_self_receiver?(call_node.receiver)

          scope = scope_index[call_node]
          return nil if scope.nil?

          # ADR-67 WD6b — an inferred-parameter receiver's nominal type is an open-call-site lower bound; a
          # private-method visibility firing against it is an FP by construction. Decline.
          return nil if inferred_param_receiver?(call_node, scope)

          receiver_type = scope.type_of(call_node.receiver)
          return nil unless receiver_type.is_a?(Type::Nominal)

          visibility = scope.discovered_method_visibility(receiver_type.class_name, call_node.name)
          return nil unless visibility == :private

          build_visibility_mismatch_diagnostic(path, call_node, receiver_type)
        end

        def explicit_non_self_receiver?(receiver)
          return false if receiver.nil?
          return false if receiver.is_a?(Prism::SelfNode)

          true
        end

        def build_visibility_mismatch_diagnostic(path, call_node, receiver_type)
          Diagnostic.from_message_loc(
            call_node,
            rule: RULE_VISIBILITY_MISMATCH,
            path: path,
            message: "private method `#{call_node.name}' called on #{receiver_type.class_name} receiver",
            severity: :error,
            receiver_type: receiver_type.class_name,
            method_name: call_node.name.to_s
          )
        end

        # Pulls a single concrete class name from an ivar write's rvalue type. Returns nil when the type is
        # too unstable to compare (Union / Dynamic / IntegerRange / etc.). `concrete_class_name` already
        # covers Nominal / Singleton / Constant / Tuple / HashShape; the wrapper exists so the ivar rule can
        # extend the envelope (or apply different filters) without disturbing the call rules.
        #
        # `TrueClass` / `FalseClass` are both normalised to `"bool"` here so the common boolean-flag idiom
        # (`@loaded = false` in `initialize` then `@loaded = true` on first work) doesn't fire the mismatch
        # rule. A real `bool → String` drift still trips because the second write's `ivar_class_for` returns
        # `"String"`.
        def ivar_class_for(type)
          name = concrete_class_name(type)
          return "bool" if %w[TrueClass FalseClass].include?(name)

          name
        end

        def build_always_truthy_condition_diagnostic(path, predicate_node, polarity)
          Diagnostic.from_node(
            predicate_node,
            rule: RULE_ALWAYS_TRUTHY_CONDITION,
            path: path,
            message: "condition is always #{polarity} (the surrounding flow proves it folds to a constant)",
            severity: :warning
          )
        end

        def build_unreachable_clause_diagnostic(path, result)
          Diagnostic.from_node(
            result.body,
            rule: RULE_UNREACHABLE_CLAUSE,
            path: path,
            message: unreachable_clause_message(result),
            severity: :warning
          )
        end

        def build_void_value_use_diagnostic(path, result)
          Diagnostic.from_node(
            result.void_node,
            rule: RULE_VALUE_USE_VOID,
            path: path,
            message: "value use of `void': `#{result.origin.label}' declares `-> void', so its return " \
                     "recovers to `top' and should not be used as a value",
            severity: :warning
          )
        end

        def unreachable_clause_message(result)
          subject = result.subject_name
          kw = result.keyword
          case result.kind
          when :prior_exhaustion
            "unreachable `#{kw} #{result.condition_source}': `#{subject}' is already covered " \
            "by an earlier `#{kw}' clause"
          when :exhausted_else
            "unreachable `else': the `#{kw}' clauses already cover every value `#{subject}' can take here"
          else # :disjoint
            "unreachable `#{kw} #{result.condition_source}': `#{subject}' can never be " \
            "#{result.condition_source} here (the flow proves the subject disjoint)"
          end
        end

        def build_shadowed_rescue_diagnostic(path, result)
          Diagnostic.from_node(
            result.clause,
            rule: RULE_SHADOWED_RESCUE_CLAUSE,
            path: path,
            message: shadowed_rescue_message(result),
            severity: :warning
          )
        end

        def shadowed_rescue_message(result)
          earlier = result.earlier_sources.each_with_index.map do |source, index|
            "`#{source}' (line #{result.earlier_lines[index]})"
          end
          "shadowed `#{result.clause_source}': every exception class it names is already caught " \
            "by the earlier #{earlier.join(' and ')} clause#{'s' if earlier.size > 1}, so this clause can never run"
        end

        def build_dead_assignment_diagnostic(path, write_node, def_node)
          Diagnostic.from_name_loc(
            write_node,
            rule: RULE_DEAD_ASSIGNMENT,
            path: path,
            message: "local `#{write_node.name}' assigned in `#{def_node.name}' but never read",
            severity: :warning
          )
        end

        # The diagnostic points at the LATER occurrence (the entry that wins at runtime) and names the
        # first occurrence's line, so the fix — delete or rename one of the two — is visible from the
        # message alone.
        def build_duplicate_hash_key_diagnostic(path, result)
          first_line = result[:first_key_node].location.start_line
          Diagnostic.from_node(
            result[:key_node],
            rule: RULE_DUPLICATE_HASH_KEY,
            path: path,
            message: "duplicate hash key `#{result[:key_label]}' in the same literal; this entry " \
                     "overwrites the value first set at line #{first_line}",
            severity: :warning
          )
        end

        def build_return_in_ensure_diagnostic(path, return_node)
          Diagnostic.from_location(
            return_node.keyword_loc,
            rule: RULE_RETURN_IN_ENSURE,
            path: path,
            message: "`return' inside `ensure' discards the method's in-flight return value " \
                     "and swallows any in-flight exception",
            severity: :warning
          )
        end

        def build_ivar_write_mismatch_diagnostic(path, node, class_name, ivar_name, first_class, other_class)
          Diagnostic.from_name_loc(
            node,
            rule: RULE_IVAR_WRITE_MISMATCH,
            path: path,
            message: "instance variable `#{ivar_name}' on #{class_name} was previously assigned " \
                     "#{first_class}; this write assigns #{other_class}",
            severity: :error
          )
        end

        # Returns the dead-branch node for a literal-predicate if/unless, or nil when no observable branch
        # is dead.
        def unreachable_branch_for(node, truthy)
          dead =
            case node
            when Prism::IfNode then truthy ? node.subsequent : node.statements
            when Prism::UnlessNode then truthy ? node.statements : node.else_clause
            end
          dead unless dead.nil?
        end

        def build_unreachable_branch_diagnostic(path, dead_branch, polarity)
          Diagnostic.from_node(
            dead_branch,
            rule: RULE_UNREACHABLE_BRANCH,
            path: path,
            message: "unreachable branch: literal predicate is always #{polarity}",
            severity: :warning
          )
        end

        # v0.0.2 #4 — argument-type-mismatch diagnostic.
        # Walks a call's positional arguments and checks each
        # against the matching parameter's RBS type via
        # `Rigor::Inference::Acceptance`. Emits an `:error`
        # for the first argument whose type the parameter
        # does NOT accept under the gradual mode.
        #
        # Conservative envelope (matches the wrong-arity rule
        # plus a few additional skips):
        # - Receiver must be Nominal / Singleton / Constant
        #   (the same `concrete_class_name` test).
        # - Method must be in RBS.
        # - Method must have exactly ONE method type
        #   (overload). Multi-overload checking is left for
        #   a follow-up because picking the "intended"
        #   overload requires the dispatcher's full
        #   acceptance plumbing.
        # - The selected overload must have NO
        #   rest_positionals, NO required keywords, NO
        #   trailing positionals.
        # - The call must use plain positional arguments
        #   (no splat / kw / block-pass / forwarded).
        # - Per-argument: skip when EITHER side is `Dynamic`
        #   (the call cannot be statically refuted).
        # Ruby's universal-equality methods accept any object
        # per the `Object#==(other) → bool` /
        # `Object#eql?(other) → bool` contract. Even when a
        # subclass overrides `==` to compare specific shapes
        # (URI::Generic#==(URI::Generic), Time#==(Time), …),
        # the runtime convention is to RETURN false for
        # type-mismatched arguments rather than raise. RBS sigs
        # that declare a tight parameter type therefore over-
        # specify; checking arguments against them produces
        # spurious mismatches such as
        #   `URI::Generic#==(URI::Generic)`
        #   called with `URI::HTTP | nil`
        # tdiary-core's `config_uri == referer_uri` (where
        # `referer_uri` is `URI.parse(...) if condition`, hence
        # union-with-nil) is the canonical case. Skip arg
        # checking on these methods entirely; the call is
        # well-formed by Ruby's contract.
        UNIVERSAL_EQUALITY_METHODS = %i[== != eql? equal? <=>].to_set.freeze
        private_constant :UNIVERSAL_EQUALITY_METHODS

        # ADR-64 WD1 — the binary arithmetic / bit / ordering operators
        # dispatch through Ruby's `coerce` protocol (and `<=>` for the
        # comparisons): `5 + Money.new` is valid at runtime because
        # `Integer#+` calls `Money#coerce(5)`, even though no RBS `Integer#+`
        # overload lists `Money`. A non-`Numeric` argument to them is therefore
        # NOT statically refutable — any user type may define `coerce` — so the
        # *non-nil* argument-type-mismatch channel excludes them (a fixed
        # allow-list, modelled on {UNIVERSAL_EQUALITY_METHODS}, not `coerce`
        # detection). `nil` never coerces, so the nil channel stays in force
        # here; the exclusion applies to the non-nil case only. `<=>` and the
        # `==` family are already excluded wholesale by
        # {UNIVERSAL_EQUALITY_METHODS}.
        COERCE_DISPATCH_METHODS = %i[+ - * / % ** & | ^ << >> < > <= >=].to_set.freeze
        private_constant :COERCE_DISPATCH_METHODS

        def argument_type_diagnostic(path, call_node, scope_index)
          return nil if call_node.receiver.nil?
          return nil if UNIVERSAL_EQUALITY_METHODS.include?(call_node.name)
          return nil unless plain_positional_call?(call_node)

          scope = scope_index[call_node]
          return nil if scope.nil?

          receiver_type = scope.type_of(call_node.receiver)
          class_name = concrete_class_name(receiver_type)
          return nil if class_name.nil?

          # NOTE: unlike the undefined-method / wrong-arity
          # rules, we deliberately do NOT skip when
          # `discovered_method?` matches. When the user
          # supplies BOTH a `def` and an RBS sig, the sig is
          # the authoritative parameter contract and we
          # should validate calls against it.
          return nil unless Rigor::Reflection.rbs_class_known?(class_name, scope: scope)
          return nil unless definition_available?(receiver_type, class_name, scope)

          method_def = lookup_method(receiver_type, class_name, call_node.name, scope)
          return nil if method_def.nil? || method_def == true

          param_overrides = Rigor::RbsExtended.param_type_override_map(method_def, environment: scope.environment)
          mismatch = argument_mismatch(method_def.method_types, call_node, scope, param_overrides)
          return nil if mismatch.nil?
          return nil if inferred_param_mismatch_verdict?(call_node, mismatch, scope)

          build_argument_type_diagnostic(path, call_node, class_name, mismatch)
        end

        # ADR-67 WD6b — an argument-type-mismatch verdict resting on an open-call-site lower bound, on
        # either side of the call. The ARGUMENT side: the mismatching argument is an inferred-parameter
        # local, so firing against it is an FP by construction. The RECEIVER side: when the receiver roots
        # at an inferred parameter, the method whose parameter contract the argument was checked against
        # was itself resolved through a lower-bound type, so the whole verdict is speculative. The 2026-07-30
        # self-check surfaced the receiver half as a guard hole: seeding `env : RBS::Environment` activated
        # this rule on `env.unload(culprits)` and flagged a correct Array argument against `unload`'s
        # declared `Set[Pathname]` — an upstream signature stricter than its implementation, exactly the FP
        # class WD6b exists to suppress. The other guarded rules already declined on a param-rooted
        # receiver; this brings argument-type-mismatch in line.
        def inferred_param_mismatch_verdict?(call_node, mismatch, scope)
          inferred_param_argument?(mismatch[:node], scope) || inferred_param_receiver?(call_node, scope)
        end

        # Single overload → the exact per-argument acceptance (unchanged).
        # Multiple overloads → the nil channel (a pure-`nil` argument every
        # overload rejects) plus, on non-coerce methods, the non-nil channel
        # (a single-concrete-class argument every overload rejects). See
        # {#multi_overload_argument_mismatch}.
        def argument_mismatch(method_types, call_node, scope, param_overrides)
          if method_types.size == 1
            first_argument_mismatch(method_types.first, call_node, scope, param_overrides)
          else
            multi_overload_argument_mismatch(method_types, call_node, scope, param_overrides)
          end
        end

        # Multi-overload argument-type-mismatch. The dispatcher's per-overload
        # acceptance plumbing is not run here; instead the FP-safe shape mirrors
        # the "absent on every arm" union-undefined-method rule: an argument is
        # a mismatch only when EVERY overload's matching positional param
        # rejects it.
        #
        # Two channels, both gated on a positively-refuted argument:
        # - **nil** (any method): a pure `nil` no overload admits is a
        #   guaranteed `TypeError` — `nil` never coerces.
        # - **non-nil** (ADR-64, non-coerce methods only): an argument that
        #   types to a single concrete RBS-known class that no overload admits.
        #   Excludes {COERCE_DISPATCH_METHODS} (`5 + Money.new` is valid via
        #   `coerce`), restricts to a single concrete class (WD3 — a union arg
        #   stays deferred), and decides acceptance on the RBS param type
        #   ({#param_accepts_arg_class?}) so it sees through the `int` / `string`
        #   interface-aliases the translator degrades.
        def multi_overload_argument_mismatch(method_types, call_node, scope, param_overrides)
          functions = method_types.map(&:type)
          return nil unless functions.all? { |function| argument_check_eligible?(function) }

          coerce_method = COERCE_DISPATCH_METHODS.include?(call_node.name)
          arguments = call_node.arguments&.arguments || []
          arguments.each_with_index do |arg, index|
            arg_type = scope.type_of(arg)
            params = overload_positional_params(method_types, index)
            next if params.nil? # arity divergence — some overload lacks a param here

            mismatch =
              if nil_member?(arg_type) # pure nil only — not a `T | nil` union
                nil_arg_overload_mismatch(arg, arg_type, params, param_overrides, scope)
              elsif !coerce_method
                non_nil_arg_overload_mismatch(arg, arg_type, params, param_overrides, scope)
              end
            return mismatch if mismatch
          end
          nil
        end

        # The nil channel: a pure `nil` argument no overload admits (ADR-58
        # parity excuses a declaration-sourced ivar nil).
        def nil_arg_overload_mismatch(arg, arg_type, params, param_overrides, scope)
          return nil if declaration_sourced_nil_argument?(arg, scope)
          return nil if params.any? { |param| param_admits_nil?(param, param_overrides, scope) }

          { node: arg, name: nil, expected: overload_param_expected_label(params), actual: arg_type }
        end

        # The non-nil channel (ADR-64 WD2/WD3): a single-concrete-class
        # argument no overload admits, on a non-coerce method.
        def non_nil_arg_overload_mismatch(arg, arg_type, params, param_overrides, scope)
          return nil unless single_concrete_arg_class?(arg_type, scope)
          return nil if params.any? { |param| param_accepts_arg_class?(param, arg_type, param_overrides, scope) }

          { node: arg, name: nil, expected: overload_param_expected_label(params), actual: arg_type }
        end

        # The matching positional RBS param across every overload, or nil when
        # any overload has no param at `index` (arity divergence — the
        # wrong-arity rule's concern, not this one's).
        def overload_positional_params(method_types, index)
          params = method_types.map do |method_type|
            function = method_type.type
            param = (function.required_positionals + function.optional_positionals)[index]
            param && resolve_param_bounds(param, method_type)
          end
          params.any?(&:nil?) ? nil : params
        end

        # Substitutes each bounded method-level type parameter for its bound, so
        # `[I < _ToInt] (I index) -> …` is walked as `(_ToInt index) -> …`. A bare
        # `Variable` is undecidable to the acceptance walk and admits everything,
        # which silently disables both channels for the whole overload; the bound
        # constrains the argument exactly as an ordinary param of that type would.
        # Load-bearing since rbs 4.1 rewrote core signatures into this form
        # (`Array#fetch`'s block overload is `[I < _ToInt, T] (I index) { … }`).
        def resolve_param_bounds(param, method_type)
          bounded = method_type.type_params.select(&:upper_bound)
          return param if bounded.empty?

          substitution = RBS::Substitution.build(bounded.map(&:name), bounded.map(&:upper_bound))
          param.map_type { |type| type.sub(substitution) }
        end

        # The class names whose instances `nil` IS — `NilClass` and every
        # ancestor. A parameter typed as any other class instance rejects nil.
        NIL_COMPATIBLE_CLASS_NAMES = %w[NilClass Object BasicObject Kernel].to_set.freeze
        private_constant :NIL_COMPATIBLE_CLASS_NAMES

        # Does this parameter admit a `nil` argument? Decided on the RBS
        # parameter type (a `rigor:v1:param` override takes precedence).
        # Conservative throughout: any case we cannot decide returns true
        # (admits → do not fire), so the rule never fires on uncertainty.
        def param_admits_nil?(param, param_overrides, scope)
          override = param_overrides[param.name]
          return rigor_type_admits_nil?(override) if override

          rbs_type_admits_nil?(param.type, scope)
        end

        # The `rigor:v1:param` override variant — a refinement
        # (`non-empty-string`) rejects nil; an explicit nil / nilable union /
        # gradual override admits it.
        def rigor_type_admits_nil?(type)
          return true if type.is_a?(Type::Dynamic) || type.is_a?(Type::Top)
          return true if nil_member?(type)
          return union_contains_nil?(type) if type.is_a?(Type::Union)

          false
        end

        # Walks the RBS parameter type. The load-bearing cases are `Alias`
        # (`string` = `String | _ToStr`) and `Interface` (`_ToStr`), which
        # {Inference::RbsTypeTranslator} degrades to `untyped` — the reason a
        # `nil` argument is invisible after translation (the interface-alias
        # gap). Resolving them here recovers the rejection. Only a concrete
        # class instance that is not a `nil` ancestor, and an interface
        # NilClass does not satisfy, return false; everything else admits.
        def rbs_type_admits_nil?(rbs_type, scope)
          case rbs_type
          when RBS::Types::Union then rbs_type.types.any? { |member| rbs_type_admits_nil?(member, scope) }
          when RBS::Types::Alias
            expanded = scope.environment&.rbs_loader&.expand_type_alias(rbs_type)
            expanded.nil? || rbs_type_admits_nil?(expanded, scope)
          when RBS::Types::ClassInstance
            NIL_COMPATIBLE_CLASS_NAMES.include?(rbs_type.name.to_s.delete_prefix("::"))
          when RBS::Types::Interface then interface_admits_nil?(rbs_type, scope)
          else true # Optional / bases / variable / tuple / record / proc / literal / intersection → conservative admit
          end
        end

        # An interface parameter (`_ToStr`) admits nil only when NilClass
        # implements every method it requires (`to_str`, `to_int`, … — which
        # NilClass does not, so `string` / `int` params reject nil; a
        # hypothetical `_ToS` would admit, since NilClass#to_s exists).
        # Unresolvable → conservative true.
        def interface_admits_nil?(rbs_type, scope)
          loader = scope.environment&.rbs_loader
          return true if loader.nil?

          methods = loader.interface_method_names(rbs_type.name.to_s)
          return true if methods.nil? || methods.empty?

          methods.all? { |method_name| nil_class_has_method?(method_name, scope) }
        end

        # ADR-64 WD3 — the non-nil channel fires only on an argument that types
        # to a single concrete, RBS-known class. A union arg mirrors the
        # union-receiver story and stays deferred; a class/module object
        # (`Singleton`) has a special acceptance surface and is skipped; a
        # non-RBS project class is skipped because its conversion protocol (a
        # duck-typed `to_int` / `to_str`) is invisible to us, so we cannot
        # refute acceptance.
        def single_concrete_arg_class?(arg_type, scope)
          return false if arg_type.is_a?(Type::Union)
          return false if arg_type.is_a?(Type::Singleton)

          class_name = concrete_class_name(arg_type)
          return false if class_name.nil?

          Rigor::Reflection.rbs_class_known?(class_name, scope: scope)
        end

        # ADR-64 WD2 — does this parameter accept the (non-nil) argument?
        # The non-nil generalization of {#param_admits_nil?}: decided on the RBS
        # parameter type (a `rigor:v1:param` override takes precedence) so it
        # sees through the `int` / `string` interface-aliases the translator
        # degrades to gradual. Conservative throughout — any case we cannot
        # decide returns true (accepts → do not fire).
        def param_accepts_arg_class?(param, arg_type, param_overrides, scope)
          override = param_overrides[param.name]
          return rigor_type_accepts_arg?(override, arg_type) if override

          rbs_type_accepts_arg?(param.type, arg_type, scope)
        end

        # The `rigor:v1:param` override variant — a Rigor `Type`, so the
        # acceptance engine decides directly (gradual; only a proven rejection
        # refutes). Dynamic / Top admit unconditionally.
        def rigor_type_accepts_arg?(param_type, arg_type)
          return true if param_type.is_a?(Type::Dynamic) || param_type.is_a?(Type::Top)

          !Inference::Acceptance.accepts(param_type, arg_type, mode: :gradual).no?
        end

        # Walks the RBS parameter type, mirroring {#rbs_type_admits_nil?}. The
        # load-bearing cases are `Alias` / `Interface` (`int` = `Integer |
        # _ToInt`), which the translator degrades to gradual — resolving them
        # here recovers the rejection. A faithfully-translated `ClassInstance`
        # is handed to the acceptance engine; everything undecidable admits.
        def rbs_type_accepts_arg?(rbs_type, arg_type, scope)
          case rbs_type
          when RBS::Types::Union then rbs_type.types.any? { |member| rbs_type_accepts_arg?(member, arg_type, scope) }
          when RBS::Types::Alias
            expanded = scope.environment&.rbs_loader&.expand_type_alias(rbs_type)
            expanded.nil? || rbs_type_accepts_arg?(expanded, arg_type, scope)
          when RBS::Types::ClassInstance then class_instance_accepts_arg?(rbs_type, arg_type, scope)
          when RBS::Types::Interface then interface_accepts_arg?(rbs_type, arg_type, scope)
          else true # bases / variable / tuple / record / proc / literal / intersection / optional → conservative admit
          end
        end

        # A `ClassInstance` param (`Integer`, `Numeric`, …) is translated
        # faithfully (no interface degradation), so the acceptance engine — the
        # canonical RBS-ancestry / generic-aware subtype check — decides it.
        # Only a proven rejection refutes; an unresolvable class is `:maybe`,
        # which admits.
        def class_instance_accepts_arg?(rbs_type, arg_type, scope)
          translated = translate_param_type(rbs_type, scope.environment)
          return true if translated.is_a?(Type::Dynamic) || translated.is_a?(Type::Top)

          !Inference::Acceptance.accepts(translated, arg_type, mode: :gradual).no?
        end

        # An interface param (`_ToInt`) accepts the arg only when the arg's
        # class implements every method it requires (`to_int`, …). The non-nil
        # mirror of {#interface_admits_nil?}: ask the arg class, not NilClass.
        # Unresolvable anywhere → conservative true (admit).
        def interface_accepts_arg?(rbs_type, arg_type, scope)
          loader = scope.environment&.rbs_loader
          return true if loader.nil?

          methods = loader.interface_method_names(rbs_type.name.to_s)
          return true if methods.nil? || methods.empty?

          class_name = concrete_class_name(arg_type)
          return true if class_name.nil?

          methods.all? { |method_name| arg_class_has_method?(class_name, method_name, scope) }
        end

        # The non-nil mirror of {#nil_class_has_method?}, but conservative on
        # the unknown side: an unresolvable definition returns true (the class
        # *might* implement the method — e.g. a metaprogrammed conversion), so
        # the channel never fires on uncertainty.
        def arg_class_has_method?(class_name, method_name, scope)
          definition = Rigor::Reflection.instance_definition(class_name, scope: scope)
          return true if definition.nil?

          !definition.methods[method_name.to_sym].nil?
        end

        # A readable "expected" label for a multi-overload mismatch — the RBS
        # parameter type(s) as written (`string`, or the per-overload set), since
        # the translated Rigor type degrades the interface-alias the rejection
        # hinges on. Shared by the nil and non-nil channels.
        def overload_param_expected_label(params)
          params.map { |param| param.type.to_s.delete_prefix("::") }.uniq.join(" | ")
        end

        # ADR-58 parity for the nil channel: a declaration-sourced read that
        # types as nil is the same not-diagnostic-fuel case the union path
        # gates in {#declaration_sourced_nil_only_mismatch?}; suppress it here
        # too so a ctor-seeded `@x = nil` read passed as an argument does not
        # fire on a working program's cross-method invariant. Issue #324 —
        # delegates to {DeclarationSourcedGuard}, so a local copy of the ivar
        # (`c = @count`) is excused on the same terms `possible-nil-receiver`
        # already excused it.
        def declaration_sourced_nil_argument?(arg, scope)
          DeclarationSourcedGuard.marked?(arg, scope)
        end

        def first_argument_mismatch(method_type, call_node, scope, param_overrides)
          function = method_type.type
          return nil unless argument_check_eligible?(function)

          params = function.required_positionals + function.optional_positionals
          arguments = call_node.arguments&.arguments || []
          arguments.each_with_index do |arg, index|
            param = params[index]
            next if param.nil? # arity mismatch is the wrong-arity rule's concern.

            mismatch = single_argument_mismatch(param, arg, scope, param_overrides)
            return mismatch if mismatch
          end
          nil
        end

        # The mismatch (or nil) for one positional argument against one
        # parameter. The nil channel decides a pure `nil` argument on the RBS
        # parameter type — seeing through the `string` / `int` interface-alias
        # the translator degrades to gradual (so `"a" + nil` fires), excusing a
        # declaration-sourced ivar nil (ADR-58 parity). The non-nil channel is
        # the original translated-acceptance check, with a `rigor:v1:param`
        # override taking precedence over the RBS-declared type.
        def single_argument_mismatch(param, arg, scope, param_overrides)
          arg_type = scope.type_of(arg)

          if nil_member?(arg_type)
            return nil if declaration_sourced_nil_argument?(arg, scope)
            return nil if param_admits_nil?(param, param_overrides, scope)

            return { node: arg, name: param.name, expected: overload_param_expected_label([param]), actual: arg_type }
          end

          param_type = param_overrides[param.name] || translate_param_type(param.type, scope.environment)
          return nil if param_type.is_a?(Type::Dynamic) || param_type.is_a?(Type::Top)
          return nil if arg_type.is_a?(Type::Dynamic) || arg_type.is_a?(Type::Top)
          return nil unless argument_genuinely_mismatches?(arg, arg_type, param_type, scope)

          { node: arg, name: param.name, expected: param_type, actual: arg_type }
        end

        # The parameter rejects the argument AND the rejection is not a
        # withheld declaration-sourced-nil case.
        def argument_genuinely_mismatches?(arg, arg_type, param_type, scope)
          return false unless Inference::Acceptance.accepts(param_type, arg_type, mode: :gradual).no?

          # ADR-58 (N2 extension) — the same declaration-sourced-nil-is-not-
          # diagnostic-fuel criterion that governs `possible-nil-receiver`
          # applies here. When the only reason the argument is rejected is a
          # *declaration-sourced* nil constituent (the class-ivar index seed
          # of a ctor `@x = nil` / a non-definitely-assigned ivar read), and
          # the argument type with that nil removed WOULD be accepted, the
          # working program's cross-method invariant is assumed and we do not
          # fire. Flow-live nil (a method-local `@x = nil` write, a failed-
          # guard narrowing) drops the provenance mark upstream and still
          # fires. The argument's type is unchanged — only the firing
          # decision is gated.
          !declaration_sourced_nil_only_mismatch?(arg, arg_type, param_type, scope)
        end

        # True when `arg` is a declaration-sourced read whose rejection is
        # caused solely by its nil constituent: stripping nil from the argument
        # type yields a type the parameter accepts (gradual mode). Mirrors the
        # `possible-nil-receiver` WD1 gate — since issue #324 through the very
        # same {DeclarationSourcedGuard} predicate, so the ivar read and its
        # local copy (`c = @count`) are one case rather than two spellings that
        # can drift apart again.
        def declaration_sourced_nil_only_mismatch?(arg, arg_type, param_type, scope)
          return false unless DeclarationSourcedGuard.marked?(arg, scope)
          return false unless arg_type.is_a?(Type::Union)
          return false unless union_contains_nil?(arg_type)

          non_nil = Type::Combinator.union(*arg_type.members.reject { |m| nil_member?(m) })
          return false if non_nil.is_a?(Type::Bot)

          Inference::Acceptance.accepts(param_type, non_nil, mode: :gradual).yes?
        end

        def argument_check_eligible?(function)
          # See `arity_eligible?`: `UntypedFunction` lacks
          # the per-arity accessors. Treat it as ineligible
          # for argument-type-mismatch diagnostics.
          return false unless function.respond_to?(:required_keywords)

          function.rest_positionals.nil? &&
            function.required_keywords.empty? &&
            function.optional_keywords.empty? &&
            function.rest_keywords.nil? &&
            function.trailing_positionals.empty?
        end

        def translate_param_type(rbs_type, _environment)
          Inference::RbsTypeTranslator.translate(rbs_type)
        rescue StandardError
          Type::Combinator.untyped
        end

        def build_argument_type_diagnostic(path, call_node, class_name, mismatch)
          method_label = "`#{call_node.name}' on #{class_name}"
          parameter_label = mismatch[:name] ? "parameter `#{mismatch[:name]}' of #{method_label}" : method_label
          expected = mismatch[:expected]
          expected_description = expected.is_a?(String) ? expected : expected.describe(:short)
          message = "argument type mismatch at #{parameter_label}: " \
                    "expected #{expected_description}, " \
                    "got #{mismatch[:actual].describe(:short)}"
          Diagnostic.from_node(
            mismatch[:node],
            rule: RULE_ARGUMENT_TYPE,
            path: path,
            message: message,
            severity: :error,
            receiver_type: class_name,
            method_name: call_node.name.to_s
          )
        end

        def build_arity_diagnostic(path, call_node, class_name, min, max, actual)
          range = min == max ? min.to_s : "#{min}..#{max}"
          method_label = "`#{call_node.name}' on #{class_name}"
          message = "wrong number of arguments to #{method_label} (given #{actual}, expected #{range})"
          Diagnostic.from_message_loc(
            call_node,
            rule: RULE_WRONG_ARITY,
            path: path,
            message: message,
            severity: :error,
            receiver_type: class_name,
            method_name: call_node.name.to_s
          )
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

        # ADR-8 § "`def.return-type-mismatch` rule" — flags a `def m(...) ... end` whose body's last
        # expression's type cannot satisfy the RBS-declared return type. Conservative envelope (v0.1.x
        # first cut):
        #
        # - Skips methods without an RBS declaration. The rule has no contract to compare against for
        #   source-only methods.
        # - Skips methods whose enclosing class isn't a `Type::Singleton` self_type that we can name
        #   (top-level / module-level methods land outside the rule).
        # - Skips methods whose body's last expression is absent or types as `Dynamic[top]` (the
        #   analyzer's fail-soft fallback) — emitting on `Dynamic[top]` would be noise.
        # - Compares the inferred body type against the declared return via `accepts?`:
        #     :yes   → silent
        #     :no    → emit at :error (severity_profile may re-stamp; default `balanced` keeps the
        #              authored severity).
        #     :maybe → emit at :warning. Promoted to :error under `severity_profile: strict` per ADR-8 §
        #              "Severity profile".
        def return_type_mismatch_diagnostic(path, def_node, scope_index)
          return nil if def_node.body.nil?

          last_expr = body_last_expression(def_node.body)
          return nil if last_expr.nil?

          inner_scope = scope_index[last_expr] || scope_index[def_node.body] || scope_index[def_node]
          return nil if inner_scope.nil?

          declared = declared_return_type(def_node, scope_index)
          return nil if declared.nil?

          inferred = inner_scope.type_of(last_expr)
          return nil if dynamic_top?(inferred)

          severity = compare_return(declared, inferred)
          return nil if severity.nil?

          build_return_type_mismatch_diagnostic(path, def_node, declared, inferred, severity)
        end

        # The body of a `def` is the last `Prism::StatementsNode` child (or a single expression for
        # one-liner defs). Take the last statement; that's the implicit return.
        def body_last_expression(body)
          case body
          when Prism::StatementsNode then body.body.last
          when Prism::BeginNode then body_last_expression(body.statements)
          else body
          end
        end

        # Pulls the declared RBS return type for the def. The enclosing class name comes from the def's
        # scope's `self_type`; the method name is on the def itself. `def self.foo` is a singleton method
        # — dispatched through `Reflection.singleton_method_definition`; plain `def foo` uses
        # `instance_method_definition`. Method overloads contribute their union of declared return types
        # (any one of them satisfying the body silences the rule).
        #
        # v0.1.2 — when the RBS sig carries a `%a{rigor:v1:return: <refinement>}` annotation (recognised by
        # `RbsExtended.read_return_type_override`), the refinement carrier replaces the RBS-declared return
        # for this rule. Annotation-driven refinements — `non-empty-string`, `positive-int`,
        # `non-empty-array[Integer]`, etc. — are stricter than the underlying RBS class, so a body whose
        # inferred type the bare RBS sig would accept may still fail the refinement (e.g. `def name; "";
        # end` returns `Constant[""]`, accepted by `String` but rejected by `non-empty-string`).
        def declared_return_type(def_node, scope_index)
          scope = scope_index[def_node]
          return nil if scope.nil?

          self_type = scope.self_type
          return nil unless self_type.respond_to?(:class_name)

          method_def =
            if def_node.receiver.nil? && !singleton_context_def?(scope, self_type.class_name, def_node.name)
              Reflection.instance_method_definition(self_type.class_name, def_node.name, scope: scope)
            else
              Reflection.singleton_method_definition(self_type.class_name, def_node.name, scope: scope)
            end
          return nil if method_def.nil?

          override = Rigor::RbsExtended.read_return_type_override(method_def, environment: scope.environment)
          return override if override

          declared_return_union(method_def, scope.environment)
        end

        # A receiverless `def` inside `class << self` is a singleton def; the def NODE alone cannot say
        # so, but the discovery walk recorded it under the singleton kind (and not the instance kind).
        # Without this, `class << self; def load` compared its body against `Kernel#load: -> bool` — the
        # inherited INSTANCE method — instead of its own `def self.load` signature. A name defined on
        # both facets stays on the instance lookup (the pre-existing conservative reading).
        def singleton_context_def?(scope, class_name, method_name)
          scope.discovered_method?(class_name, method_name, :singleton) &&
            !scope.discovered_method?(class_name, method_name, :instance)
        end

        # `type_vars:` — ADR-35 WD9 tier 1. When the caller supplies a generic-instantiation
        # substitution map (parent-side, keyed by the parent class's declared type-parameter names),
        # a `-> T` return is translated at its instantiated type (`-> Integer`) rather than degrading
        # to `Dynamic[Top]`. The default empty map is the pre-WD9 behaviour, under which any type
        # variable degrades to `Dynamic[Top]` and the rule stays silent.
        def declared_return_union(method_def, _environment, type_vars: {})
          translated = method_def.method_types.filter_map do |mt|
            Inference::RbsTypeTranslator.translate(
              mt.type.return_type,
              self_type: nil, instance_type: nil, type_vars: type_vars
            )
          rescue StandardError
            nil
          end
          return nil if translated.empty?

          translated.size == 1 ? translated.first : Type::Combinator.union(*translated)
        end

        def dynamic_top?(type)
          type.is_a?(Type::Dynamic) || (type.respond_to?(:top?) && type.top?.yes?)
        end

        # Returns the severity to emit at, or nil to stay silent. The first-cut implementation only fires
        # on proven (`:no`) mismatches; `:maybe` is treated as silent until the analyzer's narrowing
        # becomes precise enough to avoid noise on common patterns (`{}` → declared `Hash[K, V]`,
        # `Set.new` → declared `Set[Symbol]`, …). ADR-8's promise to emit on `:maybe` under
        # `severity_profile: strict` is deferred to a follow-up that lands together with the narrowing
        # precision improvements.
        def compare_return(declared, inferred)
          result = declared.accepts(inferred)
          return :error if result.no?

          nil
        end

        def build_return_type_mismatch_diagnostic(path, def_node, declared, inferred, severity)
          Diagnostic.from_name_loc(
            def_node,
            rule: RULE_RETURN_TYPE,
            path: path,
            message: "return-type mismatch on `#{def_node.name}': " \
                     "declared #{declared.describe(:short)}, inferred #{inferred.describe(:short)}",
            severity: severity,
            method_name: def_node.name.to_s
          )
        end

        # ADR-35 slice 1 — `def.override-visibility-reduced`. The Liskov signature rule for visibility: an
        # instance-method override MUST NOT reduce the visibility it inherits (public → protected/private,
        # or protected → private), because a caller holding the supertype that invokes the method breaks
        # when handed the subtype.
        #
        # Slice-1 scope (ADR-35 WD1, visibility carve-out): both the override and the shadowed method must
        # have a STATICALLY OBSERVABLE visibility. The override's visibility is read from the
        # source-discovered table; the parent is resolved against the project-discovered ancestor chain
        # (user-source classes / modules only — RBS-known ancestors, whose accessibility RBS models as
        # public/private only, are a deferred follow-on). When either side is not observable the rule stays
        # silent.
        def override_visibility_diagnostic(path, def_node, scope_index)
          return nil unless def_node.receiver.nil? # instance methods only

          scope = scope_index[def_node]
          return nil if scope.nil?

          self_type = scope.self_type
          return nil unless self_type.respond_to?(:class_name)

          class_name = self_type.class_name.to_s
          method_name = def_node.name

          override_visibility = scope.discovered_method_visibility(class_name, method_name)
          return nil if override_visibility.nil?

          parent = nearest_ancestor_visibility(scope, class_name, method_name)
          return nil if parent.nil?

          parent_class, parent_visibility = parent
          # Unknown ancestor visibility (e.g. the defining file was not in the analyzed set) → cannot
          # prove a reduction, stay silent.
          return nil if parent_visibility.nil?
          return nil unless visibility_reduced?(parent_visibility, override_visibility)

          build_override_visibility_diagnostic(
            path, def_node, parent_class, parent_visibility, override_visibility
          )
        end

        # Returns true when `override_visibility` is strictly more restrictive than `parent_visibility`
        # under the public > protected > private ordering.
        #
        # The nil guard below is defence, not dead code. `VISIBILITY_RANK` is a closed literal hash read
        # with a dynamic key, so a symbol outside the table reads as nil at runtime. The engine folds that
        # read to the nil-free value union `0 | 1 | 2`, which `internal-spec/inference-engine.md` declares
        # OPTIMISTIC rather than proof — and since issue #313 that mark survives the `.nil?` fold and the
        # `||` composition, so no suppression directive is needed here.
        def visibility_reduced?(parent_visibility, override_visibility)
          parent_rank = VISIBILITY_RANK[parent_visibility]
          override_rank = VISIBILITY_RANK[override_visibility]
          return false if parent_rank.nil? || override_rank.nil?

          override_rank < parent_rank
        end

        # Breadth-first walk of the project-discovered ancestor chain (included / prepended modules first,
        # then the superclass — Ruby's MRO ordering), yielding each resolved ancestor class name
        # nearest-first. Returns the first truthy value the block produces, or nil. Cross-file: the chain
        # is followed through the scope tables the runner seeds from the project pre-pass (ADR-24 WD1).
        # Cycle-guarded and node-count-capped. Mirrors `ExpressionTyper#resolve_user_def_through_ancestors`.
        def each_project_ancestor(scope, class_name)
          queue = ancestor_class_names(scope, class_name)
          seen = { class_name.to_s => true }
          visited = 0
          until queue.empty?
            current = queue.shift
            next if current.nil? || seen[current]

            seen[current] = true
            visited += 1
            return nil if visited > OVERRIDE_ANCESTOR_WALK_LIMIT

            result = yield current
            return result if result

            ancestor_class_names(scope, current).each { |name| queue.push(name) }
          end
          nil
        end

        # `[defining_class, visibility]` for the nearest user-source ancestor that defines an instance
        # method `method_name`, or nil.
        def nearest_ancestor_visibility(scope, class_name, method_name)
          each_project_ancestor(scope, class_name) do |ancestor|
            # Stop at the nearest ancestor that DEFINES the method; its visibility may be nil (unknown) —
            # the caller treats unknown as "cannot prove a reduction" and stays silent. Never fabricate
            # `:public` from a missing entry (that produced a large false-positive cluster on cross-file
            # Rails concerns).
            [ancestor, scope.discovered_method_visibility(ancestor, method_name)] if scope.user_def_for(ancestor,
                                                                                                        method_name)
          end
        end

        # Direct ancestors of `class_name` as project-discovered, qualified names: included / prepended
        # modules first, then the superclass. As-written names are resolved against the subclass's lexical
        # nesting; names that resolve to no project class/module (RBS-known / third-party) are dropped.
        def ancestor_class_names(scope, class_name)
          names = []
          scope.includes_of(class_name).each do |raw|
            resolved = resolve_override_ancestor_name(scope, class_name, raw)
            names << resolved if resolved
          end
          raw_super = scope.superclass_of(class_name)
          if raw_super
            resolved_super = resolve_override_ancestor_name(scope, class_name, raw_super)
            names << resolved_super if resolved_super
          end
          names
        end

        def resolve_override_ancestor_name(scope, subclass_qualified, raw_ancestor)
          segments = subclass_qualified.to_s.split("::")
          (segments.length - 1).downto(0) do |i|
            candidate = (segments[0, i] + [raw_ancestor]).join("::")
            return candidate if known_user_class?(scope, candidate)
          end
          # ADR-46 slice 3 — the override checker reads the class graph
          # directly (not through the recorder's `Scope` choke points), and
          # short-circuits when the ancestor resolves to no project class, so
          # an incremental re-check has no edge telling it to re-check this
          # subclass when that ancestor is later defined. Record a negative
          # class edge (keyed on the unqualified name) so the appeared-class
          # widening picks it up.
          DependencyRecorder.read_missing(:class, raw_ancestor.to_s.split("::").last) if DependencyRecorder.active?
          nil
        end

        def known_user_class?(scope, name)
          scope.discovered_superclasses.key?(name) ||
            scope.discovered_def_nodes.key?(name) ||
            scope.discovered_includes.key?(name)
        end

        def build_override_visibility_diagnostic(path, def_node, parent_class, parent_visibility, override_visibility)
          Diagnostic.from_name_loc(
            def_node,
            rule: RULE_OVERRIDE_VISIBILITY_REDUCED,
            path: path,
            message: "visibility of `#{def_node.name}' reduced from #{parent_visibility} to " \
                     "#{override_visibility} (overrides #{parent_class}##{def_node.name}); " \
                     "breaks substitutability",
            severity: :warning,
            method_name: def_node.name.to_s
          )
        end

        # ADR-35 slice 2 — `def.override-return-widened`. The Liskov signature rule for returns
        # (covariance): an override may *narrow* the return it inherits (return a more specific type) but
        # MUST NOT *widen* it. A caller holding the supertype uses the result as the parent's return type;
        # a wider override return breaks that use.
        #
        # WD1 gate (proper, type-direction): both the override and the shadowed ancestor method must carry
        # an explicitly-authored RBS signature. The override side is gated by `defined_on?` (the RBS
        # method is declared on the overriding class itself, not merely inherited); the parent side is the
        # nearest project-discovered ancestor whose RBS declares the method. Inference-only either side →
        # silent.
        #
        # Fires only on a proven (`:no`) widening; generic / `untyped` / `self` parent returns degrade to
        # `Dynamic[Top]` and accept everything, so they stay silent (FP-safe). `self`/`instance` are
        # translated with `self_type: nil` on both sides, so a parent `-> self` and an override `-> self`
        # never fire.
        # The authored-override resolution shared by the Liskov override rules
        # (`def.override-return-widened` and `def.override-param-narrowed`): the def must be an instance
        # method whose own class declares it in RBS, and a project-discovered ancestor must also declare
        # it. Returns `[scope, override_method, parent_class, parent_method]`, or nil (the rule does not
        # fire) when any gate is unmet.
        def resolve_authored_override(def_node, scope_index)
          return nil unless def_node.receiver.nil? # instance methods only (singleton: follow-on)

          scope = scope_index[def_node]
          return nil if scope.nil?

          self_type = scope.self_type
          return nil unless self_type.respond_to?(:class_name)

          class_name = self_type.class_name.to_s
          method_name = def_node.name

          override_method = safe_instance_method_definition(class_name, method_name, scope)
          return nil if override_method.nil?
          return nil unless defined_on?(override_method, class_name)

          parent = nearest_ancestor_method_def(scope, class_name, method_name)
          return nil if parent.nil?

          parent_class, parent_method = parent
          [scope, override_method, parent_class, parent_method]
        end

        def override_return_widened_diagnostic(path, def_node, scope_index)
          resolved = resolve_authored_override(def_node, scope_index)
          return nil if resolved.nil?

          scope, override_method, parent_class, parent_method = resolved
          parent_type_vars = ancestor_instantiation_type_vars(scope, parent_class)
          override_return = declared_return_union(override_method, scope.environment)
          parent_return = declared_return_union(parent_method, scope.environment, type_vars: parent_type_vars)
          return nil if override_return.nil? || parent_return.nil?
          return nil if dynamic_top?(parent_return) # untyped / unbound-generic parent contract

          return nil unless parent_return.accepts(override_return).no?

          build_override_return_widened_diagnostic(
            path, def_node, parent_class, parent_return, override_return
          )
        end

        # `[defining_class, RBS::Definition::Method]` for the nearest project-discovered ancestor whose
        # RBS declares `method_name` (not the starting class's own declaration), or nil.
        def nearest_ancestor_method_def(scope, class_name, method_name)
          each_project_ancestor(scope, class_name) do |ancestor|
            method_def = safe_instance_method_definition(ancestor, method_name, scope)
            [ancestor, method_def] if method_def && !defined_on?(method_def, class_name)
          end
        end

        def safe_instance_method_definition(class_name, method_name, scope)
          Reflection.instance_method_definition(class_name, method_name, scope: scope)
        rescue StandardError
          nil
        end

        # True when `method_def`'s RBS declaration lives on `class_name` itself (rather than being
        # inherited from an ancestor).
        def defined_on?(method_def, class_name)
          defined_in = method_def.defined_in
          return false if defined_in.nil?

          normalize_class_name(defined_in.to_s) == normalize_class_name(class_name)
        end

        def normalize_class_name(name)
          name.to_s.delete_prefix("::")
        end

        # ADR-35 WD9 tier 1 — generic-instantiation-aware comparison. Builds the substitution map
        # `{ parent_type_param_name => instantiated Rigor::Type }` for the parent contract as the
        # overriding subclass instantiates it (RBS `class Sub < Parent[Concrete]` / `include
        # _Iface[Concrete]`). Mirrors the ADR-4 Phase 2d dispatcher zip (`build_type_vars`): the
        # parent's declared type-parameter names zipped against the subclass-side instantiation args.
        #
        # Returns `{}` — restoring the pre-WD9 behaviour under which any parent type variable degrades
        # to `Dynamic[Top]` and the rule stays silent — whenever the subclass does not instantiate the
        # ancestor generically, the RBS definition cannot be built, arities disagree, or an argument
        # fails to translate. This is the FP-safety contract: substitution only ever *adds* precision
        # (a `-> T` compared at `-> Integer`); an unbound / unresolved generic keeps degrading to
        # silence, never a false `:no`.
        def ancestor_instantiation_type_vars(scope, parent_class)
          self_type = scope.self_type
          return {} unless self_type.respond_to?(:class_name)

          args = ancestor_instantiation_args(scope, self_type.class_name.to_s, parent_class)
          return {} if args.nil? || args.empty?

          param_names = Reflection.class_type_param_names(parent_class, scope: scope)
          return {} if param_names.empty? || param_names.size != args.size

          translated = args.map do |arg|
            Inference::RbsTypeTranslator.translate(arg, self_type: nil, instance_type: nil, type_vars: {})
          rescue StandardError
            nil
          end
          return {} if translated.any?(&:nil?)

          param_names.zip(translated).to_h
        end

        # The RBS type arguments the subclass applies to `parent_class` in its ancestry, or nil when
        # the subclass has no RBS definition or does not name that ancestor. Reads the resolved
        # instance-ancestor list (`RBS::Definition#ancestors`), whose `Ancestor::Instance` entries carry
        # the instantiation `.args` for each superclass / included module. Fail-soft: any RBS build
        # error yields nil, which the caller treats as "no instantiation" and degrades to silence.
        def ancestor_instantiation_args(scope, subclass_name, parent_class)
          definition = Reflection.instance_definition(subclass_name, scope: scope)
          return nil if definition.nil?

          target = normalize_class_name(parent_class)
          ancestor = definition.ancestors.ancestors.find do |anc|
            anc.respond_to?(:args) && normalize_class_name(anc.name.to_s) == target
          end
          ancestor&.args
        rescue ::RBS::BaseError, StandardError
          nil
        end

        def build_override_return_widened_diagnostic(path, def_node, parent_class, parent_return, override_return)
          Diagnostic.from_name_loc(
            def_node,
            rule: RULE_OVERRIDE_RETURN_WIDENED,
            path: path,
            message: "return type of `#{def_node.name}' widened from #{parent_return.describe(:short)} " \
                     "to #{override_return.describe(:short)} (overrides #{parent_class}##{def_node.name}); " \
                     "breaks substitutability",
            severity: :warning,
            method_name: def_node.name.to_s
          )
        end

        # ADR-35 slice 3 — `def.override-param-narrowed`. The Liskov signature rule for parameters
        # (contravariance): an override may *widen* a parameter (accept a supertype — accepting more is
        # safe) but MUST NOT *narrow* it. A caller holding the supertype passes a parent-typed argument; a
        # narrowed override parameter cannot accept it.
        #
        # Direction (ADR-35 WD3, corrected): fire on `override_param.accepts(parent_param) == :no` — the
        # override's (narrowed) slot cannot accept the wider parent argument type. WD4: type comparison at
        # matching POSITIONAL parameter indices only; arity / keyword-requiredness divergence is out of
        # scope for v1. Same WD1 both-sides-authored gate as slice 2; `untyped` / unbound-generic /
        # interface parent params degrade to `Dynamic[Top]` and are skipped (FP-safe). To avoid
        # overload-arm ambiguity, both sides must have exactly one method type.
        def override_param_narrowed_diagnostic(path, def_node, scope_index)
          resolved = resolve_authored_override(def_node, scope_index)
          return nil if resolved.nil?

          scope, override_method, parent_class, parent_method = resolved
          parent_type_vars = ancestor_instantiation_type_vars(scope, parent_class)
          override_params = positional_param_types(override_method)
          parent_params = positional_param_types(parent_method, type_vars: parent_type_vars)
          return nil if override_params.nil? || parent_params.nil?

          index = first_narrowed_param_index(override_params, parent_params)
          return nil if index.nil?

          build_override_param_narrowed_diagnostic(
            path, def_node, parent_class, index, parent_params[index], override_params[index]
          )
        end

        # Translated positional (required + optional) parameter types of a method's single method type, or
        # nil when the method is overloaded (multiple method types — arm mapping is ambiguous) or the
        # parameter list is not introspectable. Per-position translation failures yield `nil` at that slot
        # (skipped by the comparison). `self`/`instance` translate with `self_type: nil` (→
        # `Dynamic[Top]`), matching the return-side handling.
        # `type_vars:` — ADR-35 WD9 tier 1, parent side only. Substitutes the generic-instantiation
        # map (parent class's type params → the subclass's instantiation) so a parent `(T)` parameter
        # is compared at its instantiated type. Empty (the default, and the override side) keeps the
        # pre-WD9 degrade-to-`Dynamic[Top]` behaviour.
        def positional_param_types(method_def, type_vars: {})
          method_types = method_def.method_types
          return nil unless method_types.size == 1

          func = method_types.first.type
          return nil unless func.respond_to?(:required_positionals)

          (func.required_positionals + func.optional_positionals).map do |param|
            Inference::RbsTypeTranslator.translate(
              param.type, self_type: nil, instance_type: nil, type_vars: type_vars
            )
          rescue StandardError
            nil
          end
        end

        # Index of the first positional parameter the override narrows relative to the parent, or nil. A
        # position is a violation when the override's slot cannot accept the parent's argument type
        # (`override_param.accepts(parent_param) == :no`). Positions where either side is
        # missing/untranslatable, or the parent type degraded to `Dynamic[Top]` (untyped / unbound generic
        # / interface), are skipped.
        def first_narrowed_param_index(override_params, parent_params)
          count = [override_params.size, parent_params.size].min
          count.times do |i|
            override_param = override_params[i]
            parent_param = parent_params[i]
            next if override_param.nil? || parent_param.nil?
            next if dynamic_top?(parent_param) || dynamic_top?(override_param)

            return i if override_param.accepts(parent_param).no?
          end
          nil
        end

        def build_override_param_narrowed_diagnostic(path, def_node, parent_class, index, parent_param, override_param)
          Diagnostic.from_name_loc(
            def_node,
            rule: RULE_OVERRIDE_PARAM_NARROWED,
            path: path,
            message: "parameter #{index + 1} of `#{def_node.name}' narrowed from " \
                     "#{parent_param.describe(:short)} to #{override_param.describe(:short)} " \
                     "(overrides #{parent_class}##{def_node.name}); breaks substitutability",
            severity: :warning,
            method_name: def_node.name.to_s
          )
        end
      end
      # rubocop:enable Metrics/ClassLength
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
