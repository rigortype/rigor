# frozen_string_literal: true

require "spec_helper"

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
end
