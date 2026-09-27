# frozen_string_literal: true

module Rigor
  module Inference
    module DeclarationWalk
      # A failure of the walk's contract rather than of the file being walked: a shadow-harness divergence
      # ({Shadow::Divergence}) or a collector naming a variant no rule has ({UnknownVariant}). The discovery
      # passes skip a file they cannot read or parse, and the run-result cache path falls back to an uncached
      # run on an error; both let this through, because skipping the file would hide the failure and drop the
      # file from the project index. In a file's own index the per-file rescue still reports it as an error
      # row on the file.
      class ContractError < StandardError; end

      # A collector's `VARIANTS` names a rule or a variant {RULE_VARIANTS} does not have.
      class UnknownVariant < ContractError; end
    end
  end
end
