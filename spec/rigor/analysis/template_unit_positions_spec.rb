# frozen_string_literal: true

require "prism"

require "rigor"
require "rigor/analysis/template_units"
require "rigor/analysis/template_unit_positions"

# #1040 — the inverse position map, on hand-written compiled sources so each soundness rule is pinned
# without a plugin in the way.
RSpec.describe Rigor::Analysis::TemplateUnitPositions do
  def positions(template, compiled, line_map)
    entry = Rigor::Analysis::TemplateUnits::Entry.new(
      logical_name: "x", path: "x.erb", source: compiled, line_map: line_map, self_type: nil, locals: {},
      ivar_seeds: {}, digest: "d", unit_key: "view:x", plugin_id: "p", suppressed_rules: []
    )
    described_class.new(entry: entry, template: template, root: Prism.parse(compiled).value)
  end

  it "maps a column through the tag body the compiler copied" do
    map = positions("<p><%= user.name %></p>\n", "_b = +''; _b << '<p>'; _b << (user.name).to_s; _b << '</p>'\n",
                    { 1 => 1 })

    node = map.node_at(line: 1, column: 13)

    expect(node).to be_a(Prism::CallNode)
    expect(node.slice).to eq("user.name")
  end

  # Template text is copied into a string LITERAL, and the literal's quotes are not template bytes, so the
  # deepest node there never lies inside the run.
  it "declines markup, whose bytes land inside a string literal" do
    map = positions("<p><%= user.name %></p>\n", "_b << '<p>'; _b << (user.name).to_s; _b << '</p>'\n", { 1 => 1 })

    expect(map.node_at(line: 1, column: 2)).to eq(:not_verbatim)
  end

  # The trap a "pick the placement whose node looks like code" rule falls into: the TEXT `name` also
  # matches the tag's `name `, and choosing it would answer the local's type for a word of HTML. The two
  # placements tie on length, so the probe declines instead.
  it "declines a word of text that also appears as code, rather than guessing the code" do
    map = positions("name <%= name %>\n", "_b << \"name \"; _b << (( name ).to_s)\n", { 1 => 1 })

    expect(map.node_at(line: 1, column: 1)).to eq(:ambiguous)
  end

  it "declines a position whose bytes were copied twice" do
    map = positions("<%= a %><%= a %>\n", "a = 1; _b << (( a ).to_s); _b << (( a ).to_s)\n", { 1 => 1 })

    expect(map.node_at(line: 1, column: 5)).to eq(:ambiguous)
  end

  it "declines a template line the compiler emitted nothing for" do
    map = positions("one\ntwo\n", "one\n", { 1 => 1 })

    expect(map.node_at(line: 2, column: 1)).to eq(:no_compiled_line)
  end

  it "reads every compiled line that maps to the template line, and lists only verbatim expressions" do
    map = positions("<% x = 1 %><%= x.succ %>\n", "_b = +''\n x = 1 ; _b << (( x.succ ).to_s)\n", { 2 => 1 })

    rows, total = map.line_nodes(1)

    expect(rows.map { |column, node| [column, node.slice] }).to include([4, "x = 1"], [16, "x.succ"])
    expect(total).to eq(rows.length)
  end
end
