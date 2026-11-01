# frozen_string_literal: true

require "spec_helper"
require "prism"

# Issue #1596 — the instance variables an implicit-self or `self.` call may write, when the analysis proves the set.
RSpec.describe Rigor::Inference::SelfCallIvarWrites do
  # A scope whose `self` is a `Holder` defining each `def` of `body`.
  def scope_for(body, refinements: {})
    defs = Prism.parse("class Holder\n#{body}\nend").value.statements.body.first.body.body
    table = defs.grep(Prism::DefNode).to_h { |node| [node.name, node] }
    index = Rigor::Scope::DiscoveryIndex::EMPTY.with(
      discovered_classes: { "Holder" => true }, discovered_def_nodes: { "Holder" => table },
      contested_discovered_def_nodes: {}, discovered_refinements: refinements
    )
    Rigor::Scope.empty(environment: Rigor::Environment.default).with_discovery(index)
                .with_self_type(Rigor::Type::Combinator.nominal_of("Holder"))
  end

  def call(source) = Prism.parse(source).value.statements.body.last

  it "collects the instance variables every reachable def writes, through recursion" do
    scope = scope_for(<<~RUBY)
      def log(message) = (warn(message); note)
      def note = (@count = 1; @seen ||= true; log("again"))
    RUBY
    expect(described_class.of(call("log('x')"), scope)).to eq(Set[:@count, :@seen])
    expect(described_class.of(call("self.log('x')"), scope)).to eq(Set[:@count, :@seen])
  end

  it "reads the call's literal block as code that may run" do
    scope = scope_for("def log = nil")
    expect(described_class.of(call("log { @io = nil }"), scope)).to eq(Set[:@io])
  end

  it "proves nothing past a global or constant write, a yield, a super or an unresolved callee" do
    ["def log = ($g = 1)", "def log = (LIMIT = 1)", "def log = yield", "def log = super", "def log = super()",
     "def log = helper"]
      .each do |body|
        expect(described_class.of(call("log"), scope_for(body))).to be_nil, body
      end
  end

  it "proves nothing past a call on a local or parameter, or a code-running name" do
    ["def log(m) = m.to_s", "def log = send(:x)", "def log = method(:x)", "def log = instance_variable_set(:@a, 1)"]
      .each do |body|
        expect(described_class.of(call("log"), scope_for(body))).to be_nil, body
      end
  end

  # `self` as a value lets core code run `self`'s `to_s`, `hash`, `==` or `to_a`; a Kernel method outside the
  # accepted few may run one itself (`display` runs `to_s`).
  it "proves nothing where `self` is a value, or for a Kernel method that may call back into `self`" do
    ["def log = warn(\"\#{self}\")", "def log = { self => 1 }", "def log = [*self]", "def log = (a, = self)",
     "def log = (case 1 when self then 1 end)", "def log = display", "def log = inspect"].each do |body|
      expect(described_class.of(call("log"), scope_for(body))).to be_nil, body
    end
    expect(described_class.of(call("log(self)"), scope_for("def log(_x) = nil"))).to be_nil
    expect(described_class.of(call("self.log"), scope_for("def log = self.class"))).to eq(Set[])
  end

  it "proves nothing for a call with a block argument" do
    expect(described_class.of(call("log(&:upcase)"), scope_for("def log = nil"))).to be_nil
  end

  it "keeps a core method on a literal receiver, unless a refine block anywhere defines its name" do
    expect(described_class.of(call("log"), scope_for("def log = 'x'.upcase"))).to eq(Set[])
    refined = scope_for("def log = 'x'.upcase", refinements: { "String" => { upcase: ["Loud"] } })
    expect(described_class.of(call("log"), refined)).to be_nil
  end

  # Issue #2203 — a names-wildcard row (a computed `define_method`, `import_methods`) refines every name, on any class,
  # as a literal row refines its own name; a literal row of another name refines nothing the read calls.
  it "proves nothing past a names-wildcard refine row, whatever class it refines" do
    [{ "Kernel" => { "*" => ["R"] } }, { "String" => { "*" => ["R"] } }, { "*" => { "*" => ["R"] } }].each do |rows|
      expect(described_class.of(call("log"), scope_for("def log = warn('x')", refinements: rows))).to be_nil, rows.inspect
    end
    literal = scope_for("def log = warn('x')", refinements: { "Kernel" => { other: ["R"] } })
    expect(described_class.of(call("log"), literal)).to eq(Set[])
  end

  it "gives up past its def budget" do
    count = described_class::DEF_BUDGET
    chain = (0...count).map { |i| "def m#{i} = m#{i + 1}" }.join("\n")
    expect(described_class.of(call("m0"), scope_for("#{chain}\ndef m#{count} = nil"))).to be_nil
    expect(described_class.of(call("m1"), scope_for("#{chain}\ndef m#{count} = nil"))).to eq(Set[])
  end
end
