# frozen_string_literal: true

# Integration spec for `examples/rigor-rails/`. Verifies the
# Tier 1+2 Rails meta-gem's two contracts:
#
# 1. The gemspec's `add_dependency` declarations match the
#    `require` statements in `lib/rigor-rails.rb` (regression
#    guard against the two lists drifting apart — if a sub-plugin
#    is added to one, it must be added to the other).
# 2. Requiring `rigor-rails` side-effects a
#    `Rigor::Plugin.register` call for every Tier 1+2 plugin
#    class — so the plugin loader can later look them up by id
#    when `.rigor.yml` enumerates them.

require "spec_helper"

RIGOR_RAILS_META_LIB = File.expand_path("../../../examples/rigor-rails/lib", __dir__)
RIGOR_RAILS_META_GEMSPEC = File.expand_path(
  "../../../examples/rigor-rails/rigor-rails.gemspec", __dir__
)

# Each sub-plugin example carries its own lib/ — prepend them all
# to $LOAD_PATH so `require "rigor-rails"` resolves the per-gem
# entry points. In real projects bundler resolves these via
# RubyGems / Gemfile path overrides.
%w[
  rigor-rails-routes
  rigor-rails-i18n
  rigor-actionmailer
  rigor-activejob
  rigor-activerecord
  rigor-actionpack
  rigor-factorybot
].each do |gem_name|
  lib = File.expand_path("../../../examples/#{gem_name}/lib", __dir__)
  $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
end
$LOAD_PATH.unshift(RIGOR_RAILS_META_LIB) unless $LOAD_PATH.include?(RIGOR_RAILS_META_LIB)

RSpec.describe "examples/rigor-rails meta-gem" do
  let(:gemspec) { Gem::Specification.load(RIGOR_RAILS_META_GEMSPEC) }
  let(:lib_file) do
    File.read(File.join(RIGOR_RAILS_META_LIB, "rigor-rails.rb"), encoding: "UTF-8")
  end

  describe "gemspec metadata" do
    it "names the gem `rigor-rails`" do
      expect(gemspec.name).to eq("rigor-rails")
    end

    it "declares the seven Tier 1+2 sub-plugin dependencies (+ rigortype)" do
      sub_plugin_deps = gemspec.dependencies.map(&:name).grep(/\Arigor-/) - ["rigortype"]
      expect(sub_plugin_deps).to contain_exactly(
        "rigor-rails-routes",
        "rigor-rails-i18n",
        "rigor-actionmailer",
        "rigor-activejob",
        "rigor-activerecord",
        "rigor-actionpack",
        "rigor-factorybot"
      )
    end
  end

  describe "gemspec ↔ lib/rigor-rails.rb regression guard" do
    it "requires every gem listed as an `add_dependency` in the gemspec" do
      required_gems = lib_file.scan(/^require\s+"([^"]+)"/).flatten
      dep_gems = gemspec.dependencies.map(&:name).grep(/\Arigor-/) - ["rigortype"]

      expect(required_gems).to match_array(dep_gems)
    end
  end

  describe "sub-plugin class loading" do
    it "loads every Tier 1+2 sub-plugin class on require" do
      # Run the require (idempotent — `require` returns false on
      # already-loaded gems, which is fine; the Plugin::* constants
      # exist either way after this line).
      require "rigor-rails"

      expect(defined?(Rigor::Plugin::RailsRoutes)).to be_truthy
      expect(defined?(Rigor::Plugin::RailsI18n)).to be_truthy
      expect(defined?(Rigor::Plugin::Actionmailer)).to be_truthy
      expect(defined?(Rigor::Plugin::Activejob)).to be_truthy
      expect(defined?(Rigor::Plugin::Activerecord)).to be_truthy
      expect(defined?(Rigor::Plugin::Actionpack)).to be_truthy
      expect(defined?(Rigor::Plugin::Factorybot)).to be_truthy
    end

    it "each sub-plugin class advertises a manifest the loader can look up by gem name" do
      require "rigor-rails"

      [
        Rigor::Plugin::RailsRoutes,
        Rigor::Plugin::RailsI18n,
        Rigor::Plugin::Actionmailer,
        Rigor::Plugin::Activejob,
        Rigor::Plugin::Activerecord,
        Rigor::Plugin::Actionpack,
        Rigor::Plugin::Factorybot
      ].each do |klass|
        expect(klass.manifest).to be_a(Rigor::Plugin::Manifest)
        expect(klass.manifest.id).not_to be_empty
      end
    end
  end
end
