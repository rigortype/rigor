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

      # ADR-121 WD7 — the block still walks generically, as before; its names now also go under the wildcard class,
      # as the project walk records them, because the class it refines cannot be named.
      it "walks a computed `refine` target generically, and records its names under the wildcard class" do
        outcome = walk_source(<<~RUBY)
          module Shouty
            refine(target_class) { def shout = nil }
          end
        RUBY

        expect(outcome.catalog.keys).to eq([["Shouty", :shout]])
        wildcard = Rigor::Scope::DiscoveryIndex::REFINEMENT_WILDCARD
        expect(outcome.refinements).to eq({ wildcard => { shout: ["Shouty"] } })
      end

      it "records a names-wildcard row for a gem refine body it cannot fully read, as the project walk does" do
        outcome = walk_source(<<~RUBY)
          module Shouty
            refine String do
              def shout = nil
              alias_method :yell, :shout
              import_methods Helpers
            end
          end
        RUBY

        wildcard = Rigor::Scope::DiscoveryIndex::REFINEMENT_WILDCARD
        rows = { shout: ["Shouty"], yell: ["Shouty"], wildcard => ["Shouty"] }
        expect(outcome.refinements).to eq({ "Shouty::String" => rows, "String" => rows })
      end

      # Round-2 review of #1828 — a constant a gem file writes without declaring a class or module by it is recorded as
      # bound (`Outcome#bound`, by last segment) and the rows stay as the project walk records them: the reader decides,
      # per segment of the key, at read time ({Rigor::Inference::InEffectRefinements.class_wildcard_key?}), once for the
      # project's own writes and every walked gem's.
      describe "a constant a gem file writes" do
        def outcome_of(files)
          with_fake_gem do |gem_dir|
            files.each { |name, source| File.write(File.join(gem_dir, "lib", name), source) }
            return walker.walk(gem_dir: gem_dir, roots: %w[lib])
          end
        end

        it "is bound by every form of write, and a const_set with a literal name, in this file or another" do
          forms = ["K = String", "K ||= String", "K &&= String", "K += 1", "Wrap::K = String", "K, L = String, Symbol",
                   "Wrap::K, L = String, Symbol", "Object.const_set(:K, String)", "const_set('K', String)"]
          bound = forms.map { |form| outcome_of("a.rb" => "module M\n  #{form}\nend\n").bound }
          elsewhere = outcome_of("a.rb" => "module M\n  refine(K) { def shout = 1 }\nend\n", "b.rb" => "K = String\n")

          expect(bound.map(&:to_a)).to all(include("K"))
          expect(elsewhere.bound).to eq(Set["K"])
        end

        it "leaves the rows as the project walk records them" do
          outcome = outcome_of("a.rb" => "module M\n  K = String\n  refine(K) { def shout = 1 }\nend\n")

          expect(outcome.refinements).to eq({ "M::K" => { shout: ["M"] }, "K" => { shout: ["M"] } })
        end

        # The controls: a class or module the gem declares is no bound name, nor is a name nothing writes.
        it "is not bound when the gem declares a class or module by the write, or writes another name" do
          declared = ["K = Class.new", "K = Struct.new(:a)", "K = Data.define(:a)", "K = Module.new", "class K; end"]
          bound = declared.map { |form| outcome_of("a.rb" => "module M\n  #{form}\nend\n").bound }
          other = outcome_of("a.rb" => "module M\n  L = String\n  refine(String) { def shout = 1 }\nend\n")

          expect(bound).to all(eq(Set.new))
          expect(other.bound).to eq(Set["L"])
        end
      end

      # Ruby 4.0.5 raises `NoMethodError` for a top-level `refine`, so no `using` can ever activate it. The census
      # the project walk runs records it under the module name `""` (ADR-121 WD7), which no `using` names; the gem
      # walk reads the file through the same census (#1814), so the row is the same one.
      it "records a `refine` with no enclosing module under a module no `using` can name" do
        outcome = walk_source("refine(::String) { def shout = nil }\n")

        expect(outcome.catalog).to eq({})
        expect(outcome.refinements).to eq({ "String" => { shout: [""] } })
        expect(outcome.modules).to eq(Set.new)
      end
    end

    # Issue #1814 — what the walk read, for "has every file that could refine this module been read?".
    describe "coverage" do
      def walk_files(files, budget = described_class::UNBOUNDED)
        with_fake_gem do |gem_dir|
          files.each do |relative, source|
            FileUtils.mkdir_p(File.dirname(File.join(gem_dir, relative)))
            File.write(File.join(gem_dir, relative), source)
          end
          return walker.walk(gem_dir: gem_dir, roots: %w[lib], budget: budget)
        end
      end

      it "reads a gem in full, and names the classes and modules its files declare" do
        outcome = walk_files(
          "lib/a.rb" => "module Shouty\n  refine(String) { def shout = 1 }\n  class Helper; end\nend\n",
          "lib/b.rb" => "module Other\n  def self.x = 1\nend\n"
        )

        expect(outcome.fully_read?).to be(true)
        expect(outcome.unread).to eq([])
        expect(outcome.truncated?).to be(false)
        expect(outcome.mixes_modules).to be(false)
        expect(outcome.modules).to eq(Set["Shouty", "Shouty::Helper", "Other"])
      end

      it "names a module only a refinement row names, and a module a Module.new write declares" do
        outcome = walk_files(
          "lib/a.rb" => "Ext = Module.new do\n  refine(String) { def shout = 1 }\nend\n",
          "lib/b.rb" => "module L\n  M.module_eval { refine(String) { def other = 1 } }\nend\n"
        )

        expect(outcome.modules).to include("Ext", "L", "L::M", "M")
      end

      # A file that does not parse may have declared or refined anything. The signal is the gem-relative path in
      # `unread`; the existing example above keeps the walk's other facts for the files that did parse.
      it "records a file that fails to parse as unread, and the gem as not fully read" do
        outcome = walk_files(
          "lib/good.rb" => "module Good\n  refine(String) { def ok = 1 }\nend\n",
          "lib/deep/broken.rb" => "def broken\n"
        )

        expect(outcome.unread).to eq(["lib/deep/broken.rb"])
        expect(outcome.fully_read?).to be(false)
        expect(outcome.refinements).to eq({ "Good::String" => { ok: ["Good"] }, "String" => { ok: ["Good"] } })
      end

      it "records a file it cannot read as unread" do
        with_fake_gem do |gem_dir|
          File.write(File.join(gem_dir, "lib", "good.rb"), "module Good; end\n")
          File.symlink("/nonexistent/target.rb", File.join(gem_dir, "lib", "dangling.rb"))

          outcome = walker.walk(gem_dir: gem_dir, roots: %w[lib])

          expect(outcome.unread).to eq(["lib/dangling.rb"])
          expect(outcome.fully_read?).to be(false)
        end
      end

      # Round-1 review of #1828 — `require_relative "../shim/olg_more"` loads a file no walked root holds (Ruby 4.0.5
      # prints 2 for `"x".bb` after `using Olg`, the second `refine` living in the shim).
      describe "a require_relative with a literal path" do
        def walk_gem(files)
          with_fake_gem do |gem_dir|
            files.each do |relative, source|
              FileUtils.mkdir_p(File.dirname(File.join(gem_dir, relative)))
              File.write(File.join(gem_dir, relative), source)
            end
            return walker.walk(gem_dir: gem_dir, roots: %w[lib])
          end
        end

        it "records a file outside every walked root as unread" do
          outcome = walk_gem("lib/olg.rb" => "module Olg; end\nrequire_relative '../shim/olg_more'\n",
                             "shim/olg_more.rb" => "module Olg; end\n")

          expect(outcome.unread).to eq(["shim/olg_more.rb"])
          expect(outcome.fully_read?).to be(false)
        end

        it "records a path spelled with its extension" do
          outcome = walk_gem("lib/a.rb" => "require_relative '../shim/b.rb'\n",
                             "shim/b.rb" => "module B; end\n")

          expect(outcome.unread).to eq(["shim/b.rb"])
        end

        # The controls: a file under a walked root, a file that does not exist, a `load`, and a computed path.
        it "reads a file under a walked root, a missing file, a load and a computed path as read in full" do
          outcome = walk_gem("lib/a.rb" => "require_relative 'a/b'\nrequire_relative 'missing'\nload '../shim/c.rb'\n" \
                                           "require_relative File.join('..', 'shim', 'c')\n",
                             "lib/a/b.rb" => "module B; end\n", "shim/c.rb" => "module C; end\n")

          expect(outcome.unread).to eq([])
          expect(outcome.fully_read?).to be(true)
        end
      end

      # Ruby 4.0.5: `Dir.glob("lib/**/*.rb")` lists neither `lib/.vendor/x.rb` nor `lib/compat/y.rb` for a symlink
      # `lib/compat -> ../shim`, though `require` loads both. Their files may declare or refine a module.
      it "records a dot directory's files and a symlinked directory as unread" do
        with_fake_gem do |gem_dir|
          File.write(File.join(gem_dir, "lib", "good.rb"), "module Good; end\n")
          FileUtils.mkdir_p([File.join(gem_dir, "lib", ".vendor"), File.join(gem_dir, "shim")])
          File.write(File.join(gem_dir, "lib", ".vendor", "x.rb"), "module Hidden; end\n")
          File.write(File.join(gem_dir, "shim", "y.rb"), "module Linked; end\n")
          File.symlink("../shim", File.join(gem_dir, "lib", "compat"))

          outcome = walker.walk(gem_dir: gem_dir, roots: %w[lib])

          expect(outcome.unread).to contain_exactly("lib/.vendor/x.rb", "lib/compat")
          expect(outcome.fully_read?).to be(false)
          expect(outcome.modules).to eq(Set["Good"])
        end
      end

      it "records the census raising on a file as unread" do
        allow(Rigor::Inference::ScopeIndexer).to receive(:refinement_table).and_raise(StandardError, "boom")

        outcome = walk_files("lib/a.rb" => "module A\n  refine(String) { def x = 1 }\nend\n")

        expect(outcome.unread).to eq(["lib/a.rb"])
        expect(outcome.fully_read?).to be(false)
      end

      it "is not fully read once the budget truncated the walk" do
        outcome = walk_files({ "lib/a.rb" => "module A\n  def a; end\n  def b; end\n  def c; end\nend\n" }, 2)

        expect(outcome.truncated?).to be(true)
        expect(outcome.fully_read?).to be(false)
        expect(walk_files({ "lib/a.rb" => "module A\n  def a; end\nend\n" }, 2).fully_read?).to be(true)
      end

      # Ruby 4.0.5: `module Inc; refine(String) { def foo = :inc }; end; module M; include Inc; end; using M;
      # "x".foo` prints `:inc`, so `using M` puts in effect the refinements of what `M` includes or prepends.
      {
        "an include in a module body" => "module M\n  include Inc\nend\n",
        "a prepend in a module body" => "module M\n  prepend Inc\nend\n",
        "an include through self" => "module M\n  self.include Inc\nend\n",
        "an include in a method of a module" => "module M\n  def self.setup = include(Inc)\nend\n",
        "an include on a constant" => "M.include(Inc)\n",
        "a prepend on a constant" => "M.prepend(Inc)\n",
        "an include on an argument" => "class Hooks\n  def self.included(base) = base.include(Inc)\nend\n",
        "an include in a block under a class" => "class C\n  K = Module.new { include Inc }\nend\n",
        "an include at the top level" => "include Inc\n",
        "a send of :include" => "M.send(:include, Inc)\n",
        "a method(:prepend) read" => "m = M.method(:prepend)\n",
        "an eval string with an include" => "M.module_eval(\"include Inc\")\n",
        "an eval heredoc with a prepend" => "M.module_eval(<<~RUBY)\n  prepend Inc\nRUBY\n",
        # Round-1 review of #1828 — a method defined under `class << self` runs with the `self` of the enclosing body.
        # Ruby 4.0.5 prints `:inc` for `module Scg; class << self; def enable! = include(ScgInc); end; enable!; end`.
        "an include in a method defined under class << self of a module" =>
          "module M\n  class << self\n    def enable! = include(Inc)\n  end\nend\n",
        "an include in a method defined under class << expr" =>
          "module M\n  class << obj\n    def enable! = include(Inc)\n  end\nend\n",
        "an include in a method defined under class << expr inside a class" =>
          "class C\n  class << obj\n    def enable! = include(Inc)\n  end\nend\n",
        "an include in a method of a module under class << self inside a block" =>
          "Module.new do\n  class << self\n    def enable! = include(Inc)\n  end\nend\n",
        # Ruby 4.0.5 prints `:inc` for `module AfgInc; def self.mix_into(mod) = append_features(mod); end; module Afg;
        # AfgInc.mix_into(self); end`.
        "an implicit append_features in a method of a module" =>
          "module M\n  def self.mix_into(mod) = append_features(mod)\nend\n",
        "an implicit prepend_features in a module body" => "module M\n  prepend_features(Inc)\nend\n"
      }.each do |name, source|
        it "marks #{name} as a mixin site" do
          expect(walk_files("lib/m.rb" => source).mixes_modules).to be(true)
        end
      end

      # The control for each of the above: the shapes that must stay clean.
      {
        "an include in a class body" => "class C\n  include Comparable\nend\n",
        "an include in a class's method" => "class C\n  def self.use(mod) = include(mod)\nend\n",
        "an include in class << self" => "module M\n  class << self\n    include Inc\n  end\nend\n",
        "an extend self" => "module M\n  extend self\nend\n",
        "an include in a method defined under class << self of a class" =>
          "class C\n  class << self\n    def use(mod) = include(mod)\n  end\nend\n",
        "an append_features in a class's method" => "class C\n  def self.use(mod) = append_features(mod)\nend\n",
        "include? on a list" => "module M\n  def x(list) = list.include?(1)\nend\n",
        "a name that merely contains the word" => "module M\n  def includes = 1\nend\n",
        "an unrelated send" => "M.send(:name)\n"
      }.each do |name, source|
        it "does not mark #{name} as a mixin site" do
          expect(walk_files("lib/m.rb" => source).mixes_modules).to be(false)
        end
      end

      # Round-1 review of #1828 — a gem that mixes into a module it does not declare names that module, so the module
      # is not read in full whichever gem declared it. Ruby 4.0.5 prints `["X", :inc]` for `"x".shout, "x".foo` after
      # `using Shouty` with `Shouty.include(GembInc)` in a second gem.
      {
        "an include on a constant" => ["Shouty.include(GembInc)\n", %w[Shouty]],
        "a prepend on a constant path" => ["Gem::Shouty.prepend(GembInc)\n", %w[Gem::Shouty]],
        "an include under a module, by every spelling" => ["module Outer\n  Shouty.include(GembInc)\nend\n",
                                                           %w[Outer Outer::Shouty Shouty]],
        "a send of :include" => ["Shouty.send(:include, GembInc)\n", %w[Shouty]],
        "a public_send of :prepend" => ["Shouty.public_send(:prepend, GembInc)\n", %w[Shouty]],
        "an eval string" => ["Shouty.module_eval(\"include GembInc\")\n", %w[Shouty]],
        "an include in an eval block" => ["Shouty.module_eval { include GembInc }\n", %w[Shouty]],
        "an include in a block inside an eval block" => ["Shouty.class_eval { [1].each { include GembInc } }\n",
                                                         %w[Shouty]],
        "an append_features argument" => ["GembInc.append_features(Shouty)\n", %w[Shouty]],
        "a prepend_features argument under a module" => ["module Outer\n  Inc.prepend_features(Shouty)\nend\n",
                                                         %w[Outer Outer::Shouty Shouty]]
      }.each do |name, (source, named)|
        it "names the module #{name} mixes into" do
          outcome = walk_files("lib/m.rb" => source)

          expect(outcome.mixes_modules).to be(true)
          expect(outcome.modules.to_a).to match_array(named)
        end
      end

      # The controls: a receiver that is no constant names nothing, and a call that is not a mixin names no module.
      it "names no module for an include on a variable, and none for a call that is not a mixin" do
        mixed = walk_files("lib/m.rb" => "def self.included(base) = base.include(GembInc)\n")
        other = walk_files("lib/m.rb" => "Shouty.include?(GembInc)\nShouty.module_eval { def x = 1 }\n")

        expect(mixed.mixes_modules).to be(true)
        expect(mixed.modules).to eq(Set.new)
        expect(other.mixes_modules).to be(false)
        expect(other.modules).to eq(Set.new)
      end

      # Round-2 review of #1828 — a module context hands the module being defined to a constant it cannot account for.
      # Ruby 4.0.5 prints `:ok` for `"x".foo` after `using Dslg` with `module Refiner; def refines_string(name) =
      # refine(String) { define_method(name) { :ok } }; end` and `module Dslg; extend Refiner; refines_string :foo;
      # end`,
      # and the same for `class << self; include Refiner; end`, `Refiner.send(:extend_object, self)`, and a foreign
      # `Plugin.install(self)` that includes into its argument. The walker lists each such constant (every candidate
      # spelling) unless one of its own files declares it; the reader accounts for the rest against core, stdlib and
      # the other walked gems (`Index#fully_read_module?`).
      {
        "an extend of a constant the gem does not declare" =>
          ["module Dslg\n  extend Refiner\nend\n", [%w[Dslg::Refiner Refiner]]],
        "an extend of a constant path" =>
          ["module Dslg\n  extend Gem::Refiner\nend\n", [%w[Dslg::Gem::Refiner Gem::Refiner]]],
        "an extend of one declared and one undeclared module" =>
          ["module Helper; end\nmodule Dslg\n  extend Helper, Refiner\nend\n", [%w[Dslg::Refiner Refiner]]],
        "an explicit extend on a constant" => ["Dslg.extend(Refiner)\n", [%w[Refiner]]],
        "an extend in a Module.new block" => ["Module.new do\n  extend Refiner\nend\n", [%w[Refiner]]],
        "an extend in a method of a module" =>
          ["module Dslg\n  def self.setup = extend(Refiner)\nend\n", [%w[Dslg::Refiner Refiner]]],
        "an include in the body of class << self of a module" =>
          ["module Scr\n  class << self\n    include Refiner\n  end\nend\n", [%w[Scr::Refiner Refiner]]],
        "a prepend in the body of class << self of a module" =>
          ["module Scr\n  class << self\n    prepend Refiner\n  end\nend\n", [%w[Scr::Refiner Refiner]]],
        "a call on a constant that passes self" =>
          ["module Shouty\n  Plugin.install(self)\nend\n", [%w[Shouty::Plugin Plugin]]],
        "a call on a constant that passes self as a keyword" =>
          ["module Shouty\n  Plugin.install(into: self)\nend\n", [%w[Shouty::Plugin Plugin]]],
        "a call on a constant path chain that passes self" =>
          ["module Shouty\n  Plugin::Installer.new.install(self)\nend\n",
           [%w[Shouty::Plugin::Installer Plugin::Installer]]],
        "a call on a constant that takes a block" =>
          ["module Shouty\n  Registry.configure { |c| c.name = 1 }\nend\n", [%w[Shouty::Registry Registry]]],
        "a send on a constant" =>
          ["module Eog\n  Refiner.send(:extend_object, self)\nend\n", [%w[Eog::Refiner Refiner]]],
        "a send on a constant that hands over nothing else" =>
          ["module Eog\n  Refiner.send(:install, 1)\nend\n", [%w[Eog::Refiner Refiner]]],
        "a public_send on a constant" => ["module Eog\n  Refiner.public_send(:install)\nend\n",
                                          [%w[Eog::Refiner Refiner]]],
        "an extend_object on a constant" =>
          ["module Eog\n  Refiner.extend_object(Other)\nend\n", [%w[Eog::Refiner Refiner]]],
        "a define_method on a constant" =>
          ["module Eog\n  Refiner.define_method(:x, other)\nend\n", [%w[Eog::Refiner Refiner]]],
        "a module_eval on a constant" => ["module Eog\n  Refiner.module_eval(\"1\")\nend\n",
                                          [%w[Eog::Refiner Refiner]]],
        "a hand-off in the body of class << self of a module" =>
          ["module Shouty\n  class << self\n    Plugin.install(self)\n  end\nend\n", [%w[Shouty::Plugin Plugin]]],
        "a hand-off in a method defined under class << self of a module" =>
          ["module Shouty\n  class << self\n    def setup = Plugin.install(self)\n  end\nend\n",
           [%w[Shouty::Plugin Plugin]]],
        "a call in a method of a module" =>
          ["module Shouty\n  def self.setup = Plugin.install(self)\nend\n", [%w[Shouty::Plugin Plugin]]]
      }.each do |name, (source, foreign)|
        it "lists the constant of #{name} as foreign" do
          expect(walk_files("lib/m.rb" => source).foreign).to eq(foreign)
        end
      end

      it "reads an extend of an expression as not read in full, with no constant to account for" do
        outcome = walk_files("lib/m.rb" => "module Dslg\n  extend(*HELPERS)\nend\n")

        expect([outcome.mixes_modules, outcome.foreign]).to eq([true, []])
      end

      it "lists a refine target no gem file declares, and not one the gem declares or reopens" do
        foreign = walk_files("lib/m.rb" => "module M\n  refine(ActiveRecord::Base) { def x = 1 }\nend\n")
        declared = walk_files("lib/m.rb" => "module M\n  class Point; end\n  refine(Point) { def x = 1 }\nend\n")
        reopened = walk_files("lib/m.rb" => "class String; end\nmodule M\n  refine(String) { def x = 1 }\nend\n")

        expect(foreign.foreign_targets).to eq([%w[M::ActiveRecord::Base ActiveRecord::Base]])
        expect([declared.foreign_targets, reopened.foreign_targets]).to eq([[], []])
      end

      # The controls: a constant the gem declares (in this file or another), `self`, a class body, the top level, a
      # receiver that is no constant, and a call that hands over nothing.
      {
        "an extend of a module the gem declares" => {
          "lib/m.rb" => "module Helper; end\nmodule Dslg\n  extend Helper\nend\n"
        },
        "an extend of a module another file of the gem declares" => {
          "lib/m.rb" => "module Dslg\n  extend Helper\nend\n", "lib/helper.rb" => "module Helper; end\n"
        },
        "an extend self" => { "lib/m.rb" => "module Dslg\n  extend self\nend\n" },
        "an extend in a class body" => { "lib/m.rb" => "class Base\n  extend Forwardable\nend\n" },
        "an extend on a variable" => { "lib/m.rb" => "def self.included(base) = base.extend(ClassMethods)\n" },
        "a hand-off in a class body" => { "lib/m.rb" => "class Base\n  Plugin.install(self)\nend\n" },
        "a hand-off at the top level" => { "lib/m.rb" => "Plugin.install(self)\n" },
        "a hand-off to a variable" => {
          "lib/m.rb" => "module M\n  def self.setup(registry) = registry.install(self)\nend\n"
        },
        "a call on a constant that hands over nothing" => {
          "lib/m.rb" => "module M\n  VALUE = Config.fetch(:a)\nend\n"
        },
        "a hand-off to a constant the gem declares" => {
          "lib/m.rb" => "module Plugin; end\nmodule M\n  Plugin.install(self)\nend\n"
        },
        "an include in the body of class << self of a class" => {
          "lib/m.rb" => "class C\n  class << self\n    include Refiner\n  end\nend\n"
        },
        "a hand-off in the body of class << self of a class" => {
          "lib/m.rb" => "class C\n  class << self\n    Plugin.install(self)\n  end\nend\n"
        }
      }.each do |name, files|
        it "lists nothing for #{name}" do
          outcome = walk_files(files)

          expect([outcome.foreign, outcome.foreign_targets]).to eq([[], []])
        end
      end

      # The census the project walk runs reaches a gem file: a refine in a method and a `:refine` literal leave the
      # wildcard rows a project module would carry (see walker_walk_census_parity_spec for the full set of shapes).
      it "records the wildcard rows of a refine in a method and of a :refine literal" do
        wildcard = Rigor::Scope::DiscoveryIndex::REFINEMENT_WILDCARD
        outcome = walk_files(
          "lib/a.rb" => "module A\n  def self.setup = refine(String) { def x = 1 }\nend\n",
          "lib/b.rb" => "module B\n  send(:refine, Integer) { def y = 1 }\nend\n"
        )

        expect(outcome.refinements).to eq({ wildcard => { wildcard => %w[A B] } })
      end
    end
  end
end
