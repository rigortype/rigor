# frozen_string_literal: true

require "rigor/effects/path_finder"
require "rigor/effects/propagator"

# ADR-103 WD7 — `rigor effects explain`'s engine: the shortest edge path from an entry point to the origin
# that introduced a label. The fixpoint already has the graph; this is the review feature that pays for it.
RSpec.describe Rigor::Effects::PathFinder do
  def summary(*names, origin: Rigor::Effects::Origin.catalogue("Net::HTTP.get"))
    bundles = names.empty? ? {} : { origin => Rigor::Effects::LabelSet.new(names) }
    Rigor::Effects::Summary.new(bundles: bundles)
  end

  def edge(receiver, selector)
    Rigor::Effects::FileCollection::Edge.new(
      receiver_class: receiver, kind: :instance, selector: selector, self_call: false
    )
  end

  def table(summaries, edges)
    Rigor::Effects::Propagator.propagate(
      Rigor::Effects::FileCollection.new(summaries: summaries, edges: edges)
    )
  end

  let(:graph) do
    table(
      { "A#create" => summary, "A#place" => summary, "A#charge" => summary("io.net.http"),
        "A#detour" => summary("io.net.http") },
      { "A#create" => [edge("A", "place"), edge("A", "detour")], "A#place" => [edge("A", "charge")] }
    )
  end

  # The path ends at the ORIGIN, not at the last method: the catalogue row that coloured the label is what
  # the reviewer is looking for, and the method that owns it is the hop before.
  it "walks to the origin that introduced the label" do
    path = described_class.shortest(graph, symbol: "A#create", label: "io.net.http")

    expect(path.to_a).to eq(["A#create", "A#detour", "Net::HTTP.get"])
    expect(path.origin_source).to eq(Rigor::Effects::Origin::CATALOGUE)
  end

  # Breadth-first, so a reviewer gets the tightest explanation available rather than whichever one a
  # depth-first walk stumbled into.
  it "prefers the shorter of two routes to the same label" do
    long_only = table(
      { "A#create" => summary, "A#place" => summary, "A#charge" => summary("io.net.http") },
      { "A#create" => [edge("A", "place")], "A#place" => [edge("A", "charge")] }
    )

    expect(described_class.shortest(long_only, symbol: "A#create", label: "io.net.http").to_a)
      .to eq(["A#create", "A#place", "A#charge", "Net::HTTP.get"])
  end

  it "explains a label a method proves in its own body as a one-hop path" do
    expect(described_class.shortest(graph, symbol: "A#charge", label: "io.net.http").to_a)
      .to eq(["A#charge", "Net::HTTP.get"])
  end

  it "answers nil for a label nothing on the graph proves, and for an unknown symbol" do
    expect(described_class.shortest(graph, symbol: "A#create", label: "io.db.write")).to be_nil
    expect(described_class.shortest(graph, symbol: "A#nope", label: "io.net.http")).to be_nil
  end

  it "terminates on a cycle" do
    cyclic = table({ "A#ping" => summary, "A#pong" => summary },
                   { "A#ping" => [edge("A", "pong")], "A#pong" => [edge("A", "ping")] })

    expect(described_class.shortest(cyclic, symbol: "A#ping", label: "io")).to be_nil
  end

  it "renders as the arrow chain the manual documents" do
    expect(described_class.shortest(graph, symbol: "A#create", label: "io.net.http").to_s)
      .to eq("A#create → A#detour → Net::HTTP.get [io.net.http]")
  end
end
