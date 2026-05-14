# frozen_string_literal: true

# Integration spec for `examples/rigor-rails-i18n/`.
# Tier 1B of the Rails plugins roadmap. Reads
# `config/locales/*.yml`, builds a flat `dotted_key`
# catalogue per locale, and validates every literal-string
# `t(...)` / `I18n.t(...)` call site.

require "spec_helper"

RAILS_I18N_PLUGIN_LIB = File.expand_path("../../../examples/rigor-rails-i18n/lib", __dir__)
$LOAD_PATH.unshift(RAILS_I18N_PLUGIN_LIB) unless $LOAD_PATH.include?(RAILS_I18N_PLUGIN_LIB)
require "rigor-rails-i18n"

# `%{name}` is the I18n interpolation placeholder syntax —
# RuboCop's `Style/FormatStringToken` would prefer
# `%<name>s`, but here the YAML payload is data the plugin
# parses, not a Ruby format string.
# rubocop:disable Style/FormatStringToken
DEFAULT_LOCALES = {
  "config/locales/en.yml" => <<~YAML,
    en:
      users:
        welcome: "Welcome, %{name}"
        bye: "Bye"
      errors:
        messages:
          blank: "can't be blank"
  YAML
  "config/locales/ja.yml" => <<~YAML
    ja:
      users:
        welcome: "ようこそ、%{name}さん"
        bye: "さようなら"
  YAML
}.freeze
# rubocop:enable Style/FormatStringToken

RSpec.describe "examples/rigor-rails-i18n" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::RailsI18n }

  describe "recognised translation calls" do
    it "emits an info diagnostic for `t('users.welcome')` listing the resolving locales" do
      result = run_plugin(
        source: "t('users.welcome', name: 'Alice')\n",
        files: DEFAULT_LOCALES
      )
      info = plugin_diagnostics(result).find { |d| d.rule == "translation-call" }
      expect(info).not_to be_nil
      expect(info.severity).to eq(:info)
      expect(info.message).to include("users.welcome")
      expect(info.message).to include("en")
      expect(info.message).to include("ja")
    end

    it "recognises `I18n.t(...)` and `I18n.translate(...)` shapes" do
      result = run_plugin(
        source: "I18n.t('users.bye')\nI18n.translate('users.bye')\n",
        files: DEFAULT_LOCALES
      )
      infos = plugin_diagnostics(result).select { |d| d.rule == "translation-call" }
      expect(infos.size).to eq(2)
    end

    it "silently passes through calls with non-literal keys" do
      result = run_plugin(
        source: "key = 'users.welcome'\nt(key, name: 'Alice')\n",
        files: DEFAULT_LOCALES
      )
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "translation-call" }).to be_empty
      expect(diags.select { |d| d.rule == "unknown-key" }).to be_empty
    end
  end

  describe "unknown-key diagnostics" do
    it "flags a key that is missing in every locale and suggests a near match" do
      result = run_plugin(
        source: "t('users.welcom')\n",
        files: DEFAULT_LOCALES
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "unknown-key" }
      expect(err).not_to be_nil
      expect(err.message).to include("users.welcom")
      expect(err.message).to include("users.welcome")
    end
  end

  describe "missing-locale diagnostics" do
    let(:plugin_entry_with_ja) do
      {
        "gem" => "rigor-rails-i18n",
        "config" => { "configured_locales" => %w[en ja] }
      }
    end

    it "flags a key that resolves only in some configured locales" do
      result = run_plugin(
        source: "t('errors.messages.blank')\n",
        files: DEFAULT_LOCALES,
        plugin_entry: plugin_entry_with_ja
      )
      missing = plugin_diagnostics(result).find { |d| d.rule == "missing-locale" }
      expect(missing).not_to be_nil
      expect(missing.message).to include("ja")
    end

    it "suppresses `missing-locale` when the call passes `default:`" do
      result = run_plugin(
        source: "t('errors.messages.blank', default: 'fallback')\n",
        files: DEFAULT_LOCALES,
        plugin_entry: plugin_entry_with_ja
      )
      expect(plugin_diagnostics(result).select { |d| d.rule == "missing-locale" }).to be_empty
    end
  end

  describe "interpolation diagnostics" do
    it "flags a missing required interpolation" do
      result = run_plugin(
        source: "t('users.welcome')\n",
        files: DEFAULT_LOCALES
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "wrong-interpolation" }
      expect(err).not_to be_nil
      expect(err.message).to include("name")
    end

    it "warns about an extra interpolation key not used by any locale's value" do
      result = run_plugin(
        source: "t('users.welcome', name: 'Alice', extra: 'unused')\n",
        files: DEFAULT_LOCALES
      )
      warn = plugin_diagnostics(result).find { |d| d.rule == "extra-interpolation" }
      expect(warn).not_to be_nil
      expect(warn.message).to include("extra")
    end

    it "ignores reserved I18n option keys (default:, scope:, locale:, count:)" do
      result = run_plugin(
        source: "t('users.bye', default: 'bye', scope: :other, locale: :en, count: 1)\n",
        files: DEFAULT_LOCALES
      )
      expect(plugin_diagnostics(result).select { |d| d.rule == "extra-interpolation" }).to be_empty
    end
  end

  describe "load errors" do
    it "emits a `load-error` warning for a malformed YAML file" do
      malformed_yaml = "en:\n  bad:\n :: oops"
      files = { "config/locales/bad.yml" => malformed_yaml }
      result = run_plugin(
        source: "# noop\n",
        files: files
      )
      load_err = plugin_diagnostics(result).find { |d| d.rule == "load-error" }
      expect(load_err).not_to be_nil
      expect(load_err.message).to include("YAML syntax error")
      expect(load_err.message).to include("bad.yml")
    end
  end

  describe "configuration" do
    let(:custom_files) do
      {
        "i18n/en.yml" => <<~YAML
          en:
            greeting: "Hello"
        YAML
      }
    end

    let(:custom_plugin_entry) do
      {
        "gem" => "rigor-rails-i18n",
        "config" => { "locale_search_paths" => ["i18n"] }
      }
    end

    it "respects custom `locale_search_paths`" do
      result = run_plugin(
        source: "t('greeting')\n",
        files: custom_files,
        plugin_entry: custom_plugin_entry
      )
      info = plugin_diagnostics(result).find { |d| d.rule == "translation-call" }
      expect(info).not_to be_nil
    end
  end
end
