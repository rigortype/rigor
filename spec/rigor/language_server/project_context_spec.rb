# frozen_string_literal: true

require "tmpdir"
require "fileutils"

require "rigor/language_server"
require "rigor/configuration"
require "rigor/analysis/project_scan"
require "rigor/analysis/dependency_source_inference"
require "rigor/inference/synthetic_method_index"
require "rigor/analysis/buffer_binding"

RSpec.describe Rigor::LanguageServer::ProjectContext do
  let(:configuration) { Rigor::Configuration.new("paths" => []) }
  let(:context) { described_class.new(configuration: configuration) }

  describe "#environment" do
    it "lazy-builds the Environment and memoises it across calls" do
      env_a = context.environment
      env_b = context.environment

      expect(env_b).to equal(env_a)
    end
  end

  describe "#cache_store" do
    it "returns a read-only Cache::Store rooted at configuration.cache_path" do
      store = context.cache_store

      expect(store).to be_a(Rigor::Cache::Store)
      expect(store.read_only?).to be(true)
      expect(store.root).to eq(configuration.cache_path)
    end

    it "memoises across calls" do
      expect(context.cache_store).to equal(context.cache_store)
    end
  end

  describe "#project_scan" do
    it "lazy-builds the Analysis::ProjectScan and memoises it across calls" do
      scan_a = context.project_scan
      scan_b = context.project_scan

      expect(scan_a).to be_a(Rigor::Analysis::ProjectScan)
      expect(scan_b).to equal(scan_a)
    end

    it "exposes the empty pre-pass state for a project with no plugins / deps / pre_eval" do
      scan = context.project_scan

      expect(scan.plugin_registry).to be_empty
      expect(scan.dependency_source_index).to eq(Rigor::Analysis::DependencySourceInference::Index::EMPTY)
      expect(scan.synthetic_method_index).to eq(Rigor::Inference::SyntheticMethodIndex::EMPTY)
      expect(scan.plugin_prepare_diagnostics).to eq([])
      expect(scan.pre_eval_diagnostics).to eq([])
    end
  end

  # Issue #1700 — the vendored `prime` signatures are gated on a `require "prime"`; an open buffer that gains
  # or drops one rebuilds the environment, since neither `didSave` nor a `.rb` edit reaches
  # `workspace/didChangeWatchedFiles`.
  describe "#note_buffers" do
    around do |example|
      Dir.mktmpdir("rigor-lsp-features-") { |dir| Dir.chdir(dir) { example.run } }
    end

    let(:configuration) { Rigor::Configuration.new("paths" => %w[lib]) }
    let(:path) { File.expand_path("lib/a.rb") }

    before do
      FileUtils.mkdir_p("lib")
      File.write("lib/a.rb", "p 12\n")
    end

    def prime_loaded?(environment)
      !environment.singleton_for_name("Prime").nil?
    end

    it "rebuilds the environment only when a buffer changes the required-feature set" do
      expect(prime_loaded?(context.environment)).to be(false)

      expect { context.note_buffers(path => "p 13\n") }.not_to change(context, :generation)
      expect { context.note_buffers(path => "require 'prime'\np 12\n") }.to change(context, :generation).by(1)
      expect(prime_loaded?(context.environment)).to be(true)

      expect { context.note_buffers(path => "p 12\n") }.to change(context, :generation).by(1)
      expect(prime_loaded?(context.environment)).to be(false)
    end

    # Issue #2174 — a shipped feature counts only when it can open a class the project declares.
    it "keeps the environment when a buffer requires a library no project class is named for" do
      context.environment
      expect { context.note_buffers(path => "require 'json'\np 12\n") }.not_to change(context, :generation)
    end

    it "rebuilds it when the required library declares a class the project reopens" do
      File.write("lib/m.rb", "class Matrix\nend\n")
      context.environment
      expect { context.note_buffers(path => "require 'matrix'\np 12\n") }.to change(context, :generation).by(1)
    end

    it "rebuilds it when the required library declares a class only the project's signatures reopen" do
      FileUtils.mkdir_p("sig")
      File.write("sig/ripper.rbs", "class Ripper\nend\n")
      context.environment
      expect { context.note_buffers(path => "require 'ripper'\np 12\n") }.to change(context, :generation).by(1)
    end

    it "reads a buffer in place of its file on disk" do
      File.write("lib/a.rb", "require 'prime'\n")
      context.note_buffers(path => "p 12\n")

      expect(context.required_features).to be_empty
    end
  end

  describe "#invalidate!" do
    it "bumps the generation counter" do
      expect { context.invalidate! }.to change(context, :generation).by(1)
    end

    it "drops the cached Environment so the next read rebuilds" do
      env_before = context.environment
      context.invalidate!
      env_after = context.environment

      expect(env_after).not_to equal(env_before)
    end

    it "drops the cached ProjectScan so the next read rebuilds" do
      scan_before = context.project_scan
      context.invalidate!
      scan_after = context.project_scan

      expect(scan_after).not_to equal(scan_before)
    end

    it "keeps the cache_store across invalidations (content-addressed)" do
      store_before = context.cache_store
      context.invalidate!

      expect(context.cache_store).to equal(store_before)
    end
  end

  # #246 — the save round's state. The session lives as long as the context, is seeded from an on-disk
  # snapshot when a terminal `rigor check --incremental` left one, and is NEVER written back: writing shared
  # state would race the way the read-only cache_store above already declines to.
  describe "#project_diagnostics" do
    # `project_dir` is set by the around hook; a `let` cannot own it because the directory must exist for the
    # duration of the example and be removed after.
    attr_reader :project_dir

    around do |example|
      Dir.mktmpdir("rigor-lsp-context-") do |dir|
        @project_dir = dir
        File.write(File.join(dir, "widget.rb"), "class Widget\n  def name\n    1\n  end\nend\n")
        File.write(File.join(dir, "other.rb"), "class Other\n  def go\n    Widget.new.name.upcase\n  end\nend\n")
        Dir.chdir(dir) { example.run }
      end
    end

    let(:configuration) { Rigor::Configuration.new("paths" => [project_dir]) }

    it "reports the whole project, including a file the caller never named" do
      messages = context.project_diagnostics.map(&:message)

      expect(messages).to include(a_string_matching(/undefined method `upcase'/))
    end

    it "primes once and rechecks after — the second call reuses the session" do
      context.project_diagnostics
      session = context.send(:instance_variable_get, :@incremental_session)
      allow(session).to receive(:recheck).and_call_original

      context.project_diagnostics

      expect(session).to have_received(:recheck).once
      expect(context.send(:instance_variable_get, :@incremental_session)).to equal(session)
    end

    it "picks up an edit made between rounds" do
      expect(context.project_diagnostics.map(&:message)).to include(a_string_matching(/upcase/))
      File.write(File.join(project_dir, "widget.rb"), "class Widget\n  def name\n    \"w\"\n  end\nend\n")

      expect(context.project_diagnostics.map(&:message)).not_to include(a_string_matching(/upcase/))
    end

    it "never writes the incremental snapshot" do
      snapshot = Rigor::Cache::IncrementalSnapshot.new(root: configuration.cache_path)
      context.project_diagnostics
      context.project_diagnostics

      expect(File.exist?(snapshot.path)).to be(false)
    end

    it "drops the session on invalidate! — its cache outlived the environment it was computed against" do
      context.project_diagnostics
      session = context.send(:instance_variable_get, :@incremental_session)
      context.invalidate!

      expect(context.send(:instance_variable_get, :@incremental_session)).to be_nil
      context.project_diagnostics
      expect(context.send(:instance_variable_get, :@incremental_session)).not_to equal(session)
    end
  end

  # #1613 — a long-lived session must notice a change to the incremental snapshot's inputs without an explicit
  # invalidate!: the editor may send only didSave / didChange, and the server registers no file watchers.
  describe "#project_diagnostics after a fingerprint-input change" do
    let(:project_dir) { File.realpath(Dir.mktmpdir("rigor-lsp-fingerprint-")) }
    let(:config_path) { File.join(project_dir, ".rigor.yml") }
    let(:loader) { -> { Rigor::Configuration.load(config_path) } }
    let(:context) { described_class.new(configuration: loader.call, configuration_loader: loader) }

    around do |example|
      FileUtils.mkdir_p(File.join(project_dir, "sig"))
      File.write(File.join(project_dir, "sig", "foo.rbs"), "class Foo\n  def bar: (Integer) -> Integer\nend\n")
      File.write(File.join(project_dir, "a.rb"), "class Foo\n  def bar(x) = x\nend\nFoo.new.bar(\"s\")\n")
      Dir.chdir(project_dir) { example.run }
    ensure
      FileUtils.remove_entry(project_dir)
    end

    def messages(ctx = context) = ctx.project_diagnostics.map { |d| [d.path, d.message] }

    def cold
      messages(described_class.new(configuration: loader.call))
    end

    def write_config(extra = "")
      File.write(config_path, "paths:\n  - #{project_dir}\n#{extra}")
    end

    before { write_config }

    def rebaselines?
      session = context.instance_variable_get(:@incremental_session)
      yield
      context.project_diagnostics
      !context.instance_variable_get(:@incremental_session).equal?(session)
    end

    it "reports the sig mismatch, then drops it when sig/foo.rbs is edited" do
      expect(messages.map(&:last)).to include(a_string_matching(/argument type mismatch/))
      File.write(File.join(project_dir, "sig", "foo.rbs"), "class Foo\n  def bar: (String) -> String\nend\n")

      expect(messages).to eq([])
      expect(messages).to eq(cold)
    end

    it "matches a cold run after a pre_eval: file changes" do
      File.write(File.join(project_dir, "pre.rb"), "class Foo\n  def bar(x) = x\nend\n")
      write_config("pre_eval:\n  - pre.rb\n")
      messages
      File.write(File.join(project_dir, "pre.rb"), "class Foo\n  def bar(x) = x.to_s\n  def baz = 1\nend\n")

      expect(rebaselines? { nil }).to be(true)
      expect(messages).to eq(cold)
    end

    it "matches a cold run and re-baselines after the configured lockfile changes" do
      lock = File.join(project_dir, "my.lock")
      File.write(lock, "one\n")
      write_config("bundler:\n  lockfile: #{lock}\n")
      messages
      expect(rebaselines? { File.write(lock, "two\n") }).to be(true)
      expect(messages).to eq(cold)
    end

    it "matches a cold run and re-baselines after .rigor.yml changes" do
      messages
      expect(rebaselines? { write_config("disable:\n  - call.argument-type-mismatch\n") }).to be(true)
      expect(messages).to eq([])
      expect(messages).to eq(cold)
    end

    it "re-baselines when sig/foo.rbs changes" do
      messages
      sig = File.join(project_dir, "sig", "foo.rbs")

      expect(rebaselines? { File.write(sig, "class Foo\n  def bar: (String) -> String\nend\n") }).to be(true)
    end

    it "keeps the recheck path when nothing changed" do
      messages
      session = context.instance_variable_get(:@incremental_session)
      allow(session).to receive(:recheck).and_call_original

      context.project_diagnostics

      expect(session).to have_received(:recheck).once
      expect(context.instance_variable_get(:@incremental_session)).to equal(session)
    end

    it "re-baselines when the fingerprint cannot be computed" do
      messages
      session = context.instance_variable_get(:@incremental_session)
      allow(Rigor::Cache::IncrementalSnapshot).to receive(:fingerprint).and_return(nil)

      context.project_diagnostics

      expect(context.instance_variable_get(:@incremental_session)).not_to equal(session)
    end

    it "does not bump the generation when it re-baselines" do
      messages
      generation = context.generation
      File.write(File.join(project_dir, "sig", "foo.rbs"), "class Foo\n  def bar: (String) -> String\nend\n")
      context.project_diagnostics

      expect(context.generation).to eq(generation)
    end

    it "re-baselines when only the effects: block of .rigor.yml changes" do
      File.write(File.join(project_dir, "sig", "foo.rbs"), "class Foo\n  %a{pure} def bar: () -> nil\nend\n")
      File.write(File.join(project_dir, "a.rb"), "class Foo\n  def bar\n    puts 1\n  end\nend\n")
      write_config("effects: {}\n")
      messages
      session = context.instance_variable_get(:@incremental_session)
      write_config("effects:\n  snapshot:\n    reach: [rails-controllers]\n")
      rebaselined = messages

      expect(context.instance_variable_get(:@incremental_session)).not_to equal(session)
      expect(rebaselined).to eq(cold)
    end

    it "keeps rechecking when the fingerprint was already uncomputable at priming" do
      allow(Rigor::Cache::IncrementalSnapshot).to receive(:fingerprint).and_return(nil)
      messages
      session = context.instance_variable_get(:@incremental_session)

      context.project_diagnostics

      expect(context.instance_variable_get(:@incremental_session)).to equal(session)
    end

    it "re-baselines when an uncomputable fingerprint becomes computable" do
      allow(Rigor::Cache::IncrementalSnapshot).to receive(:fingerprint).and_return(nil)
      messages
      session = context.instance_variable_get(:@incremental_session)
      allow(Rigor::Cache::IncrementalSnapshot).to receive(:fingerprint).and_call_original

      context.project_diagnostics

      expect(context.instance_variable_get(:@incremental_session)).not_to equal(session)
    end

    it "keeps the old configuration and session when the loader raises" do
      messages
      session = context.instance_variable_get(:@incremental_session)
      configuration = context.configuration
      raising = described_class.new(configuration: configuration, configuration_loader: -> { raise "bad yaml" })
      raising.project_diagnostics
      raising_session = raising.instance_variable_get(:@incremental_session)
      raising.project_diagnostics

      expect(raising.configuration).to equal(configuration)
      expect(raising.instance_variable_get(:@incremental_session)).to equal(raising_session)
      expect(context.instance_variable_get(:@incremental_session)).to equal(session)
    end

    it "drops the cache store on a re-baseline so a cache path change takes effect" do
      messages
      store = context.cache_store
      write_config("cache:\n  path: #{File.join(project_dir, 'other-cache')}\n")
      context.project_diagnostics

      expect(context.cache_store).not_to equal(store)
      expect(context.cache_store.root).to eq(File.join(project_dir, "other-cache"))
    end
  end

  # Issue #2147 — the per-buffer publish's cross-file seed: the project's files walked once per generation, the
  # buffer's own file re-walked from its bytes.
  describe "#discovery_seed_for" do
    def buffer_for(path, bytes, dir)
      physical = File.join(dir, "buffer.rb")
      File.write(physical, bytes)
      Rigor::Analysis::BufferBinding.new(logical_path: path, physical_path: physical)
    end

    it "seeds the classes other files declare, and the buffer's declarations over its file on disk" do
      Dir.mktmpdir("rigor-lsp-seed-") do |dir|
        lib = File.join(dir, "lib")
        FileUtils.mkdir_p(lib)
        File.write(File.join(lib, "b.rb"), "class Base\nend\n")
        File.write(File.join(lib, "a.rb"), "class OnDisk\nend\n")
        context = described_class.new(configuration: Rigor::Configuration.new("paths" => [lib]))

        seed = context.discovery_seed_for(buffer_for(File.join(lib, "a.rb"), "class InBuffer\nend\n", dir))
        expect(seed[:discovered_classes].keys).to include("Base", "InBuffer")
        expect(seed[:discovered_classes].keys).not_to include("OnDisk")
      end
    end

    it "walks the project once per generation, however many publishes fold it" do
      Dir.mktmpdir("rigor-lsp-seed-") do |dir|
        lib = File.join(dir, "lib")
        FileUtils.mkdir_p(lib)
        File.write(File.join(lib, "a.rb"), "class A\nend\n")
        context = described_class.new(configuration: Rigor::Configuration.new("paths" => [lib]))
        binding = buffer_for(File.join(lib, "a.rb"), "class A\nend\n", dir)
        allow(Rigor::Protection::DiscoverySeed).to receive(:bundles).and_call_original

        context.prepare_discovery_seed
        2.times { context.discovery_seed_for(binding) }
        expect(Rigor::Protection::DiscoverySeed).to have_received(:bundles).once
      end
    end

    it "sees a file added on disk only after #invalidate!" do
      Dir.mktmpdir("rigor-lsp-seed-") do |dir|
        lib = File.join(dir, "lib")
        FileUtils.mkdir_p(lib)
        File.write(File.join(lib, "a.rb"), "class A\nend\n")
        context = described_class.new(configuration: Rigor::Configuration.new("paths" => [lib]))
        binding = buffer_for(File.join(lib, "a.rb"), "class A\nend\n", dir)
        context.discovery_seed_for(binding)

        File.write(File.join(lib, "c.rb"), "class Added\nend\n")
        expect(context.discovery_seed_for(binding)[:discovered_classes].keys).not_to include("Added")
        context.invalidate!
        expect(context.discovery_seed_for(binding)[:discovered_classes].keys).to include("Added")
      end
    end
  end
end
