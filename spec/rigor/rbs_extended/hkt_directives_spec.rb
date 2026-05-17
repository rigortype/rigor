# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::RbsExtended::HktDirectives do
  let(:untyped) { Rigor::Type::Combinator.untyped }

  describe ".parse_register" do
    it "parses the canonical JSON-flow payload" do
      string = 'rigor:v1:hkt_register: {"uri": "json::value", "arity": 1, "variance": ["out"], "bound": "untyped"}'
      reg = described_class.parse_register(string)
      expect(reg).to be_a(Rigor::Inference::HktRegistry::Registration)
      expect(reg.uri).to eq(:"json::value")
      expect(reg.arity).to eq(1)
      expect(reg.variance).to eq([:out])
      expect(reg.bound).to eq(untyped)
    end

    it "parses a multi-arg registration with explicit per-position variance" do
      string = "rigor:v1:hkt_register: " \
               '{"uri": "dry_monads::result", "arity": 2, "variance": ["out", "out"], "bound": "untyped"}'
      reg = described_class.parse_register(string)
      expect(reg.arity).to eq(2)
      expect(reg.variance).to eq(%i[out out])
    end

    it "defaults variance to `[:inv] * arity` when omitted" do
      string = 'rigor:v1:hkt_register: {"uri": "json::value", "arity": 2}'
      reg = described_class.parse_register(string)
      expect(reg.variance).to eq(%i[inv inv])
    end

    it "defaults bound to `untyped` when omitted" do
      string = 'rigor:v1:hkt_register: {"uri": "json::value", "arity": 1, "variance": ["out"]}'
      reg = described_class.parse_register(string)
      expect(reg.bound).to eq(untyped)
    end

    it "resolves a bare class-name bound to a Nominal carrier" do
      string = 'rigor:v1:hkt_register: {"uri": "json::value", "arity": 1, "variance": ["out"], "bound": "Integer"}'
      reg = described_class.parse_register(string)
      expect(reg.bound).to be_a(Rigor::Type::Nominal)
      expect(reg.bound.class_name).to eq("Integer")
    end

    it "accepts the full wrapping `%a{...}` annotation form" do
      string = '%a{rigor:v1:hkt_register: {"uri": "json::value", "arity": 1, "variance": ["out"], "bound": "untyped"}}'
      reg = described_class.parse_register(string)
      expect(reg).not_to be_nil
      expect(reg.uri).to eq(:"json::value")
    end

    it "returns nil for an unrelated directive string" do
      expect(described_class.parse_register("rigor:v1:return: non-empty-string")).to be_nil
    end

    it "returns nil and emits a reporter entry for unparseable JSON" do
      reporter = collect_reporter
      result = described_class.parse_register("rigor:v1:hkt_register: not_json", reporter: reporter)
      expect(result).to be_nil
      expect(reporter.entries).not_to be_empty
      expect(reporter.entries.first[:message]).to match(/JSON payload parse error/)
    end

    it "returns nil and emits a reporter entry for missing uri" do
      reporter = collect_reporter
      result = described_class.parse_register('rigor:v1:hkt_register: {"arity": 1}', reporter: reporter)
      expect(result).to be_nil
      expect(reporter.entries.first[:message]).to match(/uri/)
    end

    it "returns nil and emits a reporter entry for un-namespaced uri" do
      reporter = collect_reporter
      result = described_class.parse_register(
        'rigor:v1:hkt_register: {"uri": "value", "arity": 1, "variance": ["out"]}',
        reporter: reporter
      )
      expect(result).to be_nil
      expect(reporter.entries.first[:message]).to match(/namespaced/)
    end

    it "returns nil and emits a reporter entry for non-positive arity" do
      reporter = collect_reporter
      result = described_class.parse_register(
        'rigor:v1:hkt_register: {"uri": "json::value", "arity": 0}',
        reporter: reporter
      )
      expect(result).to be_nil
      expect(reporter.entries.first[:message]).to match(/arity must be a positive Integer/)
    end

    it "returns nil and emits a reporter entry for variance / arity mismatch" do
      reporter = collect_reporter
      result = described_class.parse_register(
        'rigor:v1:hkt_register: {"uri": "json::value", "arity": 2, "variance": ["out"]}',
        reporter: reporter
      )
      expect(result).to be_nil
      expect(reporter.entries.first[:message]).to match(/variance length/)
    end

    it "falls back to `untyped` and warns when bound is an unrecognised expression" do
      reporter = collect_reporter
      result = described_class.parse_register(
        'rigor:v1:hkt_register: {"uri": "json::value", "arity": 1, "variance": ["out"], "bound": "Array[String]"}',
        reporter: reporter
      )
      expect(result).not_to be_nil
      expect(result.bound).to eq(untyped)
      expect(reporter.entries.first[:message]).to match(/bound `Array\[String\]` not recognised/)
    end
  end

  describe ".parse_define" do
    it "parses the canonical JSON-flow payload" do
      string = 'rigor:v1:hkt_define: {"uri": "json::value", "params": ["K"], "body": "nil | bool"}'
      defn = described_class.parse_define(string)
      expect(defn).to be_a(Rigor::Inference::HktRegistry::Definition)
      expect(defn.uri).to eq(:"json::value")
      expect(defn.params).to eq([:K])
      expect(defn.body).to eq("nil | bool")
    end

    it "accepts an empty params list" do
      string = 'rigor:v1:hkt_define: {"uri": "json::value", "params": [], "body": "nil"}'
      defn = described_class.parse_define(string)
      expect(defn.params).to eq([])
    end

    it "returns nil for an unrelated directive string" do
      expect(described_class.parse_define("rigor:v1:hkt_register: {}")).to be_nil
    end

    it "returns nil and emits a reporter entry for missing body" do
      reporter = collect_reporter
      result = described_class.parse_define(
        'rigor:v1:hkt_define: {"uri": "json::value", "params": ["K"]}',
        reporter: reporter
      )
      expect(result).to be_nil
      expect(reporter.entries.first[:message]).to match(/body must be a String/)
    end

    it "returns nil and emits a reporter entry for non-Array params" do
      reporter = collect_reporter
      result = described_class.parse_define(
        'rigor:v1:hkt_define: {"uri": "json::value", "params": "K", "body": "_"}',
        reporter: reporter
      )
      expect(result).to be_nil
      expect(reporter.entries.first[:message]).to match(/params must be an Array/)
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
