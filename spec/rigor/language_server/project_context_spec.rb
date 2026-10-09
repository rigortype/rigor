# frozen_string_literal: true

require "tmpdir"
require "fileutils"

require "rigor/language_server"
require "rigor/configuration"
require "rigor/analysis/project_scan"
require "rigor/analysis/dependency_source_inference"
require "rigor/inference/synthetic_method_index"

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
end
