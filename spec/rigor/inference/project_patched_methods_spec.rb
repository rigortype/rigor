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

    it "applies last-write-wins (ADR-17, as at runtime) on duplicate (class, method, kind)" do
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
      expect(result.source_path).to eq("b.rb")
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

  # Issue #1708 — Ruby raises ArgumentError (cyclic include detected) at `module B; include A; end` once A includes B,
  # but the scanner records both edges, so the walk must end.
  describe "#lookup_through_ancestors with an include cycle" do
    it "finds the module's method without recursing forever" do
      mixin = ->(owner, name) { described_class::Mixin.new(owner: owner, module_name: name, kind: :include) }
      registry = described_class.new(
        entries: [entry_klass.new(class_name: "B", method_name: :bm, kind: :instance, source_path: "b.rb",
                                  source_line: 1)],
        mixins: [mixin.call("Foo", "A"), mixin.call("A", "B"), mixin.call("B", "A")]
      )

      expect(registry.lookup_through_ancestors(class_name: "Foo", method_name: :bm, kind: :instance, rbs_loader: nil)
                     &.class_name).to eq("B")
    end

    # Ruby raises ArgumentError (cyclic prepend detected) at the second prepend, as for the include cycle above.
    it "finds the module's method through a prepend cycle without recursing forever" do
      prepend = ->(owner, name) { described_class::Mixin.new(owner: owner, module_name: name, kind: :prepend) }
      registry = described_class.new(
        entries: [entry_klass.new(class_name: "B", method_name: :bm, kind: :instance, source_path: "b.rb",
                                  source_line: 1)],
        mixins: [prepend.call("Foo", "A"), prepend.call("A", "B"), prepend.call("B", "A")]
      )

      expect(registry.lookup_through_ancestors(class_name: "Foo", method_name: :bm, kind: :instance, rbs_loader: nil)
                     &.class_name).to eq("B")
    end
  end

  # Issue #2108 — `module_function :x` on a name the module inherits records no entry; the singleton-side walk
  # resolves Ruby's public singleton copy through the owner's instance ancestors instead. Each entry's shape is
  # the bound-name copy's ({ProjectPatchedScanner::Visibility.applied}): the inherited def's return type, the
  # owner as class_name, `:singleton` kind and `:public` visibility.
  describe "#lookup_through_ancestors singleton copy (#2108)" do
    let(:entry) do
      entry_klass.new(class_name: "KHelp", method_name: :kx, kind: :instance, source_path: "k.rb",
                      source_line: 1, return_type: :int_tag)
    end
    let(:registry) do
      described_class.new(
        entries: [entry],
        mixins: [described_class::Mixin.new(owner: "Kernel", module_name: "KHelp", kind: :include)],
        overrides: { ["Kernel", :kx, :instance] => :module_function },
        singleton_copies: [["Kernel", :kx]]
      )
    end

    it "answers a singleton call with the inherited instance entry, public and re-kinded" do
      # Kernel.kx => 1 in Ruby.
      found = registry.lookup_through_ancestors(class_name: "Kernel", method_name: :kx, kind: :singleton,
                                                rbs_loader: nil)

      expect(found&.class_name).to eq("Kernel")
      expect(found&.kind).to eq(:singleton)
      expect(found&.visibility).to eq(:public)
      expect(found&.return_type).to eq(:int_tag)
      expect(registry.callable?(found, explicit: true)).to be(true)
    end

    it "keeps the instance side private for an explicit call" do
      # 1.kx raises NoMethodError (private method 'kx') in Ruby.
      found = registry.lookup_through_ancestors(class_name: "Kernel", method_name: :kx, kind: :instance,
                                                rbs_loader: nil)

      expect(found&.visibility).to eq(:module_function)
      expect(registry.callable?(found, explicit: true)).to be(false)
    end

    it "answers nothing for a singleton call on a module with no recorded copy" do
      # Without `module_function :kx` Comparable's instance methods are not the module object's.
      found = registry.lookup_through_ancestors(class_name: "Comparable", method_name: :kx, kind: :singleton,
                                                rbs_loader: nil)

      expect(found).to be_nil
    end
  end
end
