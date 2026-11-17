# frozen_string_literal: true

require "spec_helper"

# ADR-116 WD1 / C4 — {CheckRules::OverrideParamNarrowed.diagnostic} on a parsed snippet and its scope index, with no
# runner: the snippet's own `def`s give the project ancestry, and a signature file (`sig`) gives the RBS both sides of
# the comparison must carry. `override_and_return_type_spec.rb` pins the rule's builder through the whole run.
#
# Mutation-proved: each guard line of `diagnostic` and the helpers it owns was blanked in turn and an example here
# failed, except these, which no input here distinguishes (one line on what was tried each):
#
# - `next if override_param.nil? || parent_param.nil?`: a translation failure needs a type the translator rejects,
#   which no signature the loader accepts produces.
# - `next if dynamic_top?(parent_param) || dynamic_top?(override_param)`: a `Dynamic` slot accepts and is accepted by
#   everything, so the comparison after it is never `no` for one (the "untyped" example pins the behaviour).
RSpec.describe Rigor::Analysis::CheckRules::OverrideParamNarrowed do
  def defs_in(node, found = [])
    found << node if node.is_a?(Prism::DefNode)
    node.compact_child_nodes.each { |child| defs_in(child, found) }
    found
  end

  def indexed(source, sig)
    environment = Rigor::Environment.for_project(signature_paths: [RunnerHelpers.materialise_sig("demo.rbs" => sig)])
    program = Prism.parse(source).value
    [program,
     Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty(environment: environment))]
  end

  # `[line, message]` for each `def` of `source` the rule reports, against the signatures `sig`.
  def fired(source, sig)
    program, scope_index = indexed(source, sig)
    defs_in(program).filter_map do |def_node|
      row = described_class.diagnostic("mem.rb", def_node, scope_index)
      [def_node.location.start_line, row.message] if row
    end
  end

  let(:source) { "class Base\n  def other(a) = a\nend\nclass Sub < Base\n  def other(a) = a\nend\n" }

  def sig_for(parent_params, override_params)
    "class Base\n  def other: (#{parent_params}) -> Integer\nend\nclass Sub < Base\n  " \
      "def other: (#{override_params}) -> Integer\nend\n"
  end

  it "reports an override whose parameter is narrower than its parent's" do
    expect(fired(source, sig_for("Object", "Integer"))).to eq(
      [[5, "parameter 1 of `other' narrowed from Object to Integer (overrides Base#other); breaks substitutability"]]
    )
  end

  it "reports at the method name, with the rule id, the warning severity and the method name" do
    program, scope_index = indexed(source, sig_for("Object", "Integer"))
    row = described_class.diagnostic("mem.rb", defs_in(program).last, scope_index)

    expect([row.rule, row.severity, row.method_name, row.line, row.column]).to eq(
      [Rigor::Analysis::CheckRules::RULE_OVERRIDE_PARAM_NARROWED, :warning, "other", 5, 7]
    )
  end

  it "numbers the first narrowed position, 1-based" do
    two = "class Base\n  def other(a, b) = a\nend\nclass Sub < Base\n  def other(a, b) = a\nend\n"
    sig = "class Base\n  def other: (Object, Object) -> Integer\nend\nclass Sub < Base\n  " \
          "def other: (Object, Integer) -> Integer\nend\n"

    expect(fired(two, sig).map(&:last)).to eq(
      ["parameter 2 of `other' narrowed from Object to Integer (overrides Base#other); breaks substitutability"]
    )
  end

  it "compares optional positionals too" do
    sig = "class Base\n  def other: (?Object) -> Integer\nend\nclass Sub < Base\n  " \
          "def other: (?Integer) -> Integer\nend\n"

    expect(fired(source, sig).size).to eq(1)
  end

  it "is silent for a widening and for an identical parameter" do
    expect([fired(source, sig_for("Integer", "Object")), fired(source, sig_for("Integer", "Integer"))]).to eq([[], []])
  end

  it "is silent when the parent's parameter is `untyped`, or the override's" do
    expect([fired(source, sig_for("untyped", "Integer")), fired(source, sig_for("Object", "untyped"))]).to eq([[], []])
  end

  it "is silent when either side has two method types, whose arms cannot be paired" do
    parent_overloaded = "class Base\n  def other: (Object) -> Integer | (String, String) -> Integer\nend\n" \
                        "class Sub < Base\n  def other: (Integer) -> Integer\nend\n"
    override_overloaded = "class Base\n  def other: (Object) -> Integer\nend\n" \
                          "class Sub < Base\n  def other: (Integer) -> Integer | (String, String) -> Integer\nend\n"

    expect([fired(source, parent_overloaded), fired(source, override_overloaded)]).to eq([[], []])
  end

  it "is silent for a method type with no positional list (`(?)`)" do
    sig = "class Base\n  def other: (?) -> Integer\nend\nclass Sub < Base\n  def other: (Integer) -> Integer\nend\n"

    expect(fired(source, sig)).to eq([])
  end

  it "compares only the positions both sides have" do
    sig = "class Base\n  def other: (Object) -> Integer\nend\nclass Sub < Base\n  " \
          "def other: (Object, ?Integer) -> Integer\nend\n"

    expect(fired(source, sig)).to eq([])
  end

  it "ignores a keyword parameter, which has no position" do
    sig = "class Base\n  def other: (k: Object) -> Integer\nend\nclass Sub < Base\n  " \
          "def other: (k: Integer) -> Integer\nend\n"

    expect(fired(source, sig)).to eq([])
  end

  it "is silent when the override's own class declares no signature" do
    expect(fired(source, "class Base\n  def other: (Object) -> Integer\nend\n")).to eq([])
  end

  it "is silent for a singleton method and for the object-lifecycle hooks" do
    singleton = "class Base\n  def self.other(a) = a\nend\nclass Sub < Base\n  def self.other(a) = a\nend\n"
    sig = "class Base\n  def self.other: (Object) -> Integer\nend\nclass Sub\n  " \
          "def self.other: (Integer) -> Integer\nend\n"
    hook = "class Base\n  def initialize(a) = a\nend\nclass Sub < Base\n  def initialize(a) = a\nend\n"
    hook_sig = "class Base\n  def initialize: (Object) -> void\nend\nclass Sub\n  " \
               "def initialize: (Integer) -> void\nend\n"

    expect([fired(singleton, sig), fired(hook, hook_sig)]).to eq([[], []])
  end

  it "compares the parent at the type a generic subclass binds" do
    generic = "class Container\n  def put(a) = a\nend\nclass IntContainer < Container\n  def put(a) = a\nend\n"
    sig = "class Container[T]\n  def put: (T) -> Integer\nend\nclass IntContainer < Container[Object]\n  " \
          "def put: (Integer) -> Integer\nend\n"

    expect(fired(generic, sig).map(&:last)).to eq(
      ["parameter 1 of `put' narrowed from Object to Integer (overrides Container#put); breaks substitutability"]
    )
  end
end
