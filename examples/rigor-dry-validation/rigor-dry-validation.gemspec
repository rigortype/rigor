# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-dry-validation"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin example: dry-validation Contract recognition (ADR-12 Tier A)."
  spec.description = "Recognises `class T < Dry::Validation::Contract` subclasses and " \
                     "publishes the `:dry_validation_contracts` cross-plugin fact (ADR-9) so " \
                     "downstream consumers can find contracts by FQN. Ships a small RBS overlay " \
                     "(sig/dry_validation.rbs) typing Contract#call / Result#success? / #failure? " \
                     "/ #to_h that users can add to their `.rigor.yml`'s `signature_paths:` for " \
                     "typed `contract.call(input).to_h` chains. Slice 1 floor per " \
                     "docs/design/20260517-dry-validation-slicing.md; slice 2 (params block " \
                     "integration with rigor-dry-schema) deferred."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb sig/**/*.rbs])
  spec.require_paths = ["lib"]

  spec.add_dependency "rigortype", ">= 0.1.5", "< 0.2.0"
end
