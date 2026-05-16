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
  end
end
