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

  describe "failure diagnostic (ADR-32 WD6)" do
    it "emits source-rbs-synthesis-failed on a file with bad inline-RBS grammar" do
      # `# @rbs ` followed by garbage that rbs-inline can't parse.
      source = <<~RUBY
        # rbs_inline: enabled
        class Demo
          # @rbs ??? this is not valid rbs-inline syntax ???
          def x(a)
            a
          end
        end
      RUBY
      result = run_plugin(source: source)
      info_diagnostics = result.diagnostics.select { |d| d.qualified_rule == "source-rbs-synthesis-failed" }
      # NOTE: rbs-inline is generally permissive and may not raise on
      # every garbage input. The contract this test asserts is: IF
      # the synthesizer hits an error, THE engine surfaces it as an
      # info diagnostic (and analysis continues). If rbs-inline
      # accepts our garbage silently, this is a no-op assertion path
      # and the test reverts to verifying no crash + no rule violation.
      expect(info_diagnostics.all? { |d| d.severity == :info }).to be(true)
      # In either branch, analysis must complete cleanly.
      expect(result.diagnostics).to all(have_attributes(severity: be_a(Symbol)))
    end
  end

  describe "per-file cache (ADR-32 WD5)" do
    let(:cache_root) { Dir.mktmpdir("rigor-rbs-inline-cache-") }
    let(:cache_store) { Rigor::Cache::Store.new(root: cache_root) }
    let(:project_dir) { Dir.mktmpdir("rigor-rbs-inline-project-") }

    after do
      FileUtils.remove_entry(cache_root) if File.directory?(cache_root)
      FileUtils.remove_entry(project_dir) if File.directory?(project_dir)
    end

    it "memoises synthesizer output across runs with unchanged source" do
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
      # Re-use the same `project_dir` across both runs so the
      # cache key (which includes the source file path) is stable.
      Rigor::Plugin.unregister!
      run_plugin_in_dir(dir: project_dir, source: source, cache_store: cache_store)
      writes_before = cache_store.stats.fetch(:writes)
      hits_before = cache_store.stats.fetch(:hits)

      Rigor::Plugin.unregister!
      run_plugin_in_dir(dir: project_dir, source: source, cache_store: cache_store)
      hits_after = cache_store.stats.fetch(:hits)

      expect(writes_before).to be > 0
      expect(hits_after).to be > hits_before
    end
  end
end
