# frozen_string_literal: true

# Integration spec for `plugins/rigor-rbs-inline/`.
#
# ADR-32 — the plugin calls the upstream `rbs-inline` library
# to synthesise RBS from Ruby source files carrying
# rbs-inline-shaped comments and contributes the result to the
# RBS environment via the `source_rbs_synthesizer:` manifest
# hook. This spec proves the end-to-end path: with the plugin
# active, a `# @rbs name: T`-shaped parameter annotation
# enforces the contract just like a hand-written `.rbs`
# signature would.

require "spec_helper"

unless defined?(RBS_INLINE_PLUGIN_LIB)
  RBS_INLINE_PLUGIN_LIB = File.expand_path(
    "../../../plugins/rigor-rbs-inline/lib", __dir__
  )
end
$LOAD_PATH.unshift(RBS_INLINE_PLUGIN_LIB) unless $LOAD_PATH.include?(RBS_INLINE_PLUGIN_LIB)
require "rigor-rbs-inline"

RSpec.describe "plugins/rigor-rbs-inline" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::RbsInline }

  it "declares the rbs-inline plugin id and config schema" do
    expect(plugin_class.manifest.id).to eq("rbs-inline")
    expect(plugin_class.manifest.config_schema).to eq("require_magic_comment" => :boolean)
  end

  it "exposes a per-instance source_rbs_synthesizer via the instance manifest" do
    instance = plugin_class.new(
      services: Rigor::Plugin::Services.new(
        reflection: Rigor::Reflection,
        type: Rigor::Type::Combinator,
        configuration: Rigor::Configuration.new
      )
    )
    expect(instance.manifest.source_rbs_synthesizer).to respond_to(:call)
  end

  describe "default mode (require_magic_comment: true, ADR-32 WD2)" do
    it "flags an argument-type mismatch on a class-wrapped # @rbs param annotation" do
      source = <<~RUBY
        # rbs_inline: enabled
        class AscDesc
          # @rbs asc_or_desc: :asc | :desc
          def ascdesc(asc_or_desc)
            asc_or_desc
          end
        end

        AscDesc.new.ascdesc(:bad)
      RUBY
      result = run_plugin(source: source)
      mismatches = result.diagnostics.select { |d| d.qualified_rule == "call.argument-type-mismatch" }
      expect(mismatches).not_to be_empty
      expect(mismatches.first.message).to match(/:asc \| :desc/)
      expect(mismatches.first.message).to match(/:bad/)
    end

    it "contributes nothing for a file without the magic comment" do
      source = <<~RUBY
        # NOTE: no `# rbs_inline: enabled` magic comment here.
        class AscDesc
          # @rbs asc_or_desc: :asc | :desc
          def ascdesc(asc_or_desc)
            asc_or_desc
          end
        end

        AscDesc.new.ascdesc(:bad)
      RUBY
      result = run_plugin(source: source)
      mismatches = result.diagnostics.select { |d| d.qualified_rule == "call.argument-type-mismatch" }
      expect(mismatches).to be_empty
    end
  end

  describe "host-context override (require_magic_comment: false, ADR-32 WD10)" do
    it "treats every file as if it carried the magic comment" do
      source = <<~RUBY
        class AscDesc
          # @rbs asc_or_desc: :asc | :desc
          def ascdesc(asc_or_desc)
            asc_or_desc
          end
        end

        AscDesc.new.ascdesc(:bad)
      RUBY
      result = run_plugin(
        source: source,
        plugin_entry: {
          "gem" => "rigor-rbs-inline",
          "config" => { "require_magic_comment" => false }
        }
      )
      mismatches = result.diagnostics.select { |d| d.qualified_rule == "call.argument-type-mismatch" }
      expect(mismatches).not_to be_empty
    end
  end
end
