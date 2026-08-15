# frozen_string_literal: true

require "spec_helper"
require "rigor/inference/pre_eval_constants"

# Issue #352 — the type-level half of the `pre_eval:` constant publication. The cross-file behaviour these
# rules produce is pinned end-to-end in `spec/rigor/analysis/pre_eval_constants_spec.rb`; this file pins the
# rules themselves, including the arms an end-to-end fixture cannot easily reach.
RSpec.describe Rigor::Inference::PreEvalConstants do
  let(:combinator) { Rigor::Type::Combinator }

  describe ".widen" do
    it "erases a value-pinned constant to its class" do
      expect(described_class.widen(combinator.constant_of(42))).to eq(combinator.nominal_of("Integer"))
      expect(described_class.widen(combinator.constant_of("x"))).to eq(combinator.nominal_of("String"))
      expect(described_class.widen(combinator.constant_of(:sym))).to eq(combinator.nominal_of("Symbol"))
    end

    it "declines a nil-valued constant" do
      expect(described_class.widen(combinator.constant_of(nil))).to be_nil
    end

    it "erases a bounded integer and a refinement to their base" do
      expect(described_class.widen(combinator.integer_range(1, 6))).to eq(combinator.nominal_of("Integer"))
      refined = Rigor::Type::Refined.new(combinator.nominal_of("String"), :"non-empty-string")
      expect(described_class.widen(refined)).to eq(combinator.nominal_of("String"))
    end

    it "erases a Tuple to raw Array and a HashShape to raw Hash, dropping the shape" do
      tuple = Rigor::Type::Tuple.new([combinator.constant_of(1), combinator.constant_of(2)])
      shape = Rigor::Type::HashShape.new({ a: combinator.constant_of(1) })
      expect(described_class.widen(tuple)).to eq(combinator.nominal_of("Array"))
      expect(described_class.widen(shape)).to eq(combinator.nominal_of("Hash"))
    end

    it "strips a nominal's type arguments" do
      applied = combinator.nominal_of("Array", type_args: [combinator.nominal_of("String")])
      expect(described_class.widen(applied)).to eq(combinator.nominal_of("Array"))
    end

    it "passes a class-alias singleton through unchanged" do
      singleton = combinator.singleton_of("String")
      expect(described_class.widen(singleton)).to eq(singleton)
    end

    it "widens every member of a union" do
      union = combinator.union(combinator.constant_of(1), combinator.constant_of("a"))
      expect(described_class.widen(union))
        .to eq(combinator.union(combinator.nominal_of("Integer"), combinator.nominal_of("String")))
    end

    it "declines a union whose extent is not fully known" do
      union = combinator.union(combinator.constant_of(1), combinator.top)
      expect(described_class.widen(union)).to be_nil
    end

    it "declines the carriers that already read as `Dynamic[top]` cross-file" do
      [combinator.top, combinator.bot, combinator.untyped,
       combinator.dynamic(combinator.nominal_of("Integer"))].each do |type|
        expect(described_class.widen(type)).to be_nil
      end
    end
  end

  describe ".collect" do
    # A stub `scope_builder` is enough here: the fixtures declare literals, so the rvalue typer never needs an
    # RBS environment. The environment-bound path is covered end-to-end in the analysis spec.
    def collect(files)
      Dir.mktmpdir("rigor-pre-eval-collect-") do |dir|
        paths = files.map do |name, body|
          File.join(dir, name).tap { |path| File.write(path, body) }
        end
        described_class.collect(paths: paths, scope_builder: ->(path) { Rigor::Scope.empty(source_path: path) })
      end
    end

    it "publishes the widened table keyed by qualified name" do
      table = collect("a.rb" => "TOP = 1\nmodule M\n  NESTED = \"s\"\nend\n")
      expect(table["TOP"]).to eq(combinator.nominal_of("Integer"))
      expect(table["M::NESTED"]).to eq(combinator.nominal_of("String"))
    end

    it "keeps a name two files agree on, and drops one they disagree on" do
      table = collect("a.rb" => "AGREE = 1\nCLASH = 1\n", "b.rb" => "AGREE = 2\nCLASH = \"two\"\n")
      expect(table["AGREE"]).to eq(combinator.nominal_of("Integer"))
      expect(table).not_to have_key("CLASH")
    end

    it "does not let a later agreeing write resurrect a conflicted name" do
      table = collect("a.rb" => "X = 1\n", "b.rb" => "X = \"s\"\n", "c.rb" => "X = 2\n")
      expect(table).not_to have_key("X")
    end

    it "fails soft on an unparseable file rather than aborting the collection" do
      table = collect("a.rb" => "GOOD = 1\n", "b.rb" => "def broken(\n")
      expect(table["GOOD"]).to eq(combinator.nominal_of("Integer"))
    end

    it "returns a frozen table" do
      expect(collect("a.rb" => "K = 1\n")).to be_frozen
    end
  end
end
