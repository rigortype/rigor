# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Plain data in, plain data out: `Configuration::Coercion` reads no `Configuration` state, so each example calls one
# coercion with a value and compares the result or the error. `configuration_spec.rb` pins the same keys through
# `Configuration.new` and `.load` (the plugin entry, the severity profile, `parallel.workers`, `sig_gen`, the
# `pre_eval:` globs, the effect keys); the examples here pin what that file does not reach, and the error messages
# the CLI prints.
RSpec.describe Rigor::Configuration::Coercion do
  def error_message(&)
    expect(&).to raise_error(Rigor::ConfigurationError)
    begin
      yield
    rescue Rigor::ConfigurationError => e
      e.message
    end
  end

  describe ".coerce_target_ruby" do
    it "accepts a `<major>.<minor>` or `<major>.<minor>.<patch>` version and `latest`, as a frozen String" do
      expect(described_class.coerce_target_ruby("3.4")).to eq("3.4")
      expect(described_class.coerce_target_ruby("3.4.1")).to eq("3.4.1")
      expect(described_class.coerce_target_ruby("latest")).to eq("latest")
      expect(described_class.coerce_target_ruby(+"3.4")).to be_frozen
    end

    it "reads a YAML float as its spelling" do
      expect(described_class.coerce_target_ruby(3.4)).to eq("3.4")
    end

    it "rejects anything else, naming the value" do
      expect(error_message { described_class.coerce_target_ruby("ruby") })
        .to eq('target_ruby must be a version (e.g. "3.4", "4.0", "3.4.0") or "latest", got "ruby"')
      expect(error_message { described_class.coerce_target_ruby(nil) }).to end_with("got nil")
      expect(error_message { described_class.coerce_target_ruby("3") }).to end_with('got "3"')
    end
  end

  describe ".coerce_plugin_entry" do
    it "keeps the gem-name shorthand as a frozen copy" do
      entry = +"rigor-foo"
      coerced = described_class.coerce_plugin_entry(entry)
      expect(coerced).to eq("rigor-foo")
      expect(coerced).to be_frozen
      expect(coerced).not_to equal(entry)
    end

    it "stringifies the keys of the full form and freezes it" do
      coerced = described_class.coerce_plugin_entry({ gem: "rigor-foo", "id" => "foo" })
      expect(coerced).to eq({ "gem" => "rigor-foo", "id" => "foo" })
      expect(coerced).to be_frozen
    end

    it "rejects every other shape" do
      expect(error_message { described_class.coerce_plugin_entry(42) })
        .to eq("plugin configuration entry must be a String or Hash, got 42")
    end
  end

  describe ".coerce_core_root" do
    it "reads nil as unset and answers a frozen copy of a path" do
      expect(described_class.coerce_core_root(nil)).to be_nil
      expect(described_class.coerce_core_root("core")).to eq("core")
      expect(described_class.coerce_core_root(+"core")).to be_frozen
    end

    it "rejects a value that is not a path String, and an empty one" do
      expect(error_message { described_class.coerce_core_root(%w[a]) })
        .to eq('core_root must be a directory path, got ["a"]')
      expect(error_message { described_class.coerce_core_root("  ") }).to eq("core_root must not be empty")
    end
  end

  describe ".coerce_baseline_path" do
    it "reads nil and the explicit-disable `false` as no baseline" do
      expect(described_class.coerce_baseline_path(nil)).to be_nil
      expect(described_class.coerce_baseline_path(false)).to be_nil
    end

    it "answers any other value as a String" do
      expect(described_class.coerce_baseline_path("b.yml")).to eq("b.yml")
      expect(described_class.coerce_baseline_path(:b)).to eq("b")
    end
  end

  describe ".coerce_cache_validation" do
    it "keeps the three recognised spellings and fails soft to `auto` for anything else" do
      %w[auto stat digest].each { |v| expect(described_class.coerce_cache_validation(v)).to eq(v) }
      expect(described_class.coerce_cache_validation(:digest)).to eq("digest")
      expect(described_class.coerce_cache_validation("strict")).to eq("auto")
      expect(described_class.coerce_cache_validation(nil)).to eq("auto")
    end
  end

  describe ".coerce_plugins_isolation" do
    it "reads nil as unset and keeps the two selectable strategies" do
      expect(described_class.coerce_plugins_isolation(nil)).to be_nil
      expect(described_class.coerce_plugins_isolation("none")).to eq("none")
      expect(described_class.coerce_plugins_isolation(:process)).to eq("process")
    end

    it "rejects `ruby_box` with the environment-variable hint" do
      expect(error_message { described_class.coerce_plugins_isolation("ruby_box") })
        .to start_with("plugins_isolation: ruby_box cannot be selected from the configuration file")
        .and include("RIGOR_PLUGIN_ISOLATION=ruby_box")
    end

    it "rejects an unknown strategy, listing the selectable ones" do
      expect(error_message { described_class.coerce_plugins_isolation("thread") })
        .to eq('plugins_isolation must be one of ["none", "process"] ' \
               '(`ruby_box` is environment-only), got "thread"')
    end
  end

  describe ".coerce_network_policy" do
    it "answers the Symbol for either spelling" do
      expect(described_class.coerce_network_policy("allowlist")).to eq(:allowlist)
      expect(described_class.coerce_network_policy(:disabled)).to eq(:disabled)
    end

    it "rejects an unknown policy" do
      expect(error_message { described_class.coerce_network_policy("open") })
        .to eq('plugins_io.network must be one of [:disabled, :allowlist], got "open"')
    end
  end

  describe ".coerce_severity_profile" do
    it "answers the Symbol for either spelling and rejects an unknown profile" do
      expect(described_class.coerce_severity_profile("strict")).to eq(:strict)
      expect(described_class.coerce_severity_profile(:lenient)).to eq(:lenient)
      expect(error_message { described_class.coerce_severity_profile("harsh") })
        .to eq('severity_profile must be one of [:lenient, :balanced, :strict], got "harsh"')
    end
  end

  describe ".coerce_severity_overrides" do
    it "answers a frozen { rule => Symbol } map and keeps an unknown rule id" do
      coerced = described_class.coerce_severity_overrides({ "call" => "warning", :"made.up" => :off })
      expect(coerced).to eq({ "call" => :warning, "made.up" => :off })
      expect(coerced).to be_frozen
    end

    it "rejects a value that is not a Hash" do
      expect(error_message { described_class.coerce_severity_overrides(%w[a]) })
        .to eq('severity_overrides must be a Hash, got ["a"]')
    end

    it "explains a bare YAML boolean, and offers `off` for `false`" do
      expect(error_message { described_class.coerce_severity_overrides({ "call" => false }) })
        .to eq('severity_overrides["call"] is false, a YAML boolean — did you mean the string "off"? ' \
               "Bare off/on/no/yes/true/false are parsed as booleans; quote the severity (e.g. \"off\").")
      expect(error_message { described_class.coerce_severity_overrides({ "call" => true }) })
        .to start_with('severity_overrides["call"] is true, a YAML boolean Bare')
    end

    it "rejects an unknown severity, listing the valid ones" do
      expect(error_message { described_class.coerce_severity_overrides({ "call" => "fatal" }) })
        .to eq('severity_overrides["call"] must be one of [:error, :warning, :info, :off], got "fatal"')
    end
  end

  describe ".coerce_parallel_workers" do
    it "reads an Integer or its string spelling" do
      expect(described_class.coerce_parallel_workers(0)).to eq(0)
      expect(described_class.coerce_parallel_workers("4")).to eq(4)
    end

    it "rejects a negative count and a non-integer, with the reason" do
      expect(error_message { described_class.coerce_parallel_workers(-1) })
        .to eq("parallel.workers must be a non-negative Integer, got -1 (parallel.workers must be >= 0, got -1)")
      expect(error_message { described_class.coerce_parallel_workers("many") })
        .to start_with('parallel.workers must be a non-negative Integer, got "many" (invalid value')
      expect(error_message { described_class.coerce_parallel_workers(nil) })
        .to start_with("parallel.workers must be a non-negative Integer, got nil (")
    end
  end

  describe ".coerce_sig_gen_inline_declared" do
    it "defaults to :write for an absent or empty section" do
      expect(described_class.coerce_sig_gen_inline_declared(nil)).to eq(:write)
      expect(described_class.coerce_sig_gen_inline_declared({})).to eq(:write)
    end

    it "answers the Symbol of a recognised value" do
      expect(described_class.coerce_sig_gen_inline_declared({ "inline_declared" => "skip" })).to eq(:skip)
    end

    it "rejects a section that is not a mapping, an unknown key and an unknown value" do
      expect(error_message { described_class.coerce_sig_gen_inline_declared("skip") })
        .to eq('sig_gen must be a mapping, got "skip"')
      expect(error_message { described_class.coerce_sig_gen_inline_declared({ "inline_declare" => "skip" }) })
        .to eq('sig_gen has unknown key(s) ["inline_declare"]; known keys: ["inline_declared"]')
      expect(error_message { described_class.coerce_sig_gen_inline_declared({ "inline_declared" => "omit" }) })
        .to eq('sig_gen.inline_declared must be one of ["write", "skip"], got "omit"')
    end
  end

  describe ".coerce_bleeding_edge" do
    it "normalises each accepted form to a frozen { mode } hash" do
      expect(described_class.coerce_bleeding_edge(nil)).to eq({ "mode" => "none" })
      expect(described_class.coerce_bleeding_edge(false)).to eq({ "mode" => "none" })
      expect(described_class.coerce_bleeding_edge(true)).to eq({ "mode" => "all" })
      expect(described_class.coerce_bleeding_edge(%i[a b])).to eq({ "mode" => "list", "ids" => %w[a b] })
      expect(described_class.coerce_bleeding_edge(true)).to be_frozen
    end

    it "reads the `all` / `except` hash form, with string or symbol keys" do
      expect(described_class.coerce_bleeding_edge({ all: true, except: [:x] }))
        .to eq({ "mode" => "all", "except" => %w[x] })
      expect(described_class.coerce_bleeding_edge({ "all" => true })).to eq({ "mode" => "all", "except" => [] })
      expect(described_class.coerce_bleeding_edge({ "all" => "yes" })).to eq({ "mode" => "none" })
    end

    it "freezes every feature id, so the selector stays Ractor-shareable" do
      coerced = described_class.coerce_bleeding_edge([+"a"])
      expect(Ractor.shareable?(coerced)).to be(true)
    end

    it "rejects any other shape" do
      expect(error_message { described_class.coerce_bleeding_edge("all") })
        .to eq('bleeding_edge must be true, false, a list of feature ids, or { all: true, except: [...] }, got "all"')
    end
  end

  describe "the effects keys" do
    it "reads `effects.check` as true unless the block is absent or it is an explicit false" do
      expect(described_class.coerce_effects_check?(nil)).to be(false)
      expect(described_class.coerce_effects_check?({})).to be(true)
      expect(described_class.coerce_effects_check?({ "check" => false })).to be(false)
      expect(described_class.coerce_effects_check?({ "check" => "no" })).to be(true)
    end

    it "reads `snapshot.gate` as a Symbol, defaulting to symmetric" do
      expect(described_class.coerce_effects_gate(nil)).to eq(:symmetric)
      expect(described_class.coerce_effects_gate("additions")).to eq(:additions)
      expect(error_message { described_class.coerce_effects_gate("none") })
        .to eq('effects.snapshot.gate must be one of [:symmetric, :additions], got "none"')
    end

    it "keeps `snapshot.reach` entries that are globs or well-formed preset names, once each" do
      expect(described_class.coerce_effects_reach(["lib/**/*.rb", "rails", "rails"])).to eq(%w[lib/**/*.rb rails])
      expect(described_class.coerce_effects_reach(nil)).to eq([])
      expect(error_message { described_class.coerce_effects_reach(["Not A Preset"]) })
        .to start_with("effects.snapshot.reach entry is neither a file glob nor a well-formed entry-point preset")
    end

    it "sorts and de-duplicates `tolerated` and `labels`, and rejects a malformed label" do
      expect(described_class.coerce_effects_tolerated(%w[io.net.http io.file io.file])).to eq(%w[io.file io.net.http])
      expect(described_class.coerce_effects_labels(%w[b.x a.x])).to eq(%w[a.x b.x])
      expect(error_message { described_class.coerce_effects_tolerated(["BAD LABEL"]) })
        .to eq('effects.tolerated is not a well-formed effect label: "BAD LABEL"')
      expect(error_message { described_class.coerce_effects_labels(["BAD LABEL"]) })
        .to eq('effects.labels is not a well-formed effect label: "BAD LABEL"')
    end

    it "reads `attribution` as a frozen { method key => sorted labels } map" do
      coerced = described_class.coerce_effects_attribution({ "Net::HTTP.get" => %w[io.net.http io.net] })
      expect(coerced).to eq({ "Net::HTTP.get" => %w[io.net io.net.http] })
      expect(coerced).to be_frozen
      expect(described_class.coerce_effects_attribution(nil)).to eq({}).and be_frozen
    end

    it "rejects an attribution key that is not a method key and a label that is malformed" do
      expect(error_message { described_class.coerce_effects_attribution({ "nope" => [] }) })
        .to eq("effects.attribution key is not a method key (`Owner#method` / `Owner.method`): \"nope\"")
      expect(error_message { described_class.coerce_effects_attribution({ "A#b" => ["BAD LABEL"] }) })
        .to eq('effects.attribution["A#b"] is not a well-formed effect label: "BAD LABEL"')
    end

    it "reads `envelopes` as frozen entries naming exactly one selector and an `effect:` bound" do
      coerced = described_class.coerce_effects_envelopes([{ "match" => "lib/**", "effect" => %w[io.file] },
                                                          { "namespace" => "App::*", "effect" => [] }])
      expect(coerced).to eq([{ "match" => "lib/**", "namespace" => nil, "effect" => %w[io.file] },
                             { "match" => nil, "namespace" => "App::*", "effect" => [] }])
      expect(coerced).to all(be_frozen)
    end

    it "rejects an envelope that is not a mapping, names neither or both selectors, or has no bound" do
      expect(error_message { described_class.coerce_effects_envelopes(["lib"]) })
        .to eq('effects.envelopes[0] is not a mapping: "lib"')
      expect(error_message { described_class.coerce_effects_envelopes([{ "effect" => [] }]) })
        .to start_with("effects.envelopes[0] must name exactly one of").and end_with("got neither")
      expect(error_message do
        described_class.coerce_effects_envelopes([{ "match" => "a", "namespace" => "B", "effect" => [] }])
      end)
        .to end_with("got both")
      expect(error_message { described_class.coerce_effects_envelopes([{ "match" => "a" }]) })
        .to eq("effects.envelopes[0] has no `effect:` bound (write `effect: []` for the empty envelope)")
      expect(error_message { described_class.coerce_effects_envelopes([{ "match" => " ", "effect" => [] }]) })
        .to eq("effects.envelopes[0].match is empty")
    end

    it "names the index of the failing envelope" do
      expect(error_message { described_class.coerce_effects_envelopes([{ "match" => "a", "effect" => [] }, 7]) })
        .to eq("effects.envelopes[1] is not a mapping: 7")
    end
  end

  describe ".expand_pre_eval_entries" do
    it "keeps a literal entry as written, with or without glob characters in a missing directory" do
      expect(described_class.expand_pre_eval_entries(%w[a.rb b.rb a.rb])).to eq(%w[a.rb b.rb])
      expect(described_class.expand_pre_eval_entries(["/nonexistent-rigor-dir/*.rb"])).to eq([])
    end

    it "expands a glob in sorted order and folds the results together" do
      Dir.mktmpdir do |dir|
        %w[b.rb a.rb].each { |name| File.write(File.join(dir, name), "") }
        result = described_class.expand_pre_eval_entries([File.join(dir, "*.rb"), File.join(dir, "a.rb")])
        expect(result).to eq([File.join(dir, "a.rb"), File.join(dir, "b.rb")])
        expect(result).to be_frozen
      end
    end

    it "reads the leading directories that exist literally, so a glob character in one is not a pattern" do
      Dir.mktmpdir do |dir|
        odd = File.join(dir, "ds [x]")
        Dir.mkdir(odd)
        File.write(File.join(odd, "m.rb"), "")
        expect(described_class.expand_pre_eval_entries([File.join(odd, "*.rb")])).to eq([File.join(odd, "m.rb")])
        expect(described_class.expand_pre_eval_entries([File.join(odd, "m.rb")])).to eq([File.join(odd, "m.rb")])
      end
    end
  end

  describe "the private helpers" do
    it "keep only the entries `Configuration` calls public" do
      %i[coerce_effects_envelope coerce_effect_label_list coerce_bleeding_edge_hash freeze_ids glob_pattern?
         literal_directory_prefix join_segments expand_pre_eval_entry].each do |name|
        expect(described_class).not_to respond_to(name)
      end
    end
  end
end
