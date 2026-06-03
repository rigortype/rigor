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
  end
end
