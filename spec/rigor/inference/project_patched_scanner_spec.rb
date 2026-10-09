# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "rigor/inference/project_patched_scanner"

RSpec.describe Rigor::Inference::ProjectPatchedScanner do
  describe ".scan" do
    it "records every `def` declared inside a top-level class reopening" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "string_ext.rb")
        File.write(path, <<~RUBY)
          class String
            def to_url
              gsub(/\\W/, "-")
            end
          end
        RUBY

        outcome = described_class.scan([path])
        entry = outcome.registry.lookup(class_name: "String", method_name: :to_url, kind: :instance)
        expect(entry).not_to be_nil
        expect(entry.source_path).to eq(path)
        expect(entry.source_line).to be > 0
        expect(outcome.diagnostics).to be_empty
      end
    end

    it "records `def self.foo` as a singleton-kind entry" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "class_ext.rb")
        File.write(path, <<~RUBY)
          class Foo
            def self.bar; end
          end
        RUBY

        outcome = described_class.scan([path])
        expect(outcome.registry.lookup(class_name: "Foo", method_name: :bar, kind: :singleton)).not_to be_nil
        expect(outcome.registry.lookup(class_name: "Foo", method_name: :bar, kind: :instance)).to be_nil
      end
    end

    it "treats `class << self; def x; end; end` as singleton too" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "ext.rb")
        File.write(path, <<~RUBY)
          class Foo
            class << self
              def helper; end
            end
          end
        RUBY

        outcome = described_class.scan([path])
        expect(outcome.registry.lookup(class_name: "Foo", method_name: :helper, kind: :singleton)).not_to be_nil
      end
    end

    it "qualifies methods through nested module / class declarations" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "nested.rb")
        File.write(path, <<~RUBY)
          module App
            class String
              def project_url; end
            end
          end
        RUBY

        outcome = described_class.scan([path])
        entry = outcome.registry.lookup(class_name: "App::String", method_name: :project_url, kind: :instance)
        expect(entry).not_to be_nil
      end
    end

    it "emits a fail-soft `pre-eval.parse-error` :warning when a file has parse errors" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "broken.rb")
        File.write(path, "def broken\n") # unterminated

        outcome = described_class.scan([path])
        expect(outcome.registry.empty?).to be(true)
        expect(outcome.diagnostics.size).to eq(1)
        diag = outcome.diagnostics.first
        expect(diag[:severity]).to eq(:warning)
        expect(diag[:rule]).to eq("pre-eval.parse-error")
        expect(diag[:path]).to eq(path)
      end
    end

    it "extracts a heuristic return_type for literal-tail def bodies (slice 3a)" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "ext.rb")
        File.write(path, <<~RUBY)
          class String
            def kind_label
              "string"
            end
            def magic
              42
            end
          end
        RUBY
        outcome = described_class.scan([path])
        label = outcome.registry.lookup(class_name: "String", method_name: :kind_label, kind: :instance)
        magic = outcome.registry.lookup(class_name: "String", method_name: :magic, kind: :instance)
        expect(label.return_type).to eq(Rigor::Type::Combinator.nominal_of("String"))
        expect(magic.return_type).to eq(Rigor::Type::Combinator.constant_of(42))
      end
    end

    it "leaves return_type nil for non-literal tail expressions" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "ext.rb")
        File.write(path, "class String; def derived; some_method; end; end\n")
        outcome = described_class.scan([path])
        entry = outcome.registry.lookup(class_name: "String", method_name: :derived, kind: :instance)
        expect(entry.return_type).to be_nil
      end
    end

    describe "alias and alias_method (#1702)" do
      def scan_source(source)
        Dir.mktmpdir do |dir|
          path = File.join(dir, "ext.rb")
          File.write(path, source)
          return described_class.scan([path]).registry
        end
      end

      def lookup(registry, name, kind = :instance, class_name: "Integer")
        registry.lookup(class_name: class_name, method_name: name, kind: kind)
      end

      it "publishes each literal spelling with the aliased def's return type" do
        registry = scan_source(<<~RUBY)
          class Integer
            def magic = 42
            alias to_m magic
            alias :to_sm :magic
            alias_method :to_mm, :magic
            alias_method "to_ms", "magic"
          end
        RUBY

        %i[to_m to_sm to_mm to_ms].each do |name|
          entry = lookup(registry, name)
          expect(entry).not_to be_nil, name.to_s
          expect(entry.return_type).to eq(Rigor::Type::Combinator.constant_of(42))
          expect(entry.alias_of).to be_nil
        end
      end

      it "records the old name of a method the patch does not define, without a return type" do
        registry = scan_source("class Integer
  alias old_plus +
  alias_method :ghost, :not_a_method
end
")

        expect(lookup(registry, :old_plus)).to have_attributes(alias_of: :+, return_type: nil, source_line: 2)
        expect(lookup(registry, :ghost)).to have_attributes(alias_of: :not_a_method, return_type: nil)
      end

      it "follows an alias of an alias, and a def written after the alias" do
        registry = scan_source(<<~RUBY)
          class Integer
            alias early later
            alias chained early
            def later = "s"
          end
        RUBY

        expect(lookup(registry, :early).return_type).to eq(Rigor::Type::Combinator.nominal_of("String"))
        expect(lookup(registry, :chained).return_type).to eq(Rigor::Type::Combinator.nominal_of("String"))
      end

      it "binds both forms on the singleton inside `class << self`" do
        registry = scan_source(<<~RUBY)
          class Foo
            class << self
              def build = 1
              alias make build
              alias_method :create, :build
            end
          end
        RUBY

        expect(lookup(registry, :make, :singleton, class_name: "Foo")).not_to be_nil
        expect(lookup(registry, :create, :singleton, class_name: "Foo")).not_to be_nil
        expect(lookup(registry, :make, :instance, class_name: "Foo")).to be_nil
      end

      it "leaves a computed name, a receiver call and a top-level alias unrecorded" do
        registry = scan_source(<<~RUBY)
          alias top_level puts
          class Integer
            def magic = 1
            alias_method name_var, :magic
            self.alias_method :via_self, :magic
            alias_method :one_arg
          end
        RUBY

        expect(registry.by_key.keys.map { |key| key[1] }).to eq([:magic])
      end
    end

    it "emits `pre-eval.duplicate-declaration` :info when two pre-eval files declare the same (class, method, kind)" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        b = File.join(dir, "b.rb")
        File.write(a, "class String; def to_url; 'a'; end; end\n")
        File.write(b, "class String; def to_url; 'b'; end; end\n")
        outcome = described_class.scan([a, b])
        dup = outcome.diagnostics.select { |d| d[:rule] == "pre-eval.duplicate-declaration" }
        expect(dup.size).to eq(1)
        expect(dup.first[:severity]).to eq(:info)
        expect(dup.first[:path]).to eq(b)
        # First-write-wins is preserved by the registry.
        entry = outcome.registry.lookup(class_name: "String", method_name: :to_url, kind: :instance)
        expect(entry.source_path).to eq(a)
      end
    end

    it "preserves entries across multiple files (no inter-file interference)" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        b = File.join(dir, "b.rb")
        File.write(a, "class String; def a_thing; end; end\n")
        File.write(b, "class Hash; def b_thing; end; end\n")

        outcome = described_class.scan([a, b])
        expect(outcome.registry.lookup(class_name: "String", method_name: :a_thing, kind: :instance)).not_to be_nil
        expect(outcome.registry.lookup(class_name: "Hash", method_name: :b_thing, kind: :instance)).not_to be_nil
      end
    end

    it "walks a body-less class via the children fallback without dropping its siblings" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "ext.rb")
        File.write(path, "class Empty; end\nclass Real\n  def helper; end\nend\n")

        outcome = described_class.scan([path])
        expect(outcome.registry.lookup(class_name: "Real", method_name: :helper, kind: :instance)).not_to be_nil
      end
    end

    it "treats `class << expr` (non-self) as opaque, recording its defs under the surrounding class" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "ext.rb")
        File.write(path, "module Outer\n  class << Helper\n    def on_x; end\n  end\nend\n")

        outcome = described_class.scan([path])
        # Recorded as an ordinary instance method of Outer, not a singleton.
        expect(outcome.registry.lookup(class_name: "Outer", method_name: :on_x, kind: :instance)).not_to be_nil
      end
    end

    it "emits a parse-error diagnostic naming the unparseable file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "broken.rb")
        File.write(path, "class Foo\n  def bad(\n")

        outcome = described_class.scan([path])
        diag = outcome.diagnostics.first
        expect(diag[:rule]).to eq("pre-eval.parse-error")
        # The parse-error message is distinct from the read-failure one below — assert the specific text so a bypass to
        # the rescue (which also names the path) does not satisfy this.
        expect(diag[:message]).to include("has a parse error").and include("broken.rb")
      end
    end

    it "emits a read-failure diagnostic when a pre_eval entry cannot be read" do
      outcome = described_class.scan(["/no/such/pre_eval_entry.rb"])

      diag = outcome.diagnostics.first
      expect(diag[:rule]).to eq("pre-eval.parse-error")
      expect(diag[:message]).to include("failed to read")
    end

    it "reads a buffer binding's physical bytes when it resolves the entry elsewhere" do
      Dir.mktmpdir do |dir|
        logical = File.join(dir, "ext.rb")
        physical = File.join(dir, "ext.buffer.rb")
        File.write(logical, "class String; def on_disk; end; end\n")
        File.write(physical, "class String; def in_buffer; end; end\n")
        buffer = Object.new
        buffer.define_singleton_method(:resolve) { |p| p == logical ? physical : p }

        outcome = described_class.scan([logical], buffer: buffer)
        # The buffer's bytes win, recorded under the logical path.
        expect(outcome.registry.lookup(class_name: "String", method_name: :in_buffer, kind: :instance)).not_to be_nil
        expect(outcome.registry.lookup(class_name: "String", method_name: :on_disk, kind: :instance)).to be_nil
      end
    end
  end
end
