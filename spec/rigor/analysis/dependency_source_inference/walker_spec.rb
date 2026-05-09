# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require "rigor/analysis/dependency_source_inference"

RSpec.describe Rigor::Analysis::DependencySourceInference::Walker do
  let(:walker) { described_class }

  def with_fake_gem(&)
    Dir.mktmpdir("fake-gem-") do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      yield dir
    end
  end

  describe ".walk" do
    it "returns an empty hash for a gem with no .rb files under any root" do
      with_fake_gem do |gem_dir|
        catalog = walker.walk(gem_dir: gem_dir, roots: %w[lib]).catalog
        expect(catalog).to be_frozen
        expect(catalog).to eq({})
      end
    end

    it "harvests `def` methods under qualified class names" do
      with_fake_gem do |gem_dir|
        File.write(File.join(gem_dir, "lib", "fake.rb"), <<~RUBY)
          class Fake
            def shout; "HI"; end
            def self.greet; "hi"; end
          end
        RUBY

        catalog = walker.walk(gem_dir: gem_dir, roots: %w[lib]).catalog

        expect(catalog).to eq(
          ["Fake", :shout] => :instance,
          ["Fake", :greet] => :singleton
        )
      end
    end

    it "qualifies methods through nested class / module declarations" do
      with_fake_gem do |gem_dir|
        File.write(File.join(gem_dir, "lib", "fake.rb"), <<~RUBY)
          module Fake
            class Inner
              def deep; end
            end
          end
        RUBY

        catalog = walker.walk(gem_dir: gem_dir, roots: %w[lib]).catalog

        expect(catalog).to eq(["Fake::Inner", :deep] => :instance)
      end
    end

    it "treats `class << self` bodies as singleton-method definitions" do
      with_fake_gem do |gem_dir|
        File.write(File.join(gem_dir, "lib", "fake.rb"), <<~RUBY)
          class Fake
            class << self
              def from_meta; end
            end
          end
        RUBY

        catalog = walker.walk(gem_dir: gem_dir, roots: %w[lib]).catalog

        expect(catalog).to eq(["Fake", :from_meta] => :singleton)
      end
    end

    it "walks every .rb file under nested subdirectories" do
      with_fake_gem do |gem_dir|
        FileUtils.mkdir_p(File.join(gem_dir, "lib", "fake", "sub"))
        File.write(File.join(gem_dir, "lib", "fake.rb"), <<~RUBY)
          module Fake
          end
        RUBY
        File.write(File.join(gem_dir, "lib", "fake", "sub", "thing.rb"), <<~RUBY)
          module Fake
            class Sub
              def call; end
            end
          end
        RUBY

        catalog = walker.walk(gem_dir: gem_dir, roots: %w[lib]).catalog

        expect(catalog).to include(["Fake::Sub", :call] => :instance)
      end
    end

    it "skips files that fail to parse without raising" do
      with_fake_gem do |gem_dir|
        File.write(File.join(gem_dir, "lib", "good.rb"), "class Good; def ok; end; end\n")
        File.write(File.join(gem_dir, "lib", "broken.rb"), "def broken\n") # unterminated def

        catalog = walker.walk(gem_dir: gem_dir, roots: %w[lib]).catalog

        expect(catalog).to include(["Good", :ok] => :instance)
        # The broken file produces no entries — its contents are silently dropped.
        expect(catalog.keys.flat_map(&:first)).not_to include("broken")
      end
    end

    it "honours hard exclusions: refuses to walk a `spec/` root even when listed" do
      with_fake_gem do |gem_dir|
        FileUtils.mkdir_p(File.join(gem_dir, "spec"))
        File.write(File.join(gem_dir, "spec", "harness.rb"), <<~RUBY)
          class HarnessSpec
            def run; end
          end
        RUBY
        File.write(File.join(gem_dir, "lib", "library.rb"), <<~RUBY)
          class Library
            def call; end
          end
        RUBY

        catalog = walker.walk(gem_dir: gem_dir, roots: %w[spec lib]).catalog

        expect(catalog.keys.map(&:first)).to contain_exactly("Library")
      end
    end

    it "honours hard exclusions: refuses to walk `test/` and `bin/` regardless of casing" do
      excluded = described_class::HARD_EXCLUDED_ROOTS

      expect(excluded).to contain_exactly("spec", "test", "bin")
      expect(walker.accepted_roots(%w[Spec TEST Bin lib ext])).to eq(%w[lib ext])
    end

    describe "budget: cap (slice 4)" do
      it "caps the catalog at `budget` entries and reports truncated?" do
        with_fake_gem do |gem_dir|
          File.write(File.join(gem_dir, "lib", "fake.rb"), <<~RUBY)
            class Fake
              def a; end
              def b; end
              def c; end
              def d; end
              def e; end
            end
          RUBY

          outcome = walker.walk(gem_dir: gem_dir, roots: %w[lib], budget: 3)

          expect(outcome.catalog.size).to eq(3)
          expect(outcome.truncated?).to be(true)
        end
      end

      it "reports truncated? false when the catalog fits within budget" do
        with_fake_gem do |gem_dir|
          File.write(File.join(gem_dir, "lib", "fake.rb"), "class Fake; def only; end; end\n")

          outcome = walker.walk(gem_dir: gem_dir, roots: %w[lib], budget: 100)

          expect(outcome.catalog.size).to eq(1)
          expect(outcome.truncated?).to be(false)
        end
      end

      it "defaults to UNBOUNDED when budget: is omitted" do
        with_fake_gem do |gem_dir|
          File.write(File.join(gem_dir, "lib", "fake.rb"), "class Fake; def only; end; end\n")

          outcome = walker.walk(gem_dir: gem_dir, roots: %w[lib])

          expect(outcome.truncated?).to be(false)
        end
      end
    end
  end
end
