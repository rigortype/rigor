# frozen_string_literal: true

require "spec_helper"

# Structural guard companion to `all_plugins_load_spec.rb` (#921). ADR-9 gives a plugin two independent
# channels that happen to share a name inside one plugin's own code — `Plugin::Base.producer` (an
# internally cached computation, read back via `producer_value`) and `services.fact_store.publish` (the
# ADR-9 fact, read by another plugin's `read_fact` / `consumes:`). rigor-factorybot declared a
# `:factory_index` producer and rigor-rspec's manifest correctly declared `consumes: [{plugin_id:
# "factorybot", name: :factory_index}]`, but nothing ever called `fact_store.publish` for it and it never
# appeared in `produces:` — so the consumer's `read_fact` silently returned nil forever. The loader's
# missing-producer check (ADR-9 § "Early validation") catches a `consumes:` entry with NO matching
# `produces:` entry anywhere in the registry, but it cannot catch a plugin that declares `produces:`
# without ever publishing, or a required (non-optional) `consumes:` entry against a plugin that is not
# part of the same run — so this spec asserts the stronger, static closure across every bundled plugin's
# manifest: every `consumes:` entry names a `(plugin_id, fact)` pair that some bundled plugin's
# `produces:` actually lists, regardless of whether that producer is loaded in any particular run.
PRODUCES_CLOSURE_REPO_ROOT = File.expand_path("../..", __dir__)

PRODUCES_CLOSURE_PLUGIN_DIRS = (
  Dir[File.join(PRODUCES_CLOSURE_REPO_ROOT, "plugins", "*", "")] +
  Dir[File.join(PRODUCES_CLOSURE_REPO_ROOT, "examples", "*", "")]
).sort.freeze

RSpec.describe "bundled plugin manifests: every consumes: entry names a published produces: fact (#921)" do
  before do
    PRODUCES_CLOSURE_PLUGIN_DIRS.each do |dir|
      lib = File.join(dir, "lib")
      $LOAD_PATH.unshift(lib) if Dir.exist?(lib) && !$LOAD_PATH.include?(lib)

      entry = File.join(dir, "lib", "#{File.basename(dir)}.rb")
      require entry if File.file?(entry)
    end
  end

  # Every concrete `Plugin::Base` subclass with a valid manifest, keyed by manifest id. Scans the
  # namespace (like `all_plugins_load_spec.rb`) rather than the loader registry, so it is unaffected by
  # another spec's `Rigor::Plugin.unregister!`.
  def loaded_plugin_classes
    Rigor::Plugin.constants
                 .map { |const| Rigor::Plugin.const_get(const) }
                 .select { |value| value.is_a?(Class) && value < Rigor::Plugin::Base }
                 .select { |klass| safe_manifest(klass) }
  end

  def safe_manifest(klass)
    klass.manifest
  rescue ArgumentError
    nil
  end

  it "has a producer for every declared consumption" do
    classes = loaded_plugin_classes
    produced = classes.each_with_object({}) do |klass, acc|
      manifest = klass.manifest
      (acc[manifest.id] ||= []).concat(manifest.produces)
    end

    orphans = classes.flat_map do |klass|
      klass.manifest.consumes.filter_map do |consumption|
        next if produced.fetch(consumption.plugin_id, []).include?(consumption.name)

        "#{klass.manifest.id} consumes (#{consumption.plugin_id.inspect}, #{consumption.name.inspect}), " \
          "which #{consumption.plugin_id.inspect} does not list in produces: " \
          "(has #{produced.fetch(consumption.plugin_id, []).inspect})"
      end
    end

    expect(orphans).to eq([]), orphans.join("\n")
  end
end
