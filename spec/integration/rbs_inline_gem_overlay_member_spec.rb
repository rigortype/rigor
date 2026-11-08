# frozen_string_literal: true

# Issue #2974 — an inline annotation on a method the ADR-72 ActiveSupport overlay also declares binds, as a
# project `sig/` declaration does (`spec/rigor/environment/gem_overlay_member_stand_down_spec.rb` pins those rows).
#
# The overlay loads with the plugins' deferred signature files, so its `Integer#ordinalize` stands down to the
# inline one, and the body is checked against `() -> Symbol` rather than the overlay's `String`. This row lives
# under `spec/integration/` because it needs the rbs-inline gem, which the RBS compatibility bundle that runs
# `spec/rigor/environment` does not install.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "an inline annotation on a gem-overlay method (#2974)" do
  # Requires and registers the bundled plugin from source; see `rbs_inline_cross_file_method_spec.rb`.
  def require_rbs_inline_plugin
    plugin_lib = File.expand_path("../../plugins/rigor-rbs-inline/lib", __dir__)
    $LOAD_PATH.unshift(plugin_lib) unless $LOAD_PATH.include?(plugin_lib)
    require "rigor-rbs-inline"
    Rigor::Plugin.unregister!
    lambda do |_name|
      Rigor::Plugin.register(Rigor::Plugin::RbsInline)
      true
    end
  end

  def write_project(dir)
    File.write(File.join(dir, "Gemfile.lock"), <<~LOCK)
      GEM
        remote: https://rubygems.org/
        specs:
          activesupport (7.1.3)

      PLATFORMS
        ruby

      DEPENDENCIES
        activesupport

      BUNDLED WITH
         2.5.6
    LOCK
    File.write(File.join(dir, "code.rb"), <<~RUBY)
      # rbs_inline: enabled

      class Integer
        #: () -> Symbol
        def ordinalize = :first
      end

      Rigor.dump_type(1.ordinalize)
      1.nope
    RUBY
  end

  def run_check(dir)
    plugin_requirer = require_rbs_inline_plugin
    configuration = Rigor::Configuration.new(
      "paths" => [File.join(dir, "code.rb")],
      "plugins" => [{ "gem" => "rigor-rbs-inline", "id" => "rbs-inline" }],
      "bundler" => { "lockfile" => "Gemfile.lock", "auto_detect" => true }
    )
    guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil,
                                            plugin_requirer: plugin_requirer))
  end

  it "binds the annotation over the overlay's declaration" do
    Dir.mktmpdir("rigor-inline-overlay-member-") do |dir|
      write_project(dir)
      result = Dir.chdir(dir) { run_check(dir) }
      rules = result.diagnostics.map(&:rule)

      expect(rules).not_to include("rbs.coverage.definition-build-failed", "def.return-type-mismatch")
      expect(result.diagnostics.select { |d| d.rule == "dump.type" }.map(&:message)).to eq(["dump_type: Symbol"])
      expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }.map(&:method_name)).to eq(["nope"])
    end
  end
end
