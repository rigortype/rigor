# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe Rigor::Inference::Builtins::MethodCatalog do
  describe "string/array singleton instances" do
    it "STRING_CATALOG approves common pure String methods" do
      catalog = Rigor::Inference::Builtins::STRING_CATALOG
      %i[length size bytesize empty? include? start_with? end_with? index count].each do |sel|
        expect(catalog.safe_for_folding?("String", sel)).to be(true)
      end
    end

    it "STRING_CATALOG approves Symbol methods (Symbol lives in string.yml)" do
      catalog = Rigor::Inference::Builtins::STRING_CATALOG
      expect(catalog.safe_for_folding?("Symbol", :length)).to be(true)
      expect(catalog.safe_for_folding?("Symbol", :empty?)).to be(true)
      expect(catalog.safe_for_folding?("Symbol", :casecmp?)).to be(true)
    end

    it "STRING_CATALOG blocks bang-suffixed selectors" do
      catalog = Rigor::Inference::Builtins::STRING_CATALOG
      %i[upcase! downcase! reverse! strip! sub! gsub! tr!].each do |sel|
        expect(catalog.safe_for_folding?("String", sel)).to be(false)
      end
    end

    it "STRING_CATALOG blocks explicitly-listed mutators" do
      catalog = Rigor::Inference::Builtins::STRING_CATALOG
      %i[replace clear << concat insert].each do |sel|
        expect(catalog.safe_for_folding?("String", sel)).to be(false)
      end
    end

    it "STRING_CATALOG blocks `crypt` (platform `crypt(3)` — not reproducible across OS / libc)" do
      catalog = Rigor::Inference::Builtins::STRING_CATALOG
      # `crypt` is classified `:leaf` in string.yml, but its output is
      # platform-dependent, so it must not fold to a Constant.
      expect(catalog.safe_for_folding?("String", :crypt)).to be(false)
    end

    it "universally blocks per-process-non-reproducible selectors (hash / object_id)" do
      # `#hash` is SipHash-salted per process and `#object_id` is
      # per-process identity — folding either bakes one process's value
      # into the type + cache. The block is universal (catalog-wide), not
      # per-class, because these are Object-level methods on every receiver.
      %w[String Symbol].each do |klass|
        expect(Rigor::Inference::Builtins::STRING_CATALOG.safe_for_folding?(klass, :hash)).to be(false)
      end
      %w[Integer Float].each do |klass|
        expect(Rigor::Inference::Builtins::NUMERIC_CATALOG.safe_for_folding?(klass, :hash)).to be(false)
      end
      expect(Rigor::Inference::Builtins::STRING_CATALOG.safe_for_folding?("String", :object_id)).to be(false)
    end

    it "ARRAY_CATALOG blocks the mutator soup (push, pop, <<, replace, …)" do
      catalog = Rigor::Inference::Builtins::ARRAY_CATALOG
      %i[push pop shift unshift << replace clear concat insert].each do |sel|
        expect(catalog.safe_for_folding?("Array", sel)).to be(false)
      end
    end

    it "HASH_CATALOG approves pure Hash readers (size, [], include?, dig, …)" do
      catalog = Rigor::Inference::Builtins::HASH_CATALOG
      %i[size length empty? [] include? has_key? has_value? dig invert compact].each do |sel|
        expect(catalog.safe_for_folding?("Hash", sel)).to be(true)
      end
    end

    it "HASH_CATALOG blocks block-yielding leaves classified as :leaf by the C-body heuristic" do
      catalog = Rigor::Inference::Builtins::HASH_CATALOG
      # `each*` / `select` / `filter` / `reject` / `transform_values` /
      # `merge` all dispatch through `rb_hash_foreach` (or yield via a
      # static callback) — the regex-based classifier marks them as
      # `:leaf` despite being block-dependent.
      %i[each each_pair each_key each_value select filter reject transform_values merge].each do |sel|
        expect(catalog.safe_for_folding?("Hash", sel)).to be(false)
      end
    end

    it "HASH_CATALOG blocks bang-suffixed mutators (compact!, select!, merge!, …)" do
      catalog = Rigor::Inference::Builtins::HASH_CATALOG
      %i[compact! select! reject! filter! transform_keys! transform_values! merge!].each do |sel|
        expect(catalog.safe_for_folding?("Hash", sel)).to be(false)
      end
    end
  end

  describe "blocklist semantics" do
    let(:catalog) do
      described_class.new(
        path: "/nonexistent/path.yml",
        mutating_selectors: { "Foo" => Set[:bar] }
      )
    end

    it "returns false for an unknown class regardless of selector" do
      expect(catalog.safe_for_folding?("UnknownClass", :bar)).to be(false)
    end

    it "returns false when the catalog file is missing (graceful degrade)" do
      expect(catalog.safe_for_folding?("Foo", :anything)).to be(false)
    end

    it "blocks bang selectors universally" do
      expect(catalog.safe_for_folding?("Foo", :baz!)).to be(false)
    end
  end

  describe "alias resolution and reset!" do
    # A real catalog ships an `aliases` section mapping an alias
    # selector to its canonical target; `method_entry` resolves the
    # alias to the target's entry. Exercise it from a temp YAML so the
    # whole resolve_alias_entry path (and `reset!`) is covered.
    let(:catalog_yaml) do
      <<~YAML
        classes:
          Foo:
            instance_methods:
              real_method:
                purity: leaf
              trivial_method:
                purity: trivial
              numeric_method:
                purity: leaf_when_numeric
              dispatch_method:
                purity: dispatch
            aliases:
              aliased_method:
                old: real_method
              dangling_alias:
                old: missing_method
      YAML
    end

    # Writes `catalog_yaml` to a temp file and yields a catalog built
    # from it; the file is removed when the block returns.
    def with_catalog
      Tempfile.create(["method-catalog", ".yml"]) do |f|
        f.write(catalog_yaml)
        f.flush
        yield described_class.new(path: f.path)
      end
    end

    it "resolves an instance-method alias to its target's entry" do
      with_catalog do |catalog|
        expect(catalog.method_entry("Foo", :aliased_method)).to eq("purity" => "leaf")
        expect(catalog.safe_for_folding?("Foo", :aliased_method)).to be(true)
      end
    end

    it "returns nil for an alias whose target does not exist" do
      with_catalog do |catalog|
        expect(catalog.method_entry("Foo", :dangling_alias)).to be_nil
        expect(catalog.safe_for_folding?("Foo", :dangling_alias)).to be(false)
      end
    end

    it "folds exactly the leaf / trivial / leaf_when_numeric purities" do
      # Pins the FOLDABLE_PURITIES membership: each foldable purity folds,
      # and a non-foldable one (`dispatch`) does not.
      with_catalog do |catalog|
        expect(catalog.safe_for_folding?("Foo", :real_method)).to be(true)     # leaf
        expect(catalog.safe_for_folding?("Foo", :trivial_method)).to be(true)  # trivial
        expect(catalog.safe_for_folding?("Foo", :numeric_method)).to be(true)  # leaf_when_numeric
        expect(catalog.safe_for_folding?("Foo", :dispatch_method)).to be(false)
      end
    end

    it "does not resolve aliases for singleton-method lookups" do
      # resolve_alias_entry only consults the instance_methods bucket.
      with_catalog do |catalog|
        expect(catalog.method_entry("Foo", :aliased_method, kind: :singleton)).to be_nil
      end
    end

    it "reset! reloads the catalog from disk and keeps resolving" do
      with_catalog do |catalog|
        expect { catalog.reset! }.not_to raise_error
        expect(catalog.safe_for_folding?("Foo", :real_method)).to be(true)
        expect(catalog.safe_for_folding?("Foo", :aliased_method)).to be(true)
      end
    end
  end
end
