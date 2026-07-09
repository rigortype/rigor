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

  it "declares the GitLab-surfaced String / Object / Date / ERB extensions in its RBS bundle" do
    # `upcase_first` / `remove` / `in?` fired `undefined-method` on GitLab once AR typed real String
    # columns; `titlecase` / `dasherize` / `advance` / `all_day` / `Date#to_time(form)` /
    # `ERB::Util.html_escape_once` are the activesupport-core-ext gaps the survey adjudicated. The bundle
    # is validated against `rbs` by the `check-plugins` gate; this locks the specific additions.
    rbs = File.read(
      File.expand_path("../../../plugins/rigor-activesupport-core-ext/sig/active_support/core_ext.rbs", __dir__)
    )
    %w[upcase_first remove titlecase dasherize advance all_day].each do |method|
      expect(rbs).to match(/def #{method}:/), "expected RBS to declare `#{method}`"
    end
    expect(rbs).to include("def in?:")
    expect(rbs).to match(/def to_time: \(\?Symbol form\) -> Time\b/)
    expect(rbs).to include("def self.html_escape_once:")
  end
end
