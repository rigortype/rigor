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

  # Issue #697 — the one axis whose subject resolves to SOMETHING: a bundled plugin's `sig/`
  # reached through `signature_paths:` loads the RBS without the manifest, so ADR-26
  # `open_receivers:` never applies and the plugin's deliberately partial declarations report
  # working code as undefined.
  describe "a bundled plugin's sig/ reached through signature_paths:" do
    let(:plugin_sig) { Rigor::SignaturePathAudit.bundled_plugin_sig_dirs.fetch("rigor-activerecord") }

    it "flags it with kind :bundled_plugin_signature_path and names the fix" do
      warnings = audit("signature_paths" => [plugin_sig])

      route = warnings.find { |w| w.kind == :bundled_plugin_signature_path }
      expect(route).not_to be_nil
      expect(route.message).to include("Add \"rigor-activerecord\" to `plugins:`")
      expect(route.to_h).to include("kind" => "bundled_plugin_signature_path", "gem" => "rigor-activerecord")
    end

    it "stays silent when plugins: already names the plugin" do
      warnings = audit("signature_paths" => [plugin_sig], "plugins" => ["rigor-activerecord"])

      expect(warnings.select { |w| w.kind == :bundled_plugin_signature_path }).to be_empty
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

    it "does NOT flag a token under a non-check engine family (FP-safety for rows it cannot enumerate)" do
      warnings = audit("disable" => ["rbs_extended.conforms-to", "configuration-error"])

      expect(warnings.select { |w| w.kind == :disabled_rule }).to be_empty
    end
  end

  # Issue #1953 — `disable:` reaches a built-in check-rule row by its id, a family or `all`, and a plugin's row by its
  # qualified id only, so every other token is inert and flagged.
  describe "disable: tokens since qualified-id matching" do
    def disabled_warnings(config_hash)
      audit(config_hash).select { |w| w.kind == :disabled_rule }
    end

    def flagged_tokens(config_hash)
      disabled_warnings(config_hash).map { |w| w.fields.fetch("token") }
    end

    it "does NOT flag a token `disable:` reaches" do
      tokens = %w[all call undefined-method call.undefined-method pre-eval pre-eval.parse-error]
      expect(flagged_tokens("disable" => tokens)).to be_empty
    end

    it "flags a bare token that names no rule, and a plugin's bare rule, with the qualified spelling as the hint" do
      warnings = disabled_warnings("disable" => %w[no-such-rule rspec.let-binding])

      expect(warnings.map { |w| w.fields.fetch("token") }).to eq(%w[no-such-rule rspec.let-binding])
      expect(warnings.map(&:message)).to all(include("is not a recognized rule id").and(include("plugin.<id>.<rule>")))
    end

    it "flags a run-level row the policy keeps on `severity_overrides:`, by any spelling" do
      tokens = %w[plugin_loader.load-error plugin_loader load-error runtime-error pool-degraded
                  plugin_trust.read-refused rbs.coverage.missing-gem rbs.coverage
                  dynamic.dependency-source.gem-not-found]
      warnings = disabled_warnings("disable" => tokens)

      expect(warnings.map { |w| w.fields.fetch("token") }).to eq(tokens)
      expect(warnings.map(&:message)).to all(include("which `disable:` does not reach; use `severity_overrides:`"))
    end

    it "does NOT flag a qualified token for a configured bundled plugin, by gem name or explicit id" do
      valid = %w[plugin.rails-i18n.load-error plugin.rails-i18n plugin.acme.tools.x plugin.acme.tools]
      config = { "plugins" => ["rigor-rails-i18n", { "gem" => "acme-rigor-1953", "id" => "acme.tools" }],
                 "disable" => valid + ["plugin.shoulda-matchers.unknown-column"] }
      # The explicit `id:` keeps the check on: the unconfigured plugin's token is still flagged.
      expect(flagged_tokens(config)).to eq(["plugin.shoulda-matchers.unknown-column"])
    end

    it "flags a qualified token for a plugin `plugins:` does not configure" do
      config = { "plugins" => ["rigor-rails-i18n"],
                 "disable" => %w[plugin.shoulda-matchers.unknown-column plugin.rails-i18nx plugin.acme.tools.x] }
      warnings = disabled_warnings(config)

      expect(warnings.map { |w| w.fields.fetch("token") })
        .to eq(%w[plugin.shoulda-matchers.unknown-column plugin.rails-i18nx plugin.acme.tools.x])
      expect(warnings.map(&:message)).to all(include("names no plugin `plugins:` configures"))
    end

    it "does NOT flag any qualified token while a third-party gem's id is unknown without loading it" do
      config = { "plugins" => %w[rigor-rails-i18n acme-rigor-1953], "disable" => ["plugin.whatever.rule"] }
      expect(flagged_tokens(config)).to be_empty
    end
  end

  # Issue #1985 — a plugin's row answers to `severity_overrides:` by its qualified id only, so a key that reaches no
  # row is flagged; a key that does (a built-in id or family, a loader row, a configured plugin) never is.
  describe "severity_overrides: keys since qualified-id matching" do
    def override_warnings(config_hash)
      audit(config_hash).select { |w| w.kind == :severity_override }
    end

    def flagged_keys(config_hash)
      override_warnings(config_hash).map { |w| w.fields.fetch("token") }
    end

    def overrides(*keys)
      keys.to_h { [it, "off"] }
    end

    it "does NOT flag a key the map reaches" do
      keys = %w[call call.undefined-method flow.always-truthy-condition pre-eval pre-eval.parse-error
                load-error runtime-error pool-degraded plugin_loader.load-error plugin_loader.runtime-error
                plugin_trust.read-refused rbs.coverage.missing-gem dynamic.dependency-source.gem-not-found
                rbs_extended.unsatisfied-conformance fallback configuration-error
                source-rbs-synthesis-failed source-rbs-annotation-not-honoured
                return-type-collapse exceptional-disagreement lower-tier-contradiction]
      expect(flagged_keys("severity_overrides" => overrides(*keys))).to be_empty
    end

    # The audit's silence on a working key rests on `NON_CHECK_DIAGNOSTIC_IDS` / `NON_CHECK_DIAGNOSTIC_FAMILIES`
    # naming every id the engine emits outside the catalogue. Scan `lib/` for `rule: "..."` literals (comment lines
    # skipped) and require the override audit to leave each one unflagged. The scan sees
    # literals only, so an id built at run time (`Conflict#to_diagnostic`'s kebab-cased reason) is pinned
    # separately below. Plugins under `plugins/` emit `plugin.<id>.*` rows and need no entry.
    def literal_rule_ids
      lib = File.expand_path("../../lib", __dir__)
      lines = Dir.glob("#{lib}/**/*.rb").flat_map { File.readlines(it) }
      literals = lines.reject { it.lstrip.start_with?("#") }.flat_map { it.scan(/\brule: "([a-z][\w.-]*)"/).flatten }
      catalogue = Rigor::Analysis::CheckRules
      constants = catalogue.constants.filter_map { |name| catalogue.const_get(name) if name.start_with?("RULE_") }
      (literals + constants.grep(String)).uniq
    end

    it "knows every literal `rule:` id lib/ emits" do
      expect(literal_rule_ids).to include("fallback", "pool-degraded", "call.undefined-method")
      expect(flagged_keys("severity_overrides" => overrides(*literal_rule_ids))).to be_empty
    end

    it "knows the contribution_merge conflict reasons, which are kebab-cased at run time" do
      ids = Rigor::FlowContribution::CONFLICT_VALID_REASONS.map { it.to_s.tr("_", "-") }
      expect(flagged_keys("severity_overrides" => overrides(*ids))).to be_empty
    end

    # The override-only ids stay out of `NON_CHECK_DIAGNOSTIC_IDS`: a marker or `disable:` cannot suppress those rows,
    # so naming one there keeps its warning.
    it "still warns on `disable: [fallback]` and a conflict id, which `disable:` cannot reach" do
      tokens = %w[fallback return-type-collapse]
      warnings = audit("disable" => tokens).select { |w| w.kind == :disabled_rule }
      expect(warnings.map { |w| w.fields.fetch("token") }).to eq(tokens)
    end

    it "flags a plugin's bare rule, with the qualified spelling as the hint" do
      warnings = override_warnings("severity_overrides" => overrides("no-such-rule", "rspec.let-binding", "rspec"))

      expect(warnings.map { |w| w.fields.fetch("token") }).to eq(%w[no-such-rule rspec.let-binding rspec])
      expect(warnings.map(&:message)).to all(include("severity_overrides:").and(include("the override has no effect"))
                                               .and(include("plugin.<id>.<rule>")))
    end

    it "flags `all` and a loader key naming no loader row" do
      expect(flagged_keys("severity_overrides" => overrides("all", "plugin_loader", "plugin_loader.bogus")))
        .to eq(%w[all plugin_loader plugin_loader.bogus])
      all_warning = override_warnings("severity_overrides" => overrides("all")).first
      expect(all_warning.message).not_to include("plugin.<id>.<rule>")
    end

    it "does NOT flag a qualified key for a configured bundled plugin, by gem name or explicit id" do
      valid = %w[plugin.rails-i18n.load-error plugin.rails-i18n plugin.acme.tools.x plugin.acme.tools]
      config = { "plugins" => ["rigor-rails-i18n", { "gem" => "acme-rigor-1985", "id" => "acme.tools" }],
                 "severity_overrides" => overrides(*valid, "plugin.shoulda-matchers.unknown-column") }

      expect(flagged_keys(config)).to eq(["plugin.shoulda-matchers.unknown-column"])
      expect(override_warnings(config).first.message).to include("names no plugin `plugins:` configures")
    end

    it "does NOT flag a qualified key while a third-party gem's id is unknown without loading it" do
      config = { "plugins" => %w[rigor-rails-i18n acme-rigor-1985],
                 "severity_overrides" => overrides("plugin.whatever.rule") }
      expect(flagged_keys(config)).to be_empty
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
