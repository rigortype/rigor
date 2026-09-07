# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::RbsExtended::HktDirectives do
  let(:untyped) { Rigor::Type::Combinator.untyped }

  describe ".parse_register" do
    it "parses the canonical kv-form payload" do
      string = "rigor:v1:hkt_register: uri=json::value arity=1 variance=out bound=untyped"
      reg = described_class.parse_register(string)
      expect(reg).to be_a(Rigor::Inference::HktRegistry::Registration)
      expect(reg.uri).to eq(:"json::value")
      expect(reg.arity).to eq(1)
      expect(reg.variance).to eq([:out])
      expect(reg.bound).to eq(untyped)
    end

    it "parses a multi-arg registration with comma-separated variance" do
      string = "rigor:v1:hkt_register: uri=dry_monads::result arity=2 variance=out,out bound=untyped"
      reg = described_class.parse_register(string)
      expect(reg.arity).to eq(2)
      expect(reg.variance).to eq(%i[out out])
    end

    it "defaults variance to `[:inv] * arity` when omitted" do
      string = "rigor:v1:hkt_register: uri=json::value arity=2"
      reg = described_class.parse_register(string)
      expect(reg.variance).to eq(%i[inv inv])
    end

    it "defaults bound to `untyped` when omitted" do
      string = "rigor:v1:hkt_register: uri=json::value arity=1 variance=out"
      reg = described_class.parse_register(string)
      expect(reg.bound).to eq(untyped)
    end

    it "resolves a bare class-name bound to a Nominal carrier" do
      string = "rigor:v1:hkt_register: uri=json::value arity=1 variance=out bound=Integer"
      reg = described_class.parse_register(string)
      expect(reg.bound).to be_a(Rigor::Type::Nominal)
      expect(reg.bound.class_name).to eq("Integer")
    end

    it "accepts the full wrapping `%a{...}` annotation form" do
      string = "%a{rigor:v1:hkt_register: uri=json::value arity=1 variance=out bound=untyped}"
      reg = described_class.parse_register(string)
      expect(reg).not_to be_nil
      expect(reg.uri).to eq(:"json::value")
    end

    it "returns nil for an unrelated directive string" do
      expect(described_class.parse_register("rigor:v1:return: non-empty-string")).to be_nil
    end

    it "returns nil and emits a reporter entry for missing uri" do
      reporter = collect_reporter
      result = described_class.parse_register("rigor:v1:hkt_register: arity=1", reporter: reporter)
      expect(result).to be_nil
      expect(reporter.entries.first[:message]).to include("uri")
    end

    it "returns nil and emits a reporter entry for un-namespaced uri" do
      reporter = collect_reporter
      result = described_class.parse_register(
        "rigor:v1:hkt_register: uri=value arity=1 variance=out",
        reporter: reporter
      )
      expect(result).to be_nil
      expect(reporter.entries.first[:message]).to include("namespaced")
    end

    it "returns nil and emits a reporter entry for non-positive arity" do
      reporter = collect_reporter
      result = described_class.parse_register(
        "rigor:v1:hkt_register: uri=json::value arity=0",
        reporter: reporter
      )
      expect(result).to be_nil
      expect(reporter.entries.first[:message]).to include("arity must be a positive Integer")
    end

    it "returns nil and emits a reporter entry for variance / arity mismatch" do
      reporter = collect_reporter
      result = described_class.parse_register(
        "rigor:v1:hkt_register: uri=json::value arity=2 variance=out",
        reporter: reporter
      )
      expect(result).to be_nil
      expect(reporter.entries.first[:message]).to include("variance length")
    end

    it "falls back to `untyped` and warns when bound is an unrecognised expression" do
      reporter = collect_reporter
      result = described_class.parse_register(
        "rigor:v1:hkt_register: uri=json::value arity=1 variance=out bound=lower",
        reporter: reporter
      )
      expect(result).not_to be_nil
      expect(result.bound).to eq(untyped)
      expect(reporter.entries.first[:message]).to include("bound `lower` not recognised")
    end
  end

  describe ".parse_define" do
    it "parses the canonical kv-form payload" do
      string = "rigor:v1:hkt_define: uri=json::value params=K body=nil | true"
      defn = described_class.parse_define(string)
      expect(defn).to be_a(Rigor::Inference::HktRegistry::Definition)
      expect(defn.uri).to eq(:"json::value")
      expect(defn.params).to eq([:K])
      expect(defn.body).to eq("nil | true")
    end

    it "populates body_tree by routing body through HktBodyParser" do
      string = "rigor:v1:hkt_define: uri=json::value params=K body=nil | true | false | Integer | " \
               "Float | String | Array[App[json::value, K]] | Hash[K, App[json::value, K]]"
      defn = described_class.parse_define(string)
      expect(defn.body_tree).not_to be_nil
      expect(defn.body_tree).to be_a(Rigor::Inference::HktBody::Union)
    end

    it "lets body= gobble everything to the end of the payload (spaces / pipes / brackets allowed)" do
      string = "rigor:v1:hkt_define: uri=test::id params=K body=K"
      defn = described_class.parse_define(string)
      expect(defn.body).to eq("K")
    end

    it "accepts a multi-param definition with comma-separated params" do
      string = "rigor:v1:hkt_define: uri=dry_monads::result params=T,E body=T | E"
      defn = described_class.parse_define(string)
      expect(defn.params).to eq(%i[T E])
    end

    it "returns nil for an unrelated directive string" do
      expect(described_class.parse_define("rigor:v1:hkt_register: uri=foo::bar arity=1")).to be_nil
    end

    it "returns nil and emits a reporter entry for missing body" do
      reporter = collect_reporter
      result = described_class.parse_define(
        "rigor:v1:hkt_define: uri=json::value params=K",
        reporter: reporter
      )
      expect(result).to be_nil
      expect(reporter.entries.first[:message]).to include("missing body")
    end

    it "returns nil and emits a reporter entry for missing params" do
      reporter = collect_reporter
      result = described_class.parse_define(
        "rigor:v1:hkt_define: uri=json::value body=K",
        reporter: reporter
      )
      expect(result).to be_nil
      expect(reporter.entries.first[:message]).to include("params")
    end

    it "drops body_tree (keeps body String) when body grammar fails to parse" do
      reporter = collect_reporter
      string = "rigor:v1:hkt_define: uri=json::value params=K body=Array[K"
      defn = described_class.parse_define(string, reporter: reporter)
      expect(defn).not_to be_nil
      expect(defn.body_tree).to be_nil
      expect(reporter.entries.last[:message]).to include("body parse error")
    end
  end

  # Issue #785 — the examples above all drive a collecting double that answers `#record`. The PRODUCTION
  # reporter answers neither `#record` nor `#<<`, so every one of those failures was silently discarded in
  # a real run. These pin the real class, which is the only shape the bug could hide in.
  describe "against the production Rigor::RbsExtended::Reporter" do
    let(:reporter) { Rigor::RbsExtended::Reporter.new }

    it "records a declined hkt_register instead of dropping it" do
      result = described_class.parse_register(
        "rigor:v1:hkt_register: uri=broken arity=1 variance=out bound=untyped", reporter: reporter
      )

      expect(result).to be_nil
      expect(reporter).not_to be_empty
      expect(reporter.hkt_directive_errors.size).to eq(1)
      expect(reporter.hkt_directive_errors.first.message).to include("namespaced")
    end

    it "records a declined hkt_define" do
      described_class.parse_define("rigor:v1:hkt_define: uri=json::value body=K", reporter: reporter)

      expect(reporter.hkt_directive_errors.map(&:message)).to include(a_string_including("params="))
    end

    it "positions the entry at the annotation's .rbs file, line and 1-based column" do
      buffer = RBS::Buffer.new(name: "sig/overlay.rbs", content: "line one\nline two\n")
      location = RBS::Location.new(buffer, 9, 13)

      described_class.parse_register(
        "rigor:v1:hkt_register: uri=json::value arity=0", reporter: reporter, source_location: location
      )

      entry = reporter.hkt_directive_errors.first
      expect(entry.path).to eq("sig/overlay.rbs")
      expect(entry.line).to eq(2)
      expect(entry.column).to eq(1)
    end

    it "keeps the entry Marshal-clean and deeply frozen so it can cross the fork-pool drain channel" do
      buffer = RBS::Buffer.new(name: "sig/overlay.rbs", content: "x\n")
      described_class.parse_register(
        "rigor:v1:hkt_register: uri=json::value arity=0", reporter: reporter,
                                                          source_location: RBS::Location.new(buffer, 0, 1)
      )
      entry = reporter.hkt_directive_errors.first

      expect(Marshal.load(Marshal.dump(entry))).to eq(entry)
      expect(Ractor.shareable?(entry)).to be(true)
    end

    it "dedups the same declined directive recorded by two workers over separate RBS::Buffers" do
      %w[a b].each do |content|
        buffer = RBS::Buffer.new(name: "sig/overlay.rbs", content: "#{content}\n")
        described_class.parse_register(
          "rigor:v1:hkt_register: uri=json::value arity=0", reporter: reporter,
                                                            source_location: RBS::Location.new(buffer, 0, 1)
        )
      end

      expect(reporter.hkt_directive_errors.size).to eq(1)
    end
  end

  def collect_reporter
    Class.new do
      attr_reader :entries

      def initialize
        @entries = []
      end

      def record(**entry)
        @entries << entry
      end
    end.new
  end
end
