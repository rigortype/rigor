# frozen_string_literal: true

# Integration spec for `plugins/rigor-activesupport-core-ext/`.
#
# ADR-25 — the bundle is a pure RBS-bundle plugin: its manifest declares `signature_paths: ["sig"]` and the
# plugin loader feeds that directory into the RBS environment. This spec proves the end-to-end path: with the
# plugin active, ActiveSupport `core_ext` selectors type-check instead of producing `call.undefined-method` diagnostics.

require "spec_helper"

unless defined?(AS_CORE_EXT_PLUGIN_LIB)
  AS_CORE_EXT_PLUGIN_LIB = File.expand_path(
    "../../../plugins/rigor-activesupport-core-ext/lib", __dir__
  )
end
$LOAD_PATH.unshift(AS_CORE_EXT_PLUGIN_LIB) unless $LOAD_PATH.include?(AS_CORE_EXT_PLUGIN_LIB)
require "rigor-activesupport-core-ext"

RSpec.describe "plugins/rigor-activesupport-core-ext" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::ActivesupportCoreExt }

  it "is a pure RBS-bundle plugin — the manifest declares signature_paths" do
    expect(plugin_class.manifest.signature_paths).to eq(["sig"])
  end

  it "contributes the core_ext sig so ActiveSupport selectors type-check" do
    source = <<~RUBY
      a = 3.days
      b = "user_account".camelize
      c = Time.current
      d = "  x   y  ".squish
      e = Array.wrap(nil)
      f = { "k" => 1 }.symbolize_keys
      g = nil.blank?
    RUBY
    result = run_plugin(source: source)
    undefined = result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }
    expect(undefined).to be_empty
  end
end
