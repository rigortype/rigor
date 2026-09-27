# frozen_string_literal: true

module Rigor
  module Analysis
    # The `RIGOR_SHADOW_RULE_WALK` switch, read in one place by both halves of the shadow harness: the rule
    # walk's collectors (ADR-53 Track B, {CheckRules}) and the discovery tables (ADR-116 WD5,
    # {Inference::DeclarationWalk::Shadow}, which also says how a run must be made), and by the cache keys that
    # must not let a warm run answer for either. A leaf file, so the ADR-87 boot-slim probe loads it without
    # any engine code.
    module ShadowHarness
      ENV_KEY = "RIGOR_SHADOW_RULE_WALK"

      module_function

      # Set to anything, `0` and the empty string included.
      def enabled?
        !ENV[ENV_KEY].nil?
      end

      # What the run-result cache and the incremental snapshot key on: nil with the harness off, which adds
      # no key slot, so a run without the variable computes the key it computed before the harness existed.
      def cache_identity
        enabled? ? ENV_KEY : nil
      end
    end
  end
end
