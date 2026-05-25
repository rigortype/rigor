# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-rbs-inline"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin that ingests rbs-inline-shaped comments as RBS signatures."
  spec.description = "Calls the upstream `rbs-inline` library at env-build time to synthesize " \
                     "RBS from Ruby source files carrying `# rbs_inline: enabled` magic " \
                     "comments (per ADR-32). The synthesized RBS feeds into the same " \
                     "MethodParameterBinder + argument-mismatch pipeline as a hand-written " \
                     "`.rbs` file, so `# @rbs name: :asc | :desc`-shaped doc-style annotations " \
                     "become enforced parameter contracts. Set `require_magic_comment: false` " \
                     "in the plugin config to skip the per-file magic-comment gate (intended " \
                     "for host contexts like the ADR-29 browser playground)."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "rbs-inline", ">= 0.5", "< 1.0"
  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
