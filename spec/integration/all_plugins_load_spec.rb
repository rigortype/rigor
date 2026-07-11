# frozen_string_literal: true

require "spec_helper"

# Structural guard: EVERY bundled plugin (`plugins/*`) and example (`examples/*`) must load and register a
# valid plugin. The per-plugin integration specs cover *behaviour*, but nothing enumerates the whole set — so a
# newly-added plugin with no spec of its own, or one whose gem entry / manifest breaks, could slip through CI
# unnoticed. This spec globs both trees so no plugin escapes a load attempt, and is the companion to
# `external_plugin_spec.rb` (which proves the *out-of-tree* load path): together they guard that the plugin
# contract keeps working for every shipped plugin and for third-party authors.
#
# Loadability is exercised by `require`-ing each gem entry. `require` is idempotent: a broken entry raises here
# when no other spec loaded it first, and a loadable one never falsely fails — so "every entry is loadable"
# holds regardless of which worker/order runs this file under `make test-parallel`. Registration + manifest
# validity are then asserted against the public `Rigor::Plugin` surface.

# Repo root from spec/integration/.
ALL_PLUGINS_REPO_ROOT = File.expand_path("../..", __dir__)

# Directories under plugins/ and examples/ (trailing slash → dirs only, so the README.md files are not picked up).
ALL_PLUGINS_DIRS = (
  Dir[File.join(ALL_PLUGINS_REPO_ROOT, "plugins", "*", "")] +
  Dir[File.join(ALL_PLUGINS_REPO_ROOT, "examples", "*", "")]
).sort.freeze

# Directories under plugins/ that are not loadable Rigor plugins (no `lib/<name>.rb` entry, no `Plugin::Base`)
# and are therefore out of scope for this guard. Currently empty: the one historical exception,
# `rigor-playground` (a standalone Rack application), now lives under `apps/`, outside these globs entirely.
ALL_PLUGINS_SKIP = %w[].freeze

ALL_PLUGINS_LOADABLE_DIRS = ALL_PLUGINS_DIRS.reject do |dir|
  ALL_PLUGINS_SKIP.include?(File.basename(dir))
end.freeze

# Meta-gems aggregate other plugins' entry points (`require "rigor-rails-routes"` …) and register no checker
# plugin of their own, so they are asserted only for clean loading, not for registration.
ALL_PLUGINS_META_GEM_IDS = %w[rails].freeze

# Put every plugin's lib on the load path up front so a meta-gem entry (which requires its sub-plugins by gem
# name) resolves regardless of example order.
ALL_PLUGINS_LOADABLE_DIRS.each do |dir|
  lib = File.join(dir, "lib")
  $LOAD_PATH.unshift(lib) if Dir.exist?(lib) && !$LOAD_PATH.include?(lib)
end

RSpec.describe "bundled plugins and examples all load (structural guard)" do
  def entry_for(dir)
    File.join(dir, "lib", "#{File.basename(dir)}.rb")
  end

  def id_for(dir)
    File.basename(dir).sub(/\Arigor-/, "")
  end

  # Every `Rigor::Plugin::*` constant that is a concrete plugin class whose declared manifest id matches `id`.
  # Scanning the namespace (rather than the loader registry) keeps the assertion robust to other specs'
  # `Rigor::Plugin.unregister!` calls — a required plugin's class constant persists even when the registry is
  # cleared.
  def plugin_class_for(id)
    Rigor::Plugin.constants
                 .map { |const| Rigor::Plugin.const_get(const) }
                 .select { |value| value.is_a?(Class) && value < Rigor::Plugin::Base }
                 .find { |klass| safe_manifest_id(klass) == id }
  end

  # A `Plugin::Base` subclass that never declared a manifest raises `ArgumentError` from `.manifest`; treat that
  # as "not this id" rather than letting the scan blow up on an unrelated class.
  def safe_manifest_id(klass)
    klass.manifest.id
  rescue ArgumentError
    nil
  end

  ALL_PLUGINS_LOADABLE_DIRS.each do |dir|
    describe File.basename(dir) do
      it "ships a gem entry point" do
        expect(File.file?(entry_for(dir))).to be(true), "expected gem entry #{entry_for(dir)} to exist"
      end

      it "loads via require without raising" do
        expect { require entry_for(dir) }.not_to raise_error
      end

      unless ALL_PLUGINS_META_GEM_IDS.include?(File.basename(dir).sub(/\Arigor-/, ""))
        it "registers a Plugin::Base subclass carrying a valid manifest" do
          require entry_for(dir)
          klass = plugin_class_for(id_for(dir))
          expect(klass).not_to(
            be_nil,
            "expected a Rigor::Plugin::* subclass registering manifest id #{id_for(dir).inspect}"
          )
          expect(klass.manifest.id).to match(Rigor::Plugin::Manifest::VALID_ID)
          expect(klass.manifest.version).not_to be_empty
        end
      end
    end
  end

  it "covers every plugins/* and examples/* directory" do
    # Guards the guard: if a new plugins/* or examples/* directory appears with no gem entry (and it is not
    # a declared exception in ALL_PLUGINS_SKIP), surface it so the omission is a deliberate decision, not an
    # oversight.
    skipped = ALL_PLUGINS_DIRS.map { |dir| File.basename(dir) } -
              ALL_PLUGINS_LOADABLE_DIRS.map { |dir| File.basename(dir) }
    expect(skipped).to eq(ALL_PLUGINS_SKIP)
  end
end
