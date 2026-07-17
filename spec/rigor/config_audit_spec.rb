# frozen_string_literal: true

require "tmpdir"
require "fileutils"

require "rigor/configuration"
require "rigor/config_audit"

RSpec.describe Rigor::ConfigAudit do
  around do |example|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
  end

  def audit(config_hash, project_root = Dir.pwd)
    described_class.warnings(Rigor::Configuration.new(config_hash), project_root: project_root)
  end

  describe "unknown top-level keys" do
    it "flags a typo'd key and suggests the near miss" do
      warnings = audit("excludee" => ["generated/**"])

      unknown = warnings.find { |w| w.kind == :unknown_key }
      expect(unknown).not_to be_nil
      expect(unknown.message).to include("`excludee` is not a recognized configuration key")
      expect(unknown.message).to include("Did you mean `exclude`?")
      expect(unknown.to_h).to include("kind" => "unknown_key", "key" => "excludee", "suggestion" => "exclude")
    end

    it "flags a key with no near miss, without a suggestion" do
      warnings = audit("wibble" => 1)

      unknown = warnings.find { |w| w.kind == :unknown_key }
      expect(unknown.message).to eq("`wibble` is not a recognized configuration key; it has no effect.")
      expect(unknown.to_h).to include("suggestion" => nil)
    end

    it "stays silent on a reserved namespace" do
      # Unknown on purpose: another implementation reads it from the same file. Warning here would push
      # users to delete the key their other tool needs (ADR-99).
      expect(audit("rigor_rs" => { "ruby" => "auto" })).to all(satisfy { |w| w.kind != :unknown_key })
    end

    it "stays silent on a nested key DEFAULTS does not carry" do
      # `budget_overrun_strategy` is real, documented, and schema-declared, but absent from
      # DEFAULTS["dependencies"] — so a DEFAULTS-keyed nested check would flag a working config. Nested
      # unknowns are the schema tier's job; this axis is top-level only (ADR-99, docs/internal-spec/config.md).
      warnings = audit("dependencies" => { "budget_overrun_strategy" => "walker_cap" })

      expect(warnings).to all(satisfy { |w| w.kind != :unknown_key })
    end

    it "stays silent on a conforming config" do
      expect(audit("target_ruby" => "4.0", "paths" => ["lib"])).to all(satisfy { |w| w.kind != :unknown_key })
    end
  end

  describe "signature_paths" do
    it "flags a missing path with kind :signature_path" do
      warnings = audit("signature_paths" => ["/no/such/path/sig"])

      sig = warnings.find { |w| w.kind == :signature_path }
      expect(sig).not_to be_nil
      expect(sig.message).to include("does not exist")
      expect(sig.to_h).to include("kind" => "signature_path", "status" => "missing")
    end
  end

  describe "libraries" do
    it "flags an unknown RBS library name" do
      warnings = audit("libraries" => ["this_library_does_not_exist_xyz"])

      lib = warnings.find { |w| w.kind == :library }
      expect(lib).not_to be_nil
      expect(lib.message).to include("is not an available RBS library")
      expect(lib.to_h.fetch("name")).to eq("this_library_does_not_exist_xyz")
    end

    it "does not flag a real stdlib library" do
      warnings = audit("libraries" => ["json"])

      expect(warnings.select { |w| w.kind == :library }).to be_empty
    end
  end

  describe "disable: / severity_overrides: rule tokens" do
    it "flags a built-in-family token that names no rule" do
      warnings = audit("disable" => ["call.undefined-methdo"])

      rule = warnings.find { |w| w.kind == :disabled_rule }
      expect(rule).not_to be_nil
      expect(rule.message).to include("the suppression has no effect")
      expect(rule.to_h.fetch("token")).to eq("call.undefined-methdo")
    end

    it "flags an inert severity_overrides key under a built-in family" do
      warnings = audit("severity_overrides" => { "flow.bogus-rule" => "off" })

      override = warnings.find { |w| w.kind == :severity_override }
      expect(override).not_to be_nil
      expect(override.message).to include("the override has no effect")
    end

    it "does NOT flag a real canonical rule id" do
      warnings = audit("disable" => ["call.undefined-method", "flow.dead-assignment"])

      expect(warnings.select { |w| w.kind == :disabled_rule }).to be_empty
    end

    it "does NOT flag a bare built-in family wildcard" do
      warnings = audit("disable" => %w[call flow])

      expect(warnings.select { |w| w.kind == :disabled_rule }).to be_empty
    end

    it "does NOT flag a legacy unprefixed alias" do
      warnings = audit("disable" => ["undefined-method"])

      expect(warnings.select { |w| w.kind == :disabled_rule }).to be_empty
    end

    it "does NOT flag a plugin / non-built-in family token (FP-safety for plugin rules)" do
      warnings = audit("disable" => ["rspec.let-binding", "rbs_extended.conforms-to"])

      expect(warnings.select { |w| w.kind == :disabled_rule }).to be_empty
    end
  end

  describe "explicit bundler / rbs_collection paths" do
    it "flags an explicit bundler.bundle_path that is not a directory" do
      warnings = audit("bundler" => { "bundle_path" => "./no_such_bundle" })

      bp = warnings.find { |w| w.kind == :bundler_bundle_path }
      expect(bp).not_to be_nil
      # Pin the config-key label, not just the descriptor, so the message names which setting to fix.
      expect(bp.message).to include("bundler.bundle_path").and include("is not a directory")
    end

    it "flags an explicit bundler.lockfile that does not exist" do
      warnings = audit("bundler" => { "lockfile" => "./no_such/Gemfile.lock" })

      lf = warnings.find { |w| w.kind == :bundler_lockfile }
      expect(lf).not_to be_nil
      expect(lf.message).to include("bundler.lockfile").and include("does not exist")
    end

    it "flags an explicit rbs_collection.lockfile that does not exist" do
      warnings = audit("rbs_collection" => { "lockfile" => "./no_such/rbs_collection.lock.yaml" })

      clf = warnings.find { |w| w.kind == :rbs_collection_lockfile }
      expect(clf).not_to be_nil
      expect(clf.message).to include("rbs_collection.lockfile").and include("does not exist")
    end

    it "does not flag an explicit bundler.lockfile that exists" do
      File.write("Gemfile.lock", "GEM\n")
      warnings = audit("bundler" => { "lockfile" => "./Gemfile.lock" })

      expect(warnings.select { |w| w.kind == :bundler_lockfile }).to be_empty
    end

    it "does not flag a nil (auto-detect) bundler path" do
      warnings = audit({})

      expect(warnings).to be_empty
    end
  end
end
