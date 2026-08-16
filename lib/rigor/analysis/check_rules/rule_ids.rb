# frozen_string_literal: true

module Rigor
  module Analysis
    module CheckRules
      # Canonical identifiers for each rule. Per ADR-8 § "Diagnostic ID family hierarchy", rule names are
      # `family.rule-name` two-segment strings; the families group diagnostics by where they originate
      # (`call.*` for call-site rules, `flow.*` for flow-analysis proofs, `assert.*` for runtime-assertion
      # rules, `dump.*` for debug helpers, `def.*` for method-definition rules). Used by the configuration
      # `disable:` list and the in-source `# rigor:disable <rule>` suppression comment system; new rules MUST
      # register here so user configuration can refer to them.
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

      ALL_RULES = [
        RULE_UNDEFINED_METHOD,
        RULE_SELF_UNDEFINED_METHOD,
        RULE_UNRESOLVED_TOPLEVEL,
        RULE_WRONG_ARITY,
        RULE_ARGUMENT_TYPE,
        RULE_NIL_RECEIVER,
        RULE_RAISE_NON_EXCEPTION,
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
        RULE_SUPPRESSION_UNKNOWN_RULE,
        RULE_SUPPRESSION_EMPTY,
        RULE_SUPPRESSION_UNKNOWN_MARKER,
        RULE_VALUE_USE_VOID,
        RULE_EFFECT_ENVELOPE_EXCEEDED
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
      RULE_FAMILIES = %w[call flow assert dump def suppression static effect].freeze

      # Families of diagnostics the engine emits OUTSIDE the CheckRules catalogue (aggregator-level and
      # reporter-level diagnostics such as `rbs_extended.unsatisfied-conformance`,
      # `dynamic.dependency-source.*`, `rbs.coverage.*`, `pre-eval.parse-error`), plus the `plugin.` prefix
      # reserved for plugin-produced identifiers. `suppression.unknown-rule` treats a dotted token whose
      # first segment appears here as KNOWN and stays silent: these ids are legitimate suppression /
      # `severity_overrides:` vocabulary the light rule-id table cannot enumerate (plugins load dynamically;
      # aggregator ids live in the engine-heavy runner), so under-warning is the FP-safe direction.
      NON_CHECK_DIAGNOSTIC_FAMILIES = %w[rbs_extended dynamic rbs pre-eval plugin].freeze

      # Bare (dot-less) diagnostic ids the engine emits outside the catalogue (see the `rule:` literals in
      # `Analysis::Runner` / `Runner::DiagnosticAggregator`). A token equal to one of these is treated as
      # known by `suppression.unknown-rule` even though it carries no family prefix; extend the list when
      # the runner grows a new bare id.
      NON_CHECK_DIAGNOSTIC_IDS = %w[
        configuration-error load-error pool-degraded runtime-error source-rbs-synthesis-failed
        source-rbs-annotation-not-honoured
      ].freeze
    end
  end
end
