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
    map = positions("<% x = 1 %><%= 2.succ %>\n", "_b = +''\n x = 1 ; _b << (( 2.succ ).to_s)\n", { 2 => 1 })

    rows, total = map.line_nodes(1)

    expect(rows.map { |column, node| [column, node.slice] }).to include([4, "x = 1"], [16, "2.succ"])
    expect(total).to eq(rows.length)
  end

  # The compiler's own punctuation joins template bytes into runs the template never had: the `=` of `<%=`
  # matches the `=` of `<=`, so `"= v "` (4 bytes, ending in the v of `1 <= v`) outran the tag body `" v "`
  # (3 bytes) and the probe answered about the WRONG `v` — with exit 0, no fallbacks, and a type `rigor
  # check` disagreed with. Every placement whose node lies inside its own run is a rival reading now.
  it "declines when a longer run ends in another occurrence of the same identifier" do
    map = positions("<%= v %><% if 1 <= v %><% end %>\n",
                    "_b << (( v ).to_s);  if 1 <= v ; ;  end \n", { 1 => 1 })

    expect(map.node_at(line: 1, column: 5)).to eq(:ambiguous)
  end

  # stdlib ERB hoists a line's leading text onto the PREVIOUS compiled line, so the literal the HTML word
  # lives in is not on this template line's compiled lines: without the line above as a spill target the
  # tie never forms and the word types as the tag's code. Only a string literal up there counts — a code
  # node on the line above is ordinary compiled code, and counting it would decline every `<%= v %>` that
  # repeats on consecutive template lines.
  it "declines leading HTML text the compiler hoisted onto the previous compiled line" do
    map = positions("<%= v %>\nname <%= name %>\n",
                    "_e.<<(( v ).to_s); _e.<< \"\\nname \".freeze\n; _e.<<(( name ).to_s)\n",
                    { 1 => 1, 2 => 2 })

    expect(map.node_at(line: 2, column: 1)).to eq(:ambiguous)
  end

  it "still answers a tag on the line after another tag with the same name" do
    map = positions("<%= v %>\n<%= v %>\n", "_e.<<(( v ).to_s)\n_e.<<(( v ).to_s)\n", { 1 => 1, 2 => 2 })

    expect(map.node_at(line: 2, column: 5)).to be_a(Prism::Node)
  end

  # One tag body is copied ONCE: the second occurrence is the same copy seen from the other end, and the
  # rival's node lies inside the winning run's own compiled span. Declining these cost real answers on the
  # busy lines of a real view.
  it "answers a name that repeats inside one tag" do
    map = positions("<%= a.nil? ? l(:x) : l(:y, a) %>\n", "_e.<<(( a.nil? ? l(:x) : l(:y, a) ).to_s)\n",
                    { 1 => 1 })

    node = map.node_at(line: 1, column: 5)

    expect(node).to be_a(Prism::Node)
    expect(node.slice).to eq("a")
  end

  it "declines an assignment that puts the same name after `= `" do
    map = positions("<%= v %><% w = v %>\n", "_b << (( v ).to_s);  w = v ;\n", { 1 => 1 })

    expect(map.node_at(line: 1, column: 5)).to eq(:ambiguous)
  end
end
