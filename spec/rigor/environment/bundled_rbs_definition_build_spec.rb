# frozen_string_literal: true

require "spec_helper"

# Drift guard for issue #299.
#
# A duplicate method declaration between Rigor's bundled RBS (`data/vendored_gem_sigs/`,
# `data/gem_overlay/`, `Environment::DEFAULT_LIBRARIES`) and the `rbs` gem's own signatures does NOT fail a
# run: `RBS::DefinitionBuilder` raises, Rigor fails soft, and the WHOLE class silently degrades to
# `Dynamic[top]` — real methods and typos alike stop being witnessed. Seven classes had been in that state
# unnoticed until the #296 warning surfaced them.
#
# So the invariant is pinned here rather than left to a warning nobody greps: every class the bundled RBS
# touches MUST have a buildable definition. A future `rbs` bump that re-collides fails the suite instead of
# silently costing precision.
RSpec.describe "bundled RBS definition builds" do
  # The full bundled environment: `DEFAULT_LIBRARIES` (which is where the `rbs` gem — and therefore its
  # `sig/shims/bundler.rbs` and `sig/shims/rubygems.rbs` — enters) plus every `data/vendored_gem_sigs/`
  # directory, plus the ADR-72 ActiveSupport overlay. The overlay is Gemfile.lock-gated in production, so it
  # is passed explicitly here to exercise the `Time` / `DateTime` collisions too.
  let(:env) do
    Rigor::Environment::RbsLoader.build_env_for(
      libraries: Rigor::Environment::DEFAULT_LIBRARIES,
      signature_paths: Rigor::Environment::RbsLoader.gem_overlay_sig_paths(["activesupport"])
    )
  end

  let(:builder) { RBS::DefinitionBuilder.new(env: env) }

  # `[type name, whether the singleton side is the one that used to collide]`.
  instance_and_singleton = [
    "::Gem::Specification",
    "::Gem::Dependency",
    "::Gem::Requirement",
    "::Bundler::LockfileParser",
    "::Bundler::LazySpecification",
    "::Bundler::Definition",
    "::Bundler::Dependency",
    "::Time",
    "::DateTime",
    "::Nokogiri::CSS::Parser",
    "::Racc::Parser"
  ]

  instance_and_singleton.each do |name|
    it "builds the instance and singleton definition of #{name}" do
      type_name = RBS::TypeName.parse(name)

      expect(builder.build_instance(type_name)).not_to be_nil
      expect(builder.build_singleton(type_name)).not_to be_nil
    end
  end

  ["::Bundler", "::BigMath"].each do |name|
    it "builds the singleton definition of the #{name} module" do
      expect(builder.build_singleton(RBS::TypeName.parse(name))).not_to be_nil
    end
  end

  # The point of the exercise: the methods that were unreachable while the definitions failed to build.
  describe "the previously-degraded members" do
    it "resolves Gem::Specification#version and its writer" do
      definition = builder.build_instance(RBS::TypeName.parse("::Gem::Specification"))

      expect(definition.methods[:version]).not_to be_nil
      expect(definition.methods[:version=]).not_to be_nil
    end

    it "resolves Bundler.default_lockfile and Bundler.definition" do
      definition = builder.build_singleton(RBS::TypeName.parse("::Bundler"))

      expect(definition.methods[:default_lockfile]).not_to be_nil
      expect(definition.methods[:definition]).not_to be_nil
    end

    it "resolves Bundler::LockfileParser's one-argument constructor and #specs" do
      definition = builder.build_instance(RBS::TypeName.parse("::Bundler::LockfileParser"))
      arities = definition.methods[:initialize].method_types.map { |mt| mt.type.required_positionals.size }

      expect(arities).to include(1)
      expect(definition.methods[:specs]).not_to be_nil
    end

    it "resolves Time#utc? and DateTime#to_time from upstream rather than the ActiveSupport overlay" do
      expect(builder.build_instance(RBS::TypeName.parse("::Time")).methods[:utc?]).not_to be_nil
      expect(builder.build_instance(RBS::TypeName.parse("::DateTime")).methods[:to_time]).not_to be_nil
    end

    it "resolves Nokogiri::CSS::Parser's Racc::Parser superclass" do
      ancestors = builder.build_instance(RBS::TypeName.parse("::Nokogiri::CSS::Parser")).ancestors

      expect(ancestors.ancestors.map { |a| a.name.to_s }).to include("::Racc::Parser")
    end
  end

  # An exhaustive sweep: no class or module anywhere in the bundled environment may fail to build. This is
  # what actually catches the NEXT collision, wherever it lands.
  it "builds every class and module declared in the bundled environment" do
    failures = env.class_decls.each_key.with_object([]) do |name, acc|
      builder.build_instance(name)
      builder.build_singleton(name)
    rescue StandardError => e
      acc << "#{name}: #{e.class}: #{e.message.lines.first.to_s.strip}"
    end

    expect(failures).to be_empty
  end
end
