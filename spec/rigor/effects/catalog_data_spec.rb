# frozen_string_literal: true

require "spec_helper"

# Pins the shipped catalogue in `data/effects/core.yml` (ADR-103 WD3, #380). The file is hand-audited,
# not generated, and every row is a decision — so the invariants that make it trustworthy are asserted
# here rather than left to review: every label is in the grammar AND in the registry, every row carries
# a justification, every posture and narrowing handler it names exists, and the mutator sets it names by
# reference agree with the ones the rest of the analyzer maintains.
RSpec.describe "the shipped core effect catalogue" do
  subject(:catalog) { Rigor::Effects::Catalog.default }

  let(:registry) { Rigor::Effects::Registry.default }

  def rows
    catalog.class_names.flat_map do |name|
      entry = catalog.class_entry(name)
      entry.instance_methods.map { |selector, row| ["#{name}##{selector}", row] } +
        entry.singleton_methods.map { |selector, row| ["#{name}.#{selector}", row] }
    end
  end

  it "loads the shipped file at schema 1" do
    expect(catalog.schema).to eq(1)
    expect(catalog.class_names).not_to be_empty
  end

  it "spells every label in the grammar and in the shared vocabulary" do
    labels = rows.flat_map { |_, row| row.labels.to_a } +
             catalog.class_names.flat_map { |name| catalog.class_entry(name).posture_labels.to_a }

    labels.uniq.each do |label|
      expect(Rigor::Effects::Label.valid?(label)).to be(true), "#{label.inspect} is not a well-formed label"
      expect(registry.known?(label)).to be(true), "#{label.inspect} is not in the shared vocabulary"
    end
  end

  it "gives every class a `why:` and a posture the defaults declare" do
    # A posture the `defaults:` table does not declare raises at load, so reaching `default` at all is
    # the assertion; this pins that the table is actually used rather than silently defaulted to ∅.
    expect(catalog.class_entry("IO").posture_labels.to_a).to eq(["io"])
    expect(catalog.class_entry("String").posture_labels.to_a).to eq([])
  end

  it "rejects a row with no justification" do
    expect { Rigor::Effects::Catalog.new(defaults: {}, classes: { "Foo" => { "methods" => { "bar" => {} } } }) }
      .to raise_error(Rigor::Effects::Catalog::Error, /why:/)
  end

  it "rejects a posture no default declares" do
    expect { Rigor::Effects::Catalog.new(defaults: {}, classes: { "Foo" => { "posture" => "nope" } }) }
      .to raise_error(Rigor::Effects::Catalog::Error, /unknown posture/)
  end

  it "rejects a narrowing handler that does not exist" do
    classes = { "Foo" => { "methods" => { "bar" => { "narrow" => "nope", "why" => "x" } } } }

    expect { Rigor::Effects::Catalog.new(defaults: {}, classes: classes) }
      .to raise_error(Rigor::Effects::Catalog::Error, /narrowing handler/)
  end

  it "names only narrowing handlers Narrowing implements" do
    rows.each do |key, row|
      next if row.narrow.nil?

      expect(Rigor::Effects::Narrowing.known?(row.narrow)).to be(true), "#{key} names #{row.narrow.inspect}"
    end
  end

  # A narrowed row's own `effects:` is the answer a caller with no call node gets, so it must still be a
  # sound upper bound rather than the ∅ an omitted key would give.
  it "gives every narrowed row a non-empty unnarrowed fallback" do
    rows.each do |key, row|
      next if row.narrow.nil?

      expect(row.labels).not_to be_empty, "#{key} narrows but has no unnarrowed fallback"
    end
  end

  describe "mutator sets, by reference" do
    # The catalogue names `mutators: array | hash | string` and the loader resolves each to the set the
    # widening rules and the mutation classifier already maintain. The YAML never re-spells a selector
    # list, so this is what proves the two cannot drift.
    {
      "Array" => Rigor::Inference::MutationWidening::ARRAY_MUTATORS,
      "Hash" => Rigor::Inference::MutationWidening::HASH_MUTATORS,
      "String" => Rigor::Effects::MutationClassifier::STRING_MUTATORS
    }.each do |class_name, selectors|
      it "marks every #{class_name} mutator as a receiver mutation" do
        selectors.each do |selector|
          entry = catalog.lookup(class_name, selector.to_s)

          expect(entry).not_to be_nil, "#{class_name}##{selector} is not catalogued at all"
          expect(entry.mutates_receiver?).to be(true), "#{class_name}##{selector} is not a receiver mutation"
        end
      end

      it "marks a non-mutating #{class_name} selector as no mutation" do
        expect(catalog.lookup(class_name, "__not_a_real_selector__").mutates_receiver?).to be(false)
      end
    end
  end

  describe "per-class default postures" do
    it "reads an uncatalogued method of a world-facing class as the parent label" do
      expect(catalog.lookup("IO", "some_uncatalogued").labels.to_a).to eq(["io"])
      expect(catalog.lookup("IO", "some_uncatalogued")).to be_posture
    end

    it "reads an uncatalogued method of a value class as nothing" do
      expect(catalog.lookup("String", "some_uncatalogued").labels).to be_empty
      expect(catalog.lookup("String", "some_uncatalogued")).to be_posture
    end

    # `Object`-level selectors exist on every receiver, so a world-facing posture would put a wrong
    # label on the most-called methods in Ruby. They are answered ∅ before the posture is consulted.
    it "answers the universal Object selectors as nothing on a world-facing class" do
      %w[class respond_to? frozen? inspect to_s is_a? tap].each do |selector|
        expect(catalog.lookup("IO", selector).labels).to be_empty, "#{selector} read as a world call"
        expect(catalog.lookup("Socket", selector).labels).to be_empty, "#{selector} read as a world call"
      end
    end

    it "lets a class's own row win over the universal list" do
      # `freeze` and `dup` are on the universal list AND rowed on Kernel; `print` is rowed only. The
      # row is consulted first, so a world-facing row is never swallowed by the ∅ fallback.
      expect(catalog.lookup("Kernel", "print").labels.to_a).to eq(["io.output.stdout"])
      expect(catalog.lookup("Kernel", "freeze").labels).to be_empty
    end

    # Measured on Redmine: `Kernel.Float(x)` read as `io` under the instance side's `world` posture.
    # `Kernel.x` is the module_function copy, and what is actually called that way is pure conversion.
    it "reads Kernel's singleton side as a value class" do
      expect(catalog.lookup("Kernel", "Float", singleton: true).labels).to be_empty
      expect(catalog.lookup("Kernel", "puts").labels.to_a).to eq(["io.output.stdout"])
    end

    it "contributes nothing at all for a class the catalogue does not list" do
      expect(catalog.lookup("Tracer::Reporter", "report")).to be_nil
    end

    it "answers a row only when the posture is suppressed" do
      expect(catalog.lookup("IO", "some_uncatalogued", posture: false)).to be_nil
      expect(catalog.lookup("Kernel", "puts", posture: false)).not_to be_nil
    end
  end

  # The single most important negative invariant of this file (ADR-103 WD3). `data/builtins`' `purity:`
  # facet answers fold-safety in the C-dispatch sense — `Random#rand` is `leaf`, `Array#push` is `leaf` —
  # and reading it as effect freedom would be wrong in both directions.
  describe "the purity: prohibition" do
    it "never opens data/builtins while loading" do
      opened = []
      allow(YAML).to receive(:safe_load_file).and_wrap_original do |original, path, **options|
        opened << path.to_s
        original.call(path, **options)
      end

      Rigor::Effects::Catalog.load_file(Rigor::Effects::Catalog::DATA_PATH)

      expect(opened).to eq([Rigor::Effects::Catalog::DATA_PATH])
      expect(opened.grep(/builtins/)).to be_empty
    end

    it "never mentions the fold-safety facet in the loader or the data" do
      source = File.read(File.expand_path("../../../lib/rigor/effects/catalog.rb", __dir__))
      data = File.read(Rigor::Effects::Catalog::DATA_PATH)

      # The word appears in both files only inside the prose that forbids reading it, never as a key.
      expect(source).not_to match(/\["purity"\]|\[:purity\]/)
      expect(data).not_to match(/^\s*purity:/)
    end

    it "gives Random#rand a nondet.random label even though the fold catalogue calls it leaf" do
      expect(Rigor::Inference::Builtins::RANDOM_CATALOG.method_entry("Random", :rand)["purity"]).to eq("leaf")
      expect(catalog.lookup("Random", "rand").labels.to_a).to eq(["nondet.random"])
    end
  end

  it "is packaged with the gem" do
    # `Catalog.default` degrades to an empty catalogue when the data file is missing, so an omission
    # from the gemspec's file list would be silent at runtime.
    root = File.expand_path("../../..", __dir__)
    spec = Gem::Specification.load(File.join(root, "rigortype.gemspec"))

    expect(spec.files).to include("data/effects/core.yml")
  end
end
