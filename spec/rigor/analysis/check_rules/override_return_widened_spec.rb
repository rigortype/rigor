# frozen_string_literal: true

require "spec_helper"

# ADR-116 WD1 / C4 — {CheckRules::OverrideReturnWidened.diagnostic} on a parsed snippet and its scope index, with no
# runner: the snippet's own `def`s give the project ancestry, and a signature file (`sig`) gives the RBS both sides of
# the comparison must carry. `override_and_return_type_spec.rb` pins the rule's builder through the whole run.
#
# Mutation-proved: each guard line of `diagnostic` and the helpers it owns was blanked in turn and an example here
# failed, except these, which no input here distinguishes (one line on what was tried each):
#
# - `return nil if resolved.nil?` and `return nil if override_return.nil? || parent_return.nil?`: a method whose RBS
#   has no method type does not exist, so `declared_return_union` never answers nil for a resolved override.
# - `return nil if OverrideSupport.dynamic_top?(parent_return)`: an `untyped` or `self` parent return is `Dynamic`,
#   whose `accepts` is never `no`, so the line after it declines every input this one does (the "untyped" and "self"
#   examples pin the behaviour, not the guard).
RSpec.describe Rigor::Analysis::CheckRules::OverrideReturnWidened do
  def defs_in(node, found = [])
    found << node if node.is_a?(Prism::DefNode)
    node.compact_child_nodes.each { |child| defs_in(child, found) }
    found
  end

  # `[line, message]` for each `def` of `source` the rule reports, against the signatures `sig`.
  def fired(source, sig)
    environment = Rigor::Environment.for_project(signature_paths: [RunnerHelpers.materialise_sig("demo.rbs" => sig)])
    program = Prism.parse(source).value
    scope_index = Rigor::Inference::ScopeIndexer.index(program,
                                                       default_scope: Rigor::Scope.empty(environment: environment))
    defs_in(program).filter_map do |def_node|
      row = described_class.diagnostic("mem.rb", def_node, scope_index)
      [def_node.location.start_line, row.message] if row
    end
  end

  let(:base_sub_source) do
    "class Base\n  def value = 1\nend\nclass Sub < Base\n  def value = Object.new\nend\n"
  end

  def sig_for(parent_return, override_return)
    "class Base\n  def value: () -> #{parent_return}\nend\nclass Sub < Base\n  " \
      "def value: () -> #{override_return}\nend\n"
  end

  it "reports an override whose declared return is wider than its parent's" do
    expect(fired(base_sub_source, sig_for("Integer", "Object"))).to eq(
      [[5, "return type of `value' widened from Integer to Object (overrides Base#value); breaks substitutability"]]
    )
  end

  it "reports at the method name, with the rule id, the warning severity and the method name" do
    environment = Rigor::Environment.for_project(
      signature_paths: [RunnerHelpers.materialise_sig("demo.rbs" => sig_for("Integer", "Object"))]
    )
    program = Prism.parse(base_sub_source).value
    scope_index = Rigor::Inference::ScopeIndexer.index(program,
                                                       default_scope: Rigor::Scope.empty(environment: environment))
    row = described_class.diagnostic("mem.rb", defs_in(program).last, scope_index)

    expect([row.rule, row.severity, row.method_name, row.line, row.column]).to eq(
      [Rigor::Analysis::CheckRules::RULE_OVERRIDE_RETURN_WIDENED, :warning, "value", 5, 7]
    )
  end

  it "is silent for a narrowing and for an identical return" do
    expect([fired(base_sub_source, sig_for("Object", "Integer")),
            fired(base_sub_source, sig_for("Integer", "Integer"))])
      .to eq([[], []])
  end

  it "is silent when the parent's return is `untyped`" do
    expect(fired(base_sub_source, sig_for("untyped", "Object"))).to eq([])
  end

  it "is silent when the parent's return is `self`, which both sides translate to `untyped`" do
    expect(fired(base_sub_source, sig_for("self", "Object"))).to eq([])
  end

  it "is silent for `void` over a parent that returns `nil`, and for `void` over `NilClass`" do
    expect([fired(base_sub_source, sig_for("nil", "void")), fired(base_sub_source, sig_for("NilClass", "void"))])
      .to eq([[], []])
  end

  it "reports `top` over `nil`, which is not `void`, and `void` over a non-nil parent" do
    expect([fired(base_sub_source, sig_for("nil", "top")).size,
            fired(base_sub_source, sig_for("Integer", "void")).size])
      .to eq([1, 1])
  end

  it "is silent when the override's own class declares no signature, only the inherited one" do
    sig = "class Base\n  def value: () -> Integer\nend\n"

    expect(fired(base_sub_source, sig)).to eq([])
  end

  it "is silent when the parent declares no signature" do
    sig = "class Sub\n  def value: () -> Object\nend\nclass Base\nend\n"

    expect(fired(base_sub_source, sig)).to eq([])
  end

  it "is silent for a singleton method" do
    source = "class Base\n  def self.value = 1\nend\nclass Sub < Base\n  def self.value = Object.new\nend\n"
    sig = "class Base\n  def self.value: () -> Integer\nend\nclass Sub\n  def self.value: () -> Object\nend\n"

    expect(fired(source, sig)).to eq([])
  end

  it "reports only the instance method when a singleton method of the same name is written beside it" do
    source = "class Base\n  def value = 1\n  def self.value = 1\nend\nclass Sub < Base\n  def value = Object.new\n  " \
             "def self.value = Object.new\nend\n"
    sig = "class Base\n  def value: () -> Integer\n  def self.value: () -> Integer\nend\nclass Sub < Base\n  " \
          "def value: () -> Object\n  def self.value: () -> Object\nend\n"

    expect(fired(source, sig).map(&:first)).to eq([6])
  end

  it "is silent when a project ancestor inherits the declaration from an RBS-only owner" do
    source = "class Mid < Array\nend\nclass Sub < Mid\n  def first = Object.new\nend\n"
    sig = "class Mid < Array[Integer]\nend\nclass Sub < Mid\n  def first: () -> Object\nend\n"

    expect(fired(source, sig)).to eq([])
  end

  it "is silent for the object-lifecycle hooks, which a parent-typed reference never calls" do
    names = %i[initialize initialize_copy initialize_dup initialize_clone]
    rows = names.map do |name|
      source = "class Base\n  def #{name}(*) = 1\nend\nclass Sub < Base\n  def #{name}(*) = Object.new\nend\n"
      sig = "class Base\n  def #{name}: (*untyped) -> Integer\nend\nclass Sub\n  " \
            "def #{name}: (*untyped) -> Object\nend\n"
      fired(source, sig)
    end

    expect(rows).to eq([[], [], [], []])
  end

  it "names an including module as the parent" do
    source = "module M\n  def value = 1\nend\nclass Sub\n  include M\n  def value = Object.new\nend\n"
    sig = "module M\n  def value: () -> Integer\nend\nclass Sub\n  include M\n  def value: () -> Object\nend\n"

    expect(fired(source, sig).map(&:last)).to eq(
      ["return type of `value' widened from Integer to Object (overrides M#value); breaks substitutability"]
    )
  end

  it "compares the parent at the type a generic subclass binds" do
    source = "class Container\n  def fetch = 1\nend\nclass IntContainer < Container\n  def fetch = Object.new\nend\n"
    sig = "class Container[T]\n  def fetch: () -> T\nend\nclass IntContainer < Container[Integer]\n  " \
          "def fetch: () -> Object\nend\n"

    expect(fired(source, sig).map(&:last)).to eq(
      ["return type of `fetch' widened from Integer to Object (overrides Container#fetch); breaks substitutability"]
    )
  end

  it "is silent for a generic parent bound to `untyped`" do
    source = "class Container\n  def fetch = 1\nend\nclass Sub < Container\n  def fetch = Object.new\nend\n"
    sig = "class Container[T]\n  def fetch: () -> T\nend\nclass Sub < Container[untyped]\n  " \
          "def fetch: () -> Object\nend\n"

    expect(fired(source, sig)).to eq([])
  end

  it "names the nearest ancestor that declares the method, past one that only inherits it" do
    source = "class Base\n  def value = 1\nend\nclass Mid < Base\nend\nclass Sub < Mid\n  def value = Object.new\nend\n"
    sig = "class Base\n  def value: () -> Integer\nend\nclass Mid < Base\nend\nclass Sub < Mid\n  " \
          "def value: () -> Object\nend\n"

    expect(fired(source, sig).map(&:last)).to eq(
      ["return type of `value' widened from Integer to Object (overrides Base#value); breaks substitutability"]
    )
  end

  it "answers with the nearest declaring ancestor when it overrides too" do
    source = "class Base\n  def value = 1\nend\nclass Mid < Base\n  def value = 1\nend\nclass Sub < Mid\n  " \
             "def value = Object.new\nend\n"
    sig = "class Base\n  def value: () -> Object\nend\nclass Mid < Base\n  def value: () -> Integer\nend\n" \
          "class Sub < Mid\n  def value: () -> Object\nend\n"

    expect(fired(source, sig).map do |row|
      [row.first, row.last[/overrides [^)]+/]]
    end).to eq([[8, "overrides Mid#value"]])
  end

  it "is silent when the declaration is inherited from an RBS-only owner the project chain does not hold" do
    source = "class Sub < Array\n  def first = Object.new\nend\n"
    sig = "class Sub < Array[Integer]\n  def first: () -> Object\nend\n"

    expect(fired(source, sig)).to eq([])
  end
end
