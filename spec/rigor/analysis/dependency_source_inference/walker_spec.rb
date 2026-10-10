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
          ["Fake", :shout] => Rigor::Analysis::DependencySourceInference::Walker::CatalogEntry.new(
            kind: :instance, return_type: Rigor::Type::Combinator.nominal_of("String")
          ),
          ["Fake", :greet] => Rigor::Analysis::DependencySourceInference::Walker::CatalogEntry.new(
            kind: :singleton, return_type: Rigor::Type::Combinator.nominal_of("String")
          )
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

        entry = Rigor::Analysis::DependencySourceInference::Walker::CatalogEntry.new(kind: :instance)
        expect(catalog).to eq(["Fake::Inner", :deep] => entry)
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

        expect(catalog).to eq(
          ["Fake", :from_meta] => Rigor::Analysis::DependencySourceInference::Walker::CatalogEntry.new(kind: :singleton)
        )
      end
    end

    it "descends a body-less class via the children fallback without aborting the file" do
      # `class Empty; end` has a nil body, so descend_class_or_module takes the walk_children branch; the sibling class
      # in the same file must still be harvested (the fallback must not crash).
      with_fake_gem do |gem_dir|
        File.write(File.join(gem_dir, "lib", "fake.rb"), <<~RUBY)
          class Empty; end
          class Real
            def m; end
          end
        RUBY

        catalog = walker.walk(gem_dir: gem_dir, roots: %w[lib]).catalog

        expect(catalog).to eq(
          ["Real", :m] => Rigor::Analysis::DependencySourceInference::Walker::CatalogEntry.new(kind: :instance)
        )
      end
    end

    it "treats `class << expr` (non-self) as opaque, recording its defs under the surrounding class" do
      # The singleton receiver is a constant, not `self`, so descend_singleton_class takes the walk_children fallback:
      # the inner def is recorded as an ordinary instance method of Outer, NOT a per-instance singleton.
      with_fake_gem do |gem_dir|
        File.write(File.join(gem_dir, "lib", "fake.rb"), <<~RUBY)
          module Outer
            class << Helper
              def on_x; end
            end
          end
        RUBY

        catalog = walker.walk(gem_dir: gem_dir, roots: %w[lib]).catalog

        expect(catalog).to eq(
          ["Outer", :on_x] => Rigor::Analysis::DependencySourceInference::Walker::CatalogEntry.new(kind: :instance)
        )
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

        expect(catalog).to include(
          ["Fake::Sub", :call] => Rigor::Analysis::DependencySourceInference::Walker::CatalogEntry.new(kind: :instance)
        )
      end
    end

    it "skips files that fail to parse without raising" do
      with_fake_gem do |gem_dir|
        File.write(File.join(gem_dir, "lib", "good.rb"), "class Good; def ok; end; end\n")
        File.write(File.join(gem_dir, "lib", "broken.rb"), "def broken\n") # unterminated def

        catalog = walker.walk(gem_dir: gem_dir, roots: %w[lib]).catalog

        expect(catalog).to include(
          ["Good", :ok] => Rigor::Analysis::DependencySourceInference::Walker::CatalogEntry.new(kind: :instance)
        )
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

    # Issue #1672 — a refine body defines refinements of its target, not methods of the refining module.
    describe "`refine` bodies" do
      def walk_source(source)
        with_fake_gem do |gem_dir|
          File.write(File.join(gem_dir, "lib", "fake.rb"), source)
          return walker.walk(gem_dir: gem_dir, roots: %w[lib])
        end
      end

      it "records a refine-body def as a refinement of the target and keeps it out of the catalog" do
        outcome = walk_source(<<~RUBY)
          module Shouty
            refine String do
              def shout = upcase + "!"
              def self.ignored = nil
            end

            def whisper = "psst"
          end
        RUBY

        expect(outcome.catalog.keys).to eq([["Shouty", :whisper]])
        expect(outcome.refinements).to eq(
          "Shouty::String" => { shout: ["Shouty"] }, "String" => { shout: ["Shouty"] }
        )
        expect(outcome.refinements).to be_frozen
      end

      it "accepts a `self` receiver and a qualified target, and unions every refining module" do
        outcome = walk_source(<<~RUBY)
          module A
            self.refine(::Kernel) { def a = 1 }
          end
          module B
            refine ::Kernel do
              def a = 2
            end
          end
        RUBY

        expect(outcome.catalog).to eq({})
        expect(outcome.refinements).to include("Kernel" => { a: %w[A B] })
      end

      it "still walks a declaration nested in a refine body under the lexical prefix" do
        outcome = walk_source(<<~RUBY)
          module Shouty
            refine ::String do
              class Helper
                def help = nil
              end
            end
          end
        RUBY

        expect(outcome.catalog.keys).to eq([["Shouty::Helper", :help]])
        expect(outcome.refinements).to eq({})
      end

      # Issue #1689 — `Class` undefines `refine`, so in a class body it is the class's own method.
      it "walks a `refine` call in a class body generically" do
        outcome = walk_source(<<~RUBY)
          class Widget < Base
            refine String do
              def label = "widget"
            end
          end
        RUBY

        expect(outcome.catalog.keys).to eq([["Widget", :label]])
        expect(outcome.refinements).to eq({})
      end

      it "walks a computed `refine` target generically, as before" do
        outcome = walk_source(<<~RUBY)
          module Shouty
            refine(target_class) { def shout = nil }
          end
        RUBY

        expect(outcome.catalog.keys).to eq([["Shouty", :shout]])
        expect(outcome.refinements).to eq({})
      end

      it "records nothing for a `refine` with no enclosing module" do
        outcome = walk_source("refine(::String) { def shout = nil }\n")

        expect(outcome.catalog).to eq({})
        expect(outcome.refinements).to eq({})
      end
    end
  end
end
