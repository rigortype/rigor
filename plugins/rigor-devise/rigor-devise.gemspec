# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-devise"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin example: ADR-16 Tier B worked target (trait-inlining registry)."
  spec.description = "Recognises Devise's model-side `devise :strategy_a, :strategy_b` DSL on " \
                     "ActiveRecord::Base subclasses. The first worked consumer of " \
                     "`Plugin::Macro::TraitRegistry` (ADR-16 slice 3c). The plugin's bundled " \
                     "registry mirrors `lib/devise/modules.rb`'s symbol → module table; the " \
                     "substrate's pre-pass per-method-explodes each included module's RBS " \
                     "instance methods onto the calling model class."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
