# frozen_string_literal: true

require "spec_helper"
require "rigor/inference/project_patched_methods"

RSpec.describe Rigor::Inference::ProjectPatchedMethods do
  let(:entry_klass) { described_class::Entry }

  describe "#lookup" do
    it "returns the recorded Entry for a matching (class, method, kind) triple" do
      entries = [
        entry_klass.new(
          class_name: "String", method_name: :to_url, kind: :instance,
          source_path: "lib/ext.rb", source_line: 3
        )
      ]
      registry = described_class.new(entries: entries)
      result = registry.lookup(class_name: "String", method_name: :to_url, kind: :instance)
      expect(result.class_name).to eq("String")
      expect(result.method_name).to eq(:to_url)
      expect(result.source_path).to eq("lib/ext.rb")
    end

    it "returns nil when no entry matches" do
      registry = described_class.new(entries: [])
      expect(registry.lookup(class_name: "String", method_name: :missing, kind: :instance)).to be_nil
    end

    it "applies first-write-wins on duplicate (class, method, kind)" do
      first = entry_klass.new(
        class_name: "Hash", method_name: :deep_merge, kind: :instance,
        source_path: "a.rb", source_line: 1
      )
      second = entry_klass.new(
        class_name: "Hash", method_name: :deep_merge, kind: :instance,
        source_path: "b.rb", source_line: 2
      )
      registry = described_class.new(entries: [first, second])
      result = registry.lookup(class_name: "Hash", method_name: :deep_merge, kind: :instance)
      expect(result.source_path).to eq("a.rb")
    end

    it "distinguishes instance from singleton kind under the same (class, method)" do
      entries = [
        entry_klass.new(class_name: "Foo", method_name: :bar, kind: :instance,
                        source_path: "f.rb", source_line: 1),
        entry_klass.new(class_name: "Foo", method_name: :bar, kind: :singleton,
                        source_path: "f.rb", source_line: 5)
      ]
      registry = described_class.new(entries: entries)
      expect(registry.lookup(class_name: "Foo", method_name: :bar, kind: :instance).source_line).to eq(1)
      expect(registry.lookup(class_name: "Foo", method_name: :bar, kind: :singleton).source_line).to eq(5)
    end
  end

  describe "#empty?" do
    it "is true when no entries were supplied" do
      expect(described_class.new(entries: []).empty?).to be(true)
    end

    it "is false once any entry was supplied" do
      registry = described_class.new(
        entries: [entry_klass.new(class_name: "X", method_name: :y, kind: :instance,
                                  source_path: "z.rb", source_line: 1)]
      )
      expect(registry.empty?).to be(false)
    end

    it "EMPTY constant is empty" do
      expect(described_class::EMPTY.empty?).to be(true)
    end
  end
end
