# frozen_string_literal: true

# Issue #527 slice 0 — the extracted external-ancestor resolver.
#
# `ExpressionTyper#rbs_ancestor_answers?` asked this question as a boolean for the #633 / ADR-110
# implicit-self binding veto; the dispatch side of #527 asks the same walk for the definition it found
# and the class it asked. This file pins the resolver's own contract — the `[definition, owner_name]`
# shape, the `::Object` cut-off, the dependency-recording flag and the memo — so a later slice changing
# the dispatch consumer cannot quietly change what the veto reads.
#
# The veto's own end-to-end behaviour is pinned by `self_class_method_over_toplevel_def_spec.rb` and
# `plugin_member_over_toplevel_def_spec.rb`, which is what makes this extraction observable-free.

require "spec_helper"

RSpec.describe Rigor::Inference::ExternalAncestorResolution do
  # A real core + stdlib RBS environment: the cut-off rule is about `Exception`, `Comparable` and
  # `Object`'s own MRO positions, which a stubbed loader could only restate.
  let(:loader) do
    Rigor::Environment::RbsLoader.new(
      libraries: Rigor::Environment::DEFAULT_LIBRARIES, signature_paths: [],
      cache_store: RunnerHelpers.shared_cache_store
    )
  end
  let(:environment) { Rigor::Environment.new(rbs_loader: loader) }
  let(:scope) do
    scope_with(
      superclasses: { "MyError" => "StandardError", "SubHash" => "Hash", "Mystery" => "SomeGem::Base" },
      includes: { "Counted" => ["Comparable"] }
    )
  end

  # The project side: `class MyError < StandardError`, `class SubHash < Hash`, and a subclass of a name
  # no RBS knows. `discovered_class_sources` is what dependency recording reads, so it is populated for
  # the recording examples below.
  def scope_with(superclasses: {}, includes: {}, class_sources: {})
    index = Rigor::Scope::DiscoveryIndex::EMPTY.with(
      discovered_superclasses: superclasses,
      discovered_includes: includes,
      discovered_class_sources: class_sources
    )
    Rigor::Scope.empty(environment: environment).with_discovery(index)
  end

  before { described_class.reset_memo! }

  describe ".resolve" do
    it "reports the definition and the ancestor it was asked of for a source subclass of a core class" do
      definition, owner = described_class.resolve("MyError", :message, :instance, scope: scope)

      expect(owner).to eq("StandardError")
      expect(definition.defined_in.to_s).to eq("::Exception")
    end

    it "reports the own class as the owner when the receiver is itself RBS-known" do
      definition, owner = described_class.resolve("Hash", :has_key?, :instance, scope: scope)

      expect(owner).to eq("Hash")
      expect(definition).not_to be_nil
    end

    it "resolves through an included module the project does not declare" do
      _definition, owner = described_class.resolve("Counted", :clamp, :instance, scope: scope)

      expect(owner).to eq("Comparable")
    end

    it "declines when the chain reaches no name the RBS environment knows" do
      expect(described_class.resolve("Mystery", :anything, :instance, scope: scope)).to be_nil
    end

    it "declines a name owned by Object or Kernel, which sit at or after a top-level def's own MRO rung" do
      # `Kernel#instance_variable_get` is reachable from every object, so answering here would retract the
      # #316 / #319 top-level binding this cut-off exists to protect.
      expect(described_class.resolve("MyError", :instance_variable_get, :instance, scope: scope)).to be_nil
    end

    it "declines a name no ancestor declares" do
      expect(described_class.resolve("MyError", :no_such_method_anywhere, :instance, scope: scope)).to be_nil
    end

    it "declines the singleton side, which slice 6 owns" do
      expect(described_class.resolve("MyError", :new, :singleton, scope: scope)).to be_nil
    end

    it "declines a nil class name and a nil scope" do
      expect(described_class.resolve(nil, :message, :instance, scope: scope)).to be_nil
      expect(described_class.resolve("MyError", :message, :instance, scope: nil)).to be_nil
    end
  end

  describe "the ADR-46 dependency edge" do
    let(:recording_scope) do
      scope_with(
        superclasses: { "MyError" => "StandardError" },
        class_sources: { "MyError" => ["app/my_error.rb:1"] }
      )
    end

    it "files an ancestry edge when the caller read the ancestry to decide something" do
      record = Rigor::Analysis::DependencyRecorder.record_for("app/reader.rb") do
        described_class.resolve("MyError", :message, :instance, scope: recording_scope)
      end

      expect(record.ancestry_sources).to include("app/my_error.rb")
    end

    it "files nothing when the caller only asked whether some ancestor happens to declare the name" do
      record = Rigor::Analysis::DependencyRecorder.record_for("app/reader.rb") do
        described_class.resolve("MyError", :message, :instance, scope: recording_scope,
                                                                record_dependencies: false)
      end

      expect(record.ancestry_sources).to be_empty
    end
  end

  describe "the memo" do
    it "returns the same answer object for a repeated (class, method, kind)" do
      first = described_class.resolve("MyError", :message, :instance, scope: scope)
      second = described_class.resolve("MyError", :message, :instance, scope: scope)

      expect(second).to equal(first)
    end

    it "keeps a recording caller off the memo, so every file records its own edge" do
      sources = { "MyError" => ["app/my_error.rb:1"] }
      recording_scope = scope_with(superclasses: { "MyError" => "StandardError" }, class_sources: sources)
      described_class.resolve("MyError", :message, :instance, scope: recording_scope)

      record = Rigor::Analysis::DependencyRecorder.record_for("app/reader.rb") do
        described_class.resolve("MyError", :message, :instance, scope: recording_scope)
      end

      expect(record.ancestry_sources).to include("app/my_error.rb")
    end
  end
end
