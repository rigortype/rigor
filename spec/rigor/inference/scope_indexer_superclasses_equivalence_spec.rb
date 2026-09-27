# frozen_string_literal: true

require "spec_helper"
require "prism"
require "tmpdir"

# ADR-116 WD5 — the superclass table and its header-nesting twin are the second discovery tables built on the
# {DeclarationWalk}. The walker they replaced stays as the oracle (`legacy_superclass_tables`), and these sources
# drive every arm it had through both: headers (nested, compact, rooted, reopened, mixin-only, body-less),
# `class <<` bodies and expressions, every meta-new write spelling, bare factory blocks, the eval family with
# bare, `self`, `self::` and unnamed receivers, and `def`s and blocks. Each runs with a file path and without,
# because the path is what one of the two variants the collector declares is about. The corpus-scale half is
# `RIGOR_SHADOW_RULE_WALK=1`.
module SuperclassesEquivalenceCases
  # One source where the two collectors' `factory_block` variants give the same nodes different contexts:
  # `class_cvars` walks the factory body with an unnamed `self`, so `self::E` names nothing and its `@@e` is
  # not filed, while the superclass table walks it as an ordinary call and files `C::E`.
  FORK = <<~RUBY
    class C
      def top = (@@top = 1)
      Class.new(Parent) do |x = Class.new(InParams) { def param = (@@param = 1) }|
        class self::E < S
          def e = (@@e = 1)
        end
        def body = (@@body = 1)
      end
    end
  RUBY

  CASES = {
    "headers: nested, compact, rooted, reopened, mixin-only" => <<~RUBY,
      module Outer
        class Plain < Base; end
        class Admin::Compact < ::Rooted::Base
          include Helper
        end
        class ::Top < Base; end
        module Mixed
          include Helper
          extend Other
        end
        class Plain < Other; end
      end
    RUBY
    "class << bodies and expressions" => <<~RUBY,
      class C
        class << self
          class Bare < S; end
          class ::Anchored < S; end
          class C::Pathed < S; end
          Class.new(Inner) { }
        end
      end
      class << Registry
        Class.new(TopSingleton) { }
      end
      class << Class.new(InExpression) { }
      end
    RUBY
    "meta-new writes in every spelling" => <<~RUBY,
      class C
        K = Class.new(Base) do
          class self::Inner < S; end
          Class.new(InMeta) { }
        end
        F = Struct.new(:a) do
          class self::Frozen < S; end
        end.freeze
        M ||= Module.new do
          class self::Deep < S; end
        end
        G = G || Data.define(:x) do
          class self::Guarded < S; end
        end
        self::P = Class.new do
          class self::Q < S; end
        end
      end
      Top = Class.new(TopMeta) { Class.new(InTopMeta) { } }
    RUBY
    "bare factory blocks" => <<~RUBY,
      class C
        Class.new(Parent) do |x = Class.new(InParams) { }|
          class self::E < S; end
          class Named < S; end
          Class.new(Nested) { }
        end
      end
      Class.new(Q) { Class.new(R) { class self::TopE < S; end } }
    RUBY
    "eval-family blocks and their receivers" => <<~RUBY,
      class X; end
      module M
        class Y; end
        X.class_eval do
          class self::Reopened < S; end
          Class.new(InEval) { }
        end
        Y.module_exec { class self::Local < S; end }
        X.instance_eval { class self::Single < S; end }
        class_eval { class self::Bare < S; end }
        self::Z.class_exec { class self::W < S; end }
        records.first.class_eval { class self::Opaque < S; end }
      end
      Klass.class_eval(Class.new(InArgs) { }) { }
    RUBY
    "defs and blocks" => <<~RUBY
      def top_build = Class.new(TopDef) { }
      [1].each { Class.new(TopBlock) { } }
      class C
        def build = Class.new(InDef) { }
      end
    RUBY
  }.freeze
end

RSpec.describe Rigor::Inference::ScopeIndexer do
  let(:shadow) { Rigor::Inference::DeclarationWalk::Shadow }
  let(:walk) { Rigor::Inference::DeclarationWalk }

  around do |example|
    saved = ENV.fetch("RIGOR_SHADOW_RULE_WALK", nil)
    ENV.delete("RIGOR_SHADOW_RULE_WALK")
    example.run
  ensure
    saved.nil? ? ENV.delete("RIGOR_SHADOW_RULE_WALK") : ENV.store("RIGOR_SHADOW_RULE_WALK", saved)
  end

  def parse(source)
    Prism.parse(source).value
  end

  def cases
    SuperclassesEquivalenceCases::CASES
  end

  describe "the superclass tables on the declaration walk" do
    SuperclassesEquivalenceCases::CASES.each do |name, source|
      it "builds the legacy walker's tables, with a file path and without: #{name}" do
        root = parse(source)
        ["app/x.rb", nil].each do |path|
          legacy = described_class.legacy_superclass_tables(root, path)
          expect(legacy.first).not_to be_empty
          expect(shadow.first_difference(legacy, described_class.build_superclass_tables(root, path), "")).to be_nil
        end
      end
    end

    it "records each header's ancestry under the nesting outside it, skipping an unnameable header" do
      headers = cases["headers: nested, compact, rooted, reopened, mixin-only"]
      supers, nestings = described_class.build_superclass_tables(parse(headers))
      expect(supers).to eq("Outer::Plain" => "Other", "Outer::Admin::Compact" => "::Rooted::Base", "Top" => "Base")
      expect(nestings.keys).to eq(%w[Outer::Plain Outer::Admin::Compact Top Outer::Mixed])
      expect(nestings["Outer::Admin::Compact"]).to eq(nil => ["Outer"], "::Rooted::Base" => ["Outer"],
                                                      "Helper" => ["Outer"])

      supers, = described_class.build_superclass_tables(parse(cases["class << bodies and expressions"]), "app/x.rb")
      # `C::C::Pathed` is wrong, pinned because the port reproduces the legacy walker: Ruby opens `C::Pathed`.
      # Flip this when #1519 is fixed.
      expect(supers.keys).to eq(["Anchored", "C::C::Pathed", "#<Class:6:4>", "#<Class:app/x.rb:10:2>",
                                 "#<Class:app/x.rb:12:9>"])
    end

    # Both answers below are the `walk_class_superclasses` variants the collector declares, and both are wrong
    # in Ruby's terms; #1521 tracks converging them. Flip these when its items 8 and 11 are fixed.
    it "walks a bare factory block as an ordinary call (the factory_block variant)" do
      supers, nestings = described_class.build_superclass_tables(parse(cases["bare factory blocks"]), "app/x.rb")
      # `self::E` anchors on the enclosing `C`, and the block's parameters are walked.
      expect(supers).to include("C::E" => "S", "TopE" => "S", "#<Class:2:28>" => "InParams")
      expect(nestings.keys).to eq(%w[C::E C::Named TopE])
    end

    it "keys an anonymous class without the path inside class, meta-new and eval bodies (the path variant)" do
      keys = cases.values.flat_map do |source|
        described_class.build_superclass_tables(parse(source), "app/x.rb").first.keys.grep(/\A#</)
      end
      expect(keys).to eq(
        ["#<Class:6:4>", "#<Class:app/x.rb:10:2>", "#<Class:app/x.rb:12:9>", "#<Class:4:4>", "#<Class:19:27>",
         "#<Class:2:2>", "#<Class:2:28>", "#<Class:5:4>", "#<Class:app/x.rb:8:0>", "#<Class:app/x.rb:8:15>",
         "#<Class:6:4>", "#<Class:app/x.rb:14:17>", "#<Class:app/x.rb:1:16>", "#<Class:app/x.rb:2:11>",
         "#<Class:4:14>"]
      )
    end

    # A two-collector walk over the same sources, in both orders: each collector must build exactly what it
    # builds alone, although the two follow different `factory_block` variants.
    def shared_tables(root, scope, order)
      collectors = { cvars: described_class::ClassCvarsCollector.new,
                     supers: described_class::SuperclassesCollector.new }
      walk.run(root, collectors.values_at(*order), described_class.superclass_walk_root("app/x.rb", scope: scope))
      [collectors[:cvars].table, collectors[:supers].tables]
    end

    it "builds both collectors' tables unchanged when they share one walk, across the factory-block fork" do
      scope = Rigor::Scope.empty.with_source_path("app/x.rb")
      (cases.values + [SuperclassesEquivalenceCases::FORK]).each do |source|
        root = parse(source)
        legacy = [described_class.legacy_class_cvar_index(root, scope),
                  described_class.legacy_superclass_tables(root, "app/x.rb")]
        [%i[cvars supers], %i[supers cvars]].each do |order|
          expect(shadow.first_difference(legacy, shared_tables(root, scope, order), "")).to be_nil
        end
      end
    end

    it "reads a subclass's variants in the collector and in the walk alike" do
      # A subclass that overrides both variants with the walk's own rules: the path it keys anonymous classes
      # with and the walk it gets must both follow the override.
      conforming = Class.new(described_class::SuperclassesCollector) do
        const_set(:VARIANTS, { factory_block: :unnamed_self, anonymous_class_path: :whole_file }.freeze)
      end
      collector = conforming.new
      walk.run(parse(SuperclassesEquivalenceCases::FORK), [collector],
               described_class.superclass_walk_root("app/x.rb"))
      expect(collector.tables.first).to eq("#<Class:app/x.rb:3:2>" => "Parent")
    end

    it "gives each collector its own variant's context at the fork" do
      cvars, (supers, _nestings) =
        shared_tables(parse(SuperclassesEquivalenceCases::FORK), Rigor::Scope.empty, %i[cvars supers])
      # The unnamed-self walk skips the block's parameters and leaves `self::E` unnamed; the defs in the
      # body still key on the lexical `C`.
      expect(cvars).to eq("C" => cvars.fetch("C"))
      expect(cvars.fetch("C").keys).to eq(%i[@@top @@body])
      # The ordinary-call walk goes through the parameters and files `self::E` under `C`.
      expect(supers).to eq("#<Class:3:2>" => "Parent", "#<Class:3:28>" => "InParams", "C::E" => "S")
    end
  end

  describe "the shadow harness on the superclass tables" do
    let(:source) { "class C < Base\nend\n" }

    let(:divergence) { Rigor::Inference::DeclarationWalk::Shadow::Divergence }

    it "never runs the legacy walker while RIGOR_SHADOW_RULE_WALK is unset" do
      allow(described_class).to receive(:legacy_superclass_tables).and_call_original
      expect(described_class.build_superclass_tables(parse(source)).first).to eq("C" => "Base")
      expect(described_class).not_to have_received(:legacy_superclass_tables)
    end

    # The superclass collector forgets everything, so the harness must report every file that declares one.
    def diverge!
      ENV.store("RIGOR_SHADOW_RULE_WALK", "1")
      forgetful = Class.new(described_class::SuperclassesCollector) do
        def tables = [{}.freeze, {}.freeze]
      end
      # Built before the stub: the subclass's `new` is the stubbed one.
      instance = forgetful.new
      allow(described_class::SuperclassesCollector).to receive(:new).and_return(instance)
    end

    it "raises through ScopeIndexer.index when the walk's tables diverge" do
      diverge!
      scope = Rigor::Scope.empty.with_source_path("app/c.rb")
      expect { described_class.index(parse(source), default_scope: scope) }
        .to raise_error(divergence,
                        %r{discovery table `superclass_tables` for app/c\.rb: \[0\]: key "C" only in legacy})
    end

    # Each project pre-pass skips a file it cannot read or parse; a divergence is neither, and skipping the
    # file would both pass the check it failed and drop the file from the project index.
    it "raises out of every project pre-pass instead of skipping the file" do
      Dir.mktmpdir("rigor-superclass-prepass-") do |dir|
        path = File.join(dir, "c.rb")
        File.write(path, source)
        diverge!
        expect { described_class.discovered_project_index_for_paths([path]) }.to raise_error(divergence)
        expect { described_class.discovered_def_index_for_paths([path]) }.to raise_error(divergence)
        expect { described_class.scan_summary_for_paths([path]) }.to raise_error(divergence)
        expect { described_class.discovered_project_index_incremental([path], seed_bundles: {}) }
          .to raise_error(divergence)
        # The parameter-inference scan's own discovery seed, which empties itself on any other error.
        seed = Rigor::Inference::ParameterInferenceCollector.new(files: [path], environment: nil)
        expect { seed.send(:discovery_seed_tables) }.to raise_error(divergence)
      end
    end

    it "raises an unknown variant out of the project pre-pass too, rather than emptying the project index" do
      Dir.mktmpdir("rigor-superclass-prepass-") do |dir|
        path = File.join(dir, "c.rb")
        File.write(path, source)
        misspelt = Class.new(described_class::SuperclassesCollector) do
          const_set(:VARIANTS, { factory_block: :ordinary }.freeze)
        end
        instance = misspelt.new
        allow(described_class::SuperclassesCollector).to receive(:new).and_return(instance)
        expect { described_class.discovered_project_index_for_paths([path]) }
          .to raise_error(Rigor::Inference::DeclarationWalk::UnknownVariant)
      end
    end

    it "aborts a cached run rather than re-running it without the project index" do
      Dir.mktmpdir("rigor-superclass-prepass-") do |dir|
        File.write(File.join(dir, "c.rb"), source)
        diverge!
        runner = Rigor::Analysis::Runner.new(
          configuration: Rigor::Configuration.new("paths" => [dir]),
          cache_store: Rigor::Cache::Store.new(root: File.join(dir, ".rigor", "cache"))
        )
        expect { InternalAnalyzerErrorGuard.check!(runner.run([dir]), context: "superclass pre-pass abort") }
          .to raise_error(divergence, /superclass_tables/)
      end
    end
  end
end
