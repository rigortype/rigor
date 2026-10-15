# frozen_string_literal: true

module Rigor
  module Analysis
    module CheckRules
      # Canonical identifiers for each rule. Per ADR-8 § "Diagnostic ID family hierarchy", rule names are
      # `family.rule-name` two-segment strings; the families group diagnostics by where they originate
      # (`call.*` for call-site rules, `flow.*` for flow-analysis proofs, `assert.*` for runtime-assertion
      # rules, `dump.*` for debug helpers, `def.*` for method-definition rules, `global.*` for writes to special
      # globals). Used by the configuration `disable:` list and the in-source `# rigor:disable <rule>`
      # suppression comment system; new rules MUST register here so user configuration can refer to them.
      #
      # ADR-87 WD4 — this pure-data constant table is split out of the (engine-heavy) `check_rules.rb` so
      # {Analysis::RuleCatalog} — which the CLI's JSON `evidence_tier` / `documentation_url` enrichment reads
      # — can require it WITHOUT loading the inference engine. The boot-slimming hit path stays engine-free
      # even when it formats JSON.
      RULE_UNDEFINED_METHOD = "call.undefined-method"
      RULE_SELF_UNDEFINED_METHOD = "call.self-undefined-method"
      RULE_UNRESOLVED_TOPLEVEL = "call.unresolved-toplevel"
      RULE_WRONG_ARITY = "call.wrong-arity"
      RULE_ARGUMENT_TYPE = "call.argument-type-mismatch"
      RULE_NIL_RECEIVER = "call.possible-nil-receiver"
      RULE_RAISE_NON_EXCEPTION = "call.raise-non-exception"
      RULE_DUMP_TYPE = "dump.type"
      RULE_ASSERT_TYPE = "assert.type-mismatch"
      RULE_ALWAYS_RAISES = "flow.always-raises"
      RULE_UNREACHABLE_BRANCH = "flow.unreachable-branch"
      RULE_RETURN_TYPE = "def.return-type-mismatch"
      RULE_VISIBILITY_MISMATCH = "def.method-visibility-mismatch"
      RULE_OVERRIDE_VISIBILITY_REDUCED = "def.override-visibility-reduced"
      RULE_OVERRIDE_RETURN_WIDENED = "def.override-return-widened"
      RULE_OVERRIDE_PARAM_NARROWED = "def.override-param-narrowed"
      RULE_IVAR_WRITE_MISMATCH = "def.ivar-write-mismatch"
      RULE_DEAD_ASSIGNMENT = "flow.dead-assignment"
      RULE_ALWAYS_TRUTHY_CONDITION = "flow.always-truthy-condition"
      RULE_UNREACHABLE_CLAUSE = "flow.unreachable-clause"
      RULE_DUPLICATE_HASH_KEY = "flow.duplicate-hash-key"
      RULE_RETURN_IN_ENSURE = "flow.return-in-ensure"
      RULE_SHADOWED_RESCUE_CLAUSE = "flow.shadowed-rescue-clause"
      RULE_SUPPRESSION_UNKNOWN_RULE = "suppression.unknown-rule"
      RULE_SUPPRESSION_EMPTY = "suppression.empty"
      RULE_SUPPRESSION_UNKNOWN_MARKER = "suppression.unknown-marker"
      # ADR-100 — the first `static.value-use.*` id: a value recovered from an author-declared `-> void`
      # return, used in value context. Authored `:warning`, resolved `:off` by every profile and promoted to
      # `:warning` only by the `use-of-void-value` bleeding-edge feature.
      RULE_VALUE_USE_VOID = "static.value-use.void"
      # ADR-103 WD8 / #383 — the first `effect.*` id: a method whose PROVEN effect labels are not
      # subsumed by the envelope its author declared (`%a{pure}` / `%a{rigor:v1:effect ...}`). Opt-in
      # twice over — the `effects:` block enables collection, and the envelope is the author's own
      # directive — so it is never unsolicited.
      RULE_EFFECT_ENVELOPE_EXCEEDED = "effect.envelope-exceeded"
      # ADR-103 WD1 / #384 — the paired vocabulary diagnostic. An unknown label degrades the whole tag
      # to ⊤, which is silent by construction; this is what keeps that fail-open reading honest. It
      # fires only where label intent is evident (`Effects::LabelIntent`'s four signals), so a project
      # opening its own vocabulary is never nagged, and it is gated by the same `effects.check` switch
      # as its sibling: opting into envelope enforcement is exactly what turns on the diagnostic that
      # says an envelope stopped enforcing.
      RULE_EFFECT_UNKNOWN_LABEL = "effect.unknown-label"
      # ADR-103 WD1 / WD14 / #386 — the inherited-bound reading. An override performs, or itself
      # declares, an effect the envelope written on the method it overrides does not admit. Implementations
      # may be purer than the bound they inherit, never less pure; both-sides-authored in the ADR-35 sense,
      # so nothing fires unless someone wrote an envelope on the ancestor.
      RULE_EFFECT_LISKOV_WIDENED = "effect.liskov-widened"
      # ADR-103 WD13 commitment 1 / #384 — the residual. A project whose RBS carries `%a{pure}` /
      # `%a{rigor:v1:effect …}` but no `effects:` block gets ONE `:info` per run saying so. An
      # annotation must never turn collection on by itself (that would be a project-wide cost cliff
      # nobody asked for), and it must equally never be silently inert.
      RULE_EFFECT_ANNOTATIONS_UNCHECKED = "effect.annotations-unchecked"
      # ADR-112 WD5 / #1075 — two statements of one member's contract that contradict: a `sig/` declaration
      # against an inline `@rbs` / `#:` one (and, once #1073 reads it, `@rbs` / `#:` against `@extrbs`), or a
      # `rigor:v1:` refinement outside the member's own declared type. `rbs.` because the finding is about
      # the RBS the environment is built from, whichever file spelled it; not `rbs_extended.`, whose rows
      # are payload validity, since most contradictions involve no `RBS::Extended` annotation at all.
      RULE_CONTRADICTING_SIGNATURE = "rbs.contradicting-signature"
      # Issue #1367 (ADR-117 WD2) — the `global.*` family: a write to a special global that its setter rejects, so
      # the write raises on every run. Two ids so a project can tune the type check without hiding read-only
      # writes; the `write` wording follows `def.ivar-write-mismatch`. The envelope is the interpreter's setter
      # (`SpecialGlobalSetters`), not the global's RBS declaration.
      RULE_GLOBAL_WRITE_TYPE_MISMATCH = "global.write-type-mismatch"
      RULE_GLOBAL_READONLY_WRITE = "global.readonly-write"
      # Issue #1692 (the ADR-47 WD5 amendment) — a call to the `ruby2_keywords` family Ruby 4.1 deprecates. Runs only
      # under an explicit `target_ruby` of 4.1 or later; see {RubyDeprecations}.
      RULE_DEPRECATED_RUBY2_KEYWORDS = "call.deprecated-ruby2-keywords"

      ALL_RULES = [
        RULE_UNDEFINED_METHOD,
        RULE_SELF_UNDEFINED_METHOD,
        RULE_UNRESOLVED_TOPLEVEL,
        RULE_WRONG_ARITY,
        RULE_ARGUMENT_TYPE,
        RULE_NIL_RECEIVER,
        RULE_RAISE_NON_EXCEPTION,
        RULE_DEPRECATED_RUBY2_KEYWORDS,
        RULE_DUMP_TYPE,
        RULE_ASSERT_TYPE,
        RULE_ALWAYS_RAISES,
        RULE_UNREACHABLE_BRANCH,
        RULE_DEAD_ASSIGNMENT,
        RULE_ALWAYS_TRUTHY_CONDITION,
        RULE_UNREACHABLE_CLAUSE,
        RULE_DUPLICATE_HASH_KEY,
        RULE_RETURN_IN_ENSURE,
        RULE_SHADOWED_RESCUE_CLAUSE,
        RULE_RETURN_TYPE,
        RULE_VISIBILITY_MISMATCH,
        RULE_OVERRIDE_VISIBILITY_REDUCED,
        RULE_OVERRIDE_RETURN_WIDENED,
        RULE_OVERRIDE_PARAM_NARROWED,
        RULE_IVAR_WRITE_MISMATCH,
        RULE_GLOBAL_WRITE_TYPE_MISMATCH,
        RULE_GLOBAL_READONLY_WRITE,
        RULE_SUPPRESSION_UNKNOWN_RULE,
        RULE_SUPPRESSION_EMPTY,
        RULE_SUPPRESSION_UNKNOWN_MARKER,
        RULE_VALUE_USE_VOID,
        RULE_EFFECT_ENVELOPE_EXCEEDED,
        RULE_EFFECT_LISKOV_WIDENED,
        RULE_EFFECT_UNKNOWN_LABEL,
        RULE_EFFECT_ANNOTATIONS_UNCHECKED,
        RULE_CONTRADICTING_SIGNATURE
      ].freeze

      # Backward-compat alias table (ADR-8 § "Backward compatibility"). Existing user code with
      # `# rigor:disable undefined-method` / `disable: [undefined-method]` keeps working — the legacy
      # unprefixed identifiers map to their canonical `family.rule-name` form here. Removing the aliases is a
      # future ADR once user code has migrated; until then, both spellings resolve identically.
      LEGACY_RULE_ALIASES = {
        "undefined-method" => RULE_UNDEFINED_METHOD,
        "self-undefined-method" => RULE_SELF_UNDEFINED_METHOD,
        "wrong-arity" => RULE_WRONG_ARITY,
        "argument-type-mismatch" => RULE_ARGUMENT_TYPE,
        "possible-nil-receiver" => RULE_NIL_RECEIVER,
        "raise-non-exception" => RULE_RAISE_NON_EXCEPTION,
        "dump-type" => RULE_DUMP_TYPE,
        "assert-type" => RULE_ASSERT_TYPE,
        "always-raises" => RULE_ALWAYS_RAISES,
        "unreachable-branch" => RULE_UNREACHABLE_BRANCH,
        "method-visibility-mismatch" => RULE_VISIBILITY_MISMATCH,
        "ivar-write-mismatch" => RULE_IVAR_WRITE_MISMATCH,
        "dead-assignment" => RULE_DEAD_ASSIGNMENT,
        "always-truthy-condition" => RULE_ALWAYS_TRUTHY_CONDITION,
        "unreachable-clause" => RULE_UNREACHABLE_CLAUSE,
        "duplicate-hash-key" => RULE_DUPLICATE_HASH_KEY,
        "return-in-ensure" => RULE_RETURN_IN_ENSURE,
        "shadowed-rescue-clause" => RULE_SHADOWED_RESCUE_CLAUSE
      }.freeze

      # Family wildcard — a `<family>` token in a suppression comment or `disable:` list disables every rule
      # whose canonical id starts with `<family>.`. Per ADR-8 § "1".
      RULE_FAMILIES = %w[call flow assert dump def global suppression static effect].freeze

      # Families of diagnostics the engine emits OUTSIDE the CheckRules catalogue (aggregator-level and
      # reporter-level diagnostics such as `rbs_extended.unsatisfied-conformance`,
      # `dynamic.dependency-source.*`, `rbs.coverage.*`, `pre-eval.parse-error`), plus the `plugin.` prefix
      # reserved for plugin-produced identifiers. `suppression.unknown-rule` treats a dotted token whose
      # first segment appears here as KNOWN and stays silent: these ids are legitimate suppression /
      # `severity_overrides:` vocabulary the light rule-id table cannot enumerate (plugins load dynamically;
      # aggregator ids live in the engine-heavy runner), so under-warning is the FP-safe direction.
      # The `pre-eval.*` ids (ADR-17 WD6) the bare family wildcard `pre-eval` expands to. Emitted by the
      # `pre_eval:` pre-pass, outside the CheckRules catalogue, so the family cannot ride `RULE_FAMILIES`
      # (which also drives the catalogue and the config audit over `ALL_RULES`).
      PRE_EVAL_RULES = %w[
        pre-eval.parse-error pre-eval.file-not-found pre-eval.duplicate-declaration
      ].freeze

      NON_CHECK_DIAGNOSTIC_FAMILIES = %w[rbs_extended dynamic rbs pre-eval plugin plugin_trust].freeze

      # Bare (dot-less) diagnostic ids the engine emits outside the catalogue (see the `rule:` literals in
      # `Analysis::Runner` / `Runner::DiagnosticAggregator`). A token equal to one of these is treated as
      # known by `suppression.unknown-rule` even though it carries no family prefix; extend the list when
      # the runner grows a new bare id.
      NON_CHECK_DIAGNOSTIC_IDS = %w[
        configuration-error load-error pool-degraded runtime-error source-rbs-synthesis-failed
        source-rbs-annotation-not-honoured
      ].freeze

      # Resolves a user-supplied rule token (`undefined-method`, `call.undefined-method`, or the family wildcard
      # `call`) to the set of canonical rule identifiers it disables. Returns `nil` for `"all"` (the existing
      # wildcard meaning "every rule"), or for unknown tokens.
      def self.resolve_rule_token(token)
        return nil if token == "all"
        return [LEGACY_RULE_ALIASES.fetch(token)] if LEGACY_RULE_ALIASES.key?(token)
        return PRE_EVAL_RULES if token == "pre-eval"
        return ALL_RULES.select { |r| r.start_with?("#{token}.") } if RULE_FAMILIES.include?(token)

        ALL_RULES.include?(token) ? [token] : []
      end

      # Expands a list of user-supplied rule tokens into the canonical-id set per ADR-8 § "Backward
      # compatibility". `disabled_rules` accepts unprefixed legacy names (`undefined-method`), canonical names
      # (`call.undefined-method`), family wildcards (`call`) and the `all` sentinel.
      def self.expand_rule_tokens(tokens)
        Array(tokens).each_with_object(Set.new) do |token, set|
          set.merge(expand_token(token.to_s))
        end
      end

      def self.expand_token(token)
        return ["all"] if token == "all"

        resolved = resolve_rule_token(token)
        resolved.nil? || resolved.empty? ? [token] : resolved
      end

      # Whether the `.rigor.yml` `disable:` list, expanded by {.expand_rule_tokens}, drops a diagnostic whose rule
      # id is `rule`: the `all` sentinel drops every rule-bearing row, any other entry its exact id. A nil rule (a
      # parse, path or internal error) is never dropped.
      def self.config_disabled?(rule, disabled)
        return false if rule.nil?

        disabled.include?("all") || disabled.include?(rule)
      end

      # The source-family prefix the runner stamps on every plugin-emitted row (`plugin.<id>`).
      PLUGIN_FAMILY_PREFIX = "plugin."

      # Issue #1953 — whether a suppression token set drops a plugin's own row. Such a row answers only to its
      # qualified id: the exact `plugin.<id>.<rule>` (its `qualified_rule`) or the whole plugin's `plugin.<id>`
      # (its `source_family`). Both compare whole strings against the row's own fields, so `plugin.<id>` never
      # reaches a plugin whose id merely starts with `<id>.`. Ids and rules may both hold dots, so plugin `a` with
      # rule `b.c` and plugin `a.b` with rule `c` share `plugin.a.b.c`, and that exact token drops both. A bare rule and `all` do not reach these rows:
      # many plugins share a bare rule (`load-error`, `unknown-column`), and a bare match would hide another
      # plugin's findings. Every other row (built-in, `plugin_loader`, `plugin_trust`) answers false.
      def self.plugin_row_disabled?(diagnostic, tokens)
        return false if diagnostic.rule.nil?

        family = diagnostic.source_family.to_s
        return false unless family.start_with?(PLUGIN_FAMILY_PREFIX)

        tokens.include?(family) || tokens.include?(diagnostic.qualified_rule)
      end
    end
  end
end
