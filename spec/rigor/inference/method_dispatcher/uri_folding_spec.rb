# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::MethodDispatcher::URIFolding do
  def uri_singleton = Rigor::Type::Combinator.singleton_of("URI")
  def c(value)      = Rigor::Type::Combinator.constant_of(value)

  def fold(method_name, *arg_types)
    described_class.try_dispatch(cc(
                                   receiver: uri_singleton,
                                   method_name: method_name,
                                   args: arg_types
                                 ))
  end

  # ── encode_www_form_component ─────────────────────────────────────────

  describe "encode_www_form_component" do
    it "percent-encodes special characters" do
      expect(fold(:encode_www_form_component, c("hello world")))
        .to eq(c("hello+world"))
    end

    it "encodes reserved characters" do
      result = fold(:encode_www_form_component, c("a?b=c&d"))
      expect(result).to be_a(Rigor::Type::Constant)
      expect(result.value).to be_a(String)
    end

    it "returns plain strings unchanged" do
      expect(fold(:encode_www_form_component, c("abc123"))).to eq(c("abc123"))
    end
  end

  # ── decode_www_form_component ─────────────────────────────────────────

  describe "decode_www_form_component" do
    it "decodes percent-encoded strings" do
      expect(fold(:decode_www_form_component, c("hello+world")))
        .to eq(c("hello world"))
    end

    it "returns plain strings unchanged" do
      expect(fold(:decode_www_form_component, c("hello"))).to eq(c("hello"))
    end
  end

  # ── encode_uri_component / decode_uri_component ────────────────────────

  describe "encode_uri_component / decode_uri_component" do
    it "encodes special characters" do
      result = fold(:encode_uri_component, c("hello world"))
      expect(result).to be_a(Rigor::Type::Constant)
      expect(result.value).to be_a(String)
    end

    it "decodes percent-encoded strings" do
      result = fold(:decode_uri_component, c("hello%20world"))
      expect(result).to be_a(Rigor::Type::Constant)
      expect(result.value).to be_a(String)
    end
  end

  # ── Decline / edge cases ──────────────────────────────────────────────

  describe "decline cases" do
    it "declines for a non-Constant argument" do
      expect(fold(:encode_www_form_component, Rigor::Type::Combinator.nominal_of("String")))
        .to be_nil
    end

    it "declines for a non-String constant" do
      expect(fold(:encode_www_form_component, c(42))).to be_nil
    end

    it "declines when more than one argument is given" do
      expect(fold(:encode_www_form_component, c("a"), c("b"))).to be_nil
    end

    it "declines for a non-Singleton receiver" do
      result = described_class.try_dispatch(cc(
                                              receiver: c("URI"),
                                              method_name: :encode_www_form_component,
                                              args: [c("hello")]
                                            ))
      expect(result).to be_nil
    end

    it "declines for a wrong singleton class" do
      result = described_class.try_dispatch(cc(
                                              receiver: Rigor::Type::Combinator.singleton_of("String"),
                                              method_name: :encode_www_form_component,
                                              args: [c("hello")]
                                            ))
      expect(result).to be_nil
    end

    it "declines for an unsupported method" do
      expect(fold(:parse, c("http://example.com"))).to be_nil
    end

    # `URI.parse` is not merely unimplemented here — it is declined on the repo's own rule, and this
    # example is the place that says so, since the decline otherwise looks like an oversight to close.
    # `URI::Generic` and friends are absent from `ConstantFolding::FOLDABLE_CONSTANT_CLASSES`, so this
    # tier has no `Constant[…]` to return; narrowing its ten-arm union to the scheme class a constant
    # string selects would be a precision win but can surface a diagnostic that does not fire today,
    # which is bucket-3 / P0 work rather than this FP-safe category (#121).
    it "declines URI.join for the same reason as URI.parse — no Constant for a URI object" do
      expect(fold(:join, c("https://example.com/"), c("a"))).to be_nil
    end
  end

  # ── encode_www_form / decode_www_form ─────────────────────────────────

  describe "encode_www_form" do
    def tuple(*elements) = Rigor::Type::Combinator.tuple_of(*elements)

    it "folds an array-of-pairs literal to the encoded form" do
      form = tuple(tuple(c("k"), c("v")), tuple(c("x"), c("1")))
      expect(fold(:encode_www_form, form)).to eq(c("k=v&x=1"))
    end

    it "folds a hash literal to the encoded form" do
      shape = Rigor::Type::HashShape.new({ "k" => c("v") })
      expect(fold(:encode_www_form, shape)).to eq(c("k=v"))
    end

    it "percent-encodes through the real encoder rather than a re-derived one" do
      form = tuple(tuple(c("q"), c("a b&c")))
      expect(fold(:encode_www_form, form)).to eq(c(URI.encode_www_form([["q", "a b&c"]])))
    end

    it "declines when any value is not constant" do
      form = tuple(tuple(c("k"), Rigor::Type::Combinator.nominal_of(String)))
      expect(fold(:encode_www_form, form)).to be_nil
    end

    # An open or partly-optional shape describes a hash whose real contents the fold cannot see, so
    # encoding only the known keys would invent a form the program never builds.
    it "declines an open HashShape" do
      shape = Rigor::Type::HashShape.new({ "k" => c("v") }, extra_keys: :open)
      expect(fold(:encode_www_form, shape)).to be_nil
    end

    it "declines a HashShape carrying an optional key" do
      shape = Rigor::Type::HashShape.new({ "k" => c("v") }, optional_keys: ["k"])
      expect(fold(:encode_www_form, shape)).to be_nil
    end

    it "declines a pair that is not two elements wide" do
      form = tuple(tuple(c("k"), c("v"), c("extra")))
      expect(fold(:encode_www_form, form)).to be_nil
    end

    it "declines a form longer than the pair limit" do
      form = tuple(Array.new(65) { |i| tuple(c("k#{i}"), c("v")) })
      expect(fold(:encode_www_form, form)).to be_nil
    end
  end

  describe "decode_www_form" do
    it "folds to a Tuple of constant pairs rather than the RBS Array[[String, String]]" do
      result = fold(:decode_www_form, c("k=v&x=1"))

      expect(result.elements.map { |pair| pair.elements.map(&:value) }).to eq([%w[k v], %w[x 1]])
    end

    it "decodes percent-escapes through the real decoder" do
      result = fold(:decode_www_form, c("q=a+b%26c"))

      expect(result.elements.first.elements.map(&:value)).to eq(["q", "a b&c"])
    end

    it "declines a non-constant argument" do
      expect(fold(:decode_www_form, Rigor::Type::Combinator.nominal_of(String))).to be_nil
    end
  end
end
