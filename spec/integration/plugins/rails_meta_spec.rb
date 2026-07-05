# frozen_string_literal: true

# Integration spec for `plugins/rigor-rails/`. Verifies the Tier 1+2 Rails meta-gem's contract:
#
# Requiring `rigor-rails` side-effects a `Rigor::Plugin.register` call for every Tier 1+2 plugin class — so the
# plugin loader can later look them up by id when `.rigor.yml` enumerates them.
#
# All sub-plugins ship bundled in the `rigortype` gem; no separate $LOAD_PATH manipulation or gemspec loading
# is needed.

require "spec_helper"
require "rigor-rails"

RSpec.describe "plugins/rigor-rails meta-gem" do
  describe "sub-plugin class loading" do
    it "loads every Tier 1+2 sub-plugin class on require" do
      expect(defined?(Rigor::Plugin::RailsRoutes)).to be_truthy
      expect(defined?(Rigor::Plugin::RailsI18n)).to be_truthy
      expect(defined?(Rigor::Plugin::Actionmailer)).to be_truthy
      expect(defined?(Rigor::Plugin::Activejob)).to be_truthy
      expect(defined?(Rigor::Plugin::Activerecord)).to be_truthy
      expect(defined?(Rigor::Plugin::Actionpack)).to be_truthy
      expect(defined?(Rigor::Plugin::Factorybot)).to be_truthy
    end

    it "each sub-plugin class advertises a manifest the loader can look up by gem name" do
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
