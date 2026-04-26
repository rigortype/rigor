# frozen_string_literal: true

require_relative "lib/rigor/version"

Gem::Specification.new do |spec|
  spec.name = "rigor"
  spec.version = Rigor::VERSION
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Inference-first static analysis for Ruby."
  spec.description = "Rigor is a CLI-first static analyzer for Ruby applications that prioritizes type inference, " \
                     "clean application code, and zero runtime dependencies."
  spec.homepage = "https://github.com/rigortype/rigor"
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]

  spec.metadata = {
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "source_code_uri" => spec.homepage,
    "documentation_uri" => "#{spec.homepage}/tree/main/docs",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir.glob(
    %w[
      README.md
      LICENSE
      exe/*
      lib/**/*.rb
      sig/**/*.rbs
    ]
  )
  spec.bindir = "exe"
  spec.executables = ["rigor"]
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 2.0"
  spec.add_dependency "rbs", ">= 3.0", "< 5.0"

  spec.add_development_dependency "rake", ">= 13.0", "< 15.0"
  spec.add_development_dependency "rspec", ">= 3.13", "< 4.0"
  spec.add_development_dependency "rubocop", ">= 1.70", "< 2.0"
  spec.add_development_dependency "rubocop-rake", ">= 0.6", "< 1.0"
  spec.add_development_dependency "rubocop-rspec", ">= 3.0", "< 4.0"
end
