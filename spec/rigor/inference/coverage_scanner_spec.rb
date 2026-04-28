# frozen_string_literal: true

require "prism"

RSpec.describe Rigor::Inference::CoverageScanner do
  let(:scanner) { described_class.new }

  def parse(source)
    Prism.parse(source).value
  end

  describe "#scan" do
    it "marks a Slice-1 program with only literals as fully recognized" do
      result = scanner.scan(parse("[1, 2, 3]\n"))

      expect(result.unrecognized_count).to eq(0)
      expect(result.unrecognized_ratio).to eq(0.0)
      expect(result.visits).to include(Prism::IntegerNode => 3, Prism::ArrayNode => 1)
    end

    it "counts nodes whose classes hit the typer's else branch" do
      result = scanner.scan(parse("foo()\n"))

      expect(result.unrecognized).to include(Prism::CallNode => 1)
      expect(result.events.size).to eq(1)
      expect(result.events.first.node_class).to eq(Prism::CallNode)
    end

    it "does not double-count pass-through wrappers above an unrecognized leaf" do
      result = scanner.scan(parse("foo()\n"))

      expect(result.unrecognized[Prism::ProgramNode]).to eq(0)
      expect(result.unrecognized[Prism::StatementsNode]).to eq(0)
      expect(result.unrecognized[Prism::CallNode]).to eq(1)
    end

    it "tracks visits and unrecognized counts independently per class" do
      result = scanner.scan(parse("foo()\nbar()\n1\n"))

      expect(result.visits[Prism::CallNode]).to eq(2)
      expect(result.unrecognized[Prism::CallNode]).to eq(2)
      expect(result.visits[Prism::IntegerNode]).to eq(1)
      expect(result.unrecognized[Prism::IntegerNode]).to eq(0)
    end

    it "computes a coverage ratio across all visited nodes" do
      result = scanner.scan(parse("foo()\n"))

      expect(result.visited_count).to be > 0
      expect(result.unrecognized_count).to eq(1)
      expect(result.unrecognized_ratio).to be_within(1e-6).of(1.0 / result.visited_count)
    end

    it "exposes recorded events with location information" do
      result = scanner.scan(parse("\nfoo()\n"))

      event = result.events.first
      expect(event.location.start_line).to eq(2)
      expect(event.family).to eq(:prism)
    end
  end
end
