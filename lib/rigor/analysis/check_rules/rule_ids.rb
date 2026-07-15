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
      RULE_SHADOWED_RESCUE_CLAUSE = "flow.shadowed-rescue-clause"

      ALL_RULES = [
        RULE_UNDEFINED_METHOD,
        RULE_SELF_UNDEFINED_METHOD,
        RULE_UNRESOLVED_TOPLEVEL,
        RULE_WRONG_ARITY,
        RULE_ARGUMENT_TYPE,
        RULE_NIL_RECEIVER,
        RULE_DUMP_TYPE,
        RULE_ASSERT_TYPE,
        RULE_ALWAYS_RAISES,
        RULE_UNREACHABLE_BRANCH,
        RULE_DEAD_ASSIGNMENT,
        RULE_ALWAYS_TRUTHY_CONDITION,
        RULE_UNREACHABLE_CLAUSE,
        RULE_SHADOWED_RESCUE_CLAUSE,
        RULE_RETURN_TYPE,
        RULE_VISIBILITY_MISMATCH,
        RULE_OVERRIDE_VISIBILITY_REDUCED,
        RULE_OVERRIDE_RETURN_WIDENED,
        RULE_OVERRIDE_PARAM_NARROWED,
        RULE_IVAR_WRITE_MISMATCH
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
        "dump-type" => RULE_DUMP_TYPE,
        "assert-type" => RULE_ASSERT_TYPE,
        "always-raises" => RULE_ALWAYS_RAISES,
        "unreachable-branch" => RULE_UNREACHABLE_BRANCH,
        "method-visibility-mismatch" => RULE_VISIBILITY_MISMATCH,
        "ivar-write-mismatch" => RULE_IVAR_WRITE_MISMATCH,
        "dead-assignment" => RULE_DEAD_ASSIGNMENT,
        "always-truthy-condition" => RULE_ALWAYS_TRUTHY_CONDITION,
        "unreachable-clause" => RULE_UNREACHABLE_CLAUSE,
        "shadowed-rescue-clause" => RULE_SHADOWED_RESCUE_CLAUSE
      }.freeze

      # Family wildcard — a `<family>` token in a suppression comment or `disable:` list disables every rule
      # whose canonical id starts with `<family>.`. Per ADR-8 § "1".
      RULE_FAMILIES = %w[call flow assert dump def].freeze
    end
  end
end
