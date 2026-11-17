# frozen_string_literal: true

require "spec_helper"

# ADR-116 WD1 / C4 — {CheckRules::OverrideVisibility.diagnostic} on a parsed snippet and its scope index, with no
# runner. `override_and_return_type_spec.rb` pins the rule's builder through the whole run.
#
# Mutation-proved: each guard line of `diagnostic` and its helpers was blanked in turn and an example here failed,
# except these, which no input here distinguishes (one line on what was tried each):
#
# - `return nil if scope.nil?`: every `def` of an indexed snippet has a scope.
# - `return nil unless self_type.respond_to?(:class_name)`: a `def` at the top level, in a class body and in
#   `class << self` all have a nominal or singleton self type.
# - `return nil if override_visibility.nil?`: a `def` the walk does not place has no row, and then no ancestor answer
#   below fires either; the next guards decline it.
# - `return nil if parent.nil?`, `return nil if parent_visibility.nil?` and the nil ranks in `visibility_reduced?`:
#   each is covered by the next (`nil, nil = nil` leaves both nil, and a nil rank is no reduction); the `:unrecorded`
#   marker needs an ancestor that defines the name with no table row, which a one-file snippet does not produce.
# - `return nil if from.nil?` in `nearest_ancestor_visibility`: a class absent from its own chain; the snippet's
#   classes are all on it.
# - `next unless scope.user_def_for(ancestor, method_name)` in `nearest_ancestor_visibility`: the walk asks only
#   project ancestors that define the name, so the answer block is never reached for another.
RSpec.describe Rigor::Analysis::CheckRules::OverrideVisibility do
  def defs_in(node, found = [])
    found << node if node.is_a?(Prism::DefNode)
    node.compact_child_nodes.each { |child| defs_in(child, found) }
    found
  end

  # `[line, message]` for each `def` of `source` the rule reports.
  def fired(source)
    program = Prism.parse(source).value
    scope_index = Rigor::Inference::ScopeIndexer.index(program,
                                                       default_scope: Rigor::Scope.empty(source_path: "mem.rb"))
    defs_in(program).filter_map do |def_node|
      row = described_class.diagnostic("mem.rb", def_node, scope_index)
      [def_node.location.start_line, row.message] if row
    end
  end

  it "reports a method made private under a bare `private` over a public parent method" do
    source = "class A\n  def x = 1\nend\nclass B < A\n  private\n  def x = 1\nend\n"

    expect(fired(source)).to eq(
      [[6, "visibility of `x' reduced from public to private (overrides A#x); breaks substitutability"]]
    )
  end

  it "reports a method made private by `private :name`" do
    expect(fired("class A\n  def x = 1\nend\nclass B < A\n  def x = 1\n  private :x\nend\n").map(&:first)).to eq([5])
  end

  it "reports public to protected" do
    source = "class A\n  def x = 1\nend\nclass B < A\n  protected\n  def x = 1\nend\n"

    expect(fired(source).map(&:last)).to eq(
      ["visibility of `x' reduced from public to protected (overrides A#x); breaks substitutability"]
    )
  end

  it "reports protected to private" do
    source = "class A\n  protected\n  def x = 1\nend\nclass B < A\n  private\n  def x = 1\nend\n"

    expect(fired(source).map(&:last)).to eq(
      ["visibility of `x' reduced from protected to private (overrides A#x); breaks substitutability"]
    )
  end

  it "names an including module as the parent when it is the nearest definer" do
    source = "module M\n  def x = 1\nend\nclass B\n  include M\n  private\n  def x = 1\nend\n"

    expect(fired(source).map(&:last)).to eq(
      ["visibility of `x' reduced from public to private (overrides M#x); breaks substitutability"]
    )
  end

  it "reports at the method name, with the rule id, the warning severity and the method name" do
    program = Prism.parse("class A\n  def x = 1\nend\nclass B < A\n  private\n  def x = 1\nend\n").value
    scope_index = Rigor::Inference::ScopeIndexer.index(program,
                                                       default_scope: Rigor::Scope.empty(source_path: "mem.rb"))
    row = described_class.diagnostic("mem.rb", defs_in(program).last, scope_index)

    expect([row.rule, row.severity, row.method_name, row.line, row.column]).to eq(
      [Rigor::Analysis::CheckRules::RULE_OVERRIDE_VISIBILITY_REDUCED, :warning, "x", 6, 7]
    )
  end

  it "is silent when the override widens or keeps the visibility" do
    source = "class A\n  private\n  def x = 1\nend\nclass B < A\n  def x = 1\nend\n"

    expect(fired(source)).to eq([])
  end

  it "is silent for a method no ancestor defines" do
    expect(fired("class A\n  def y = 1\nend\nclass B < A\n  private\n  def x = 1\nend\n")).to eq([])
  end

  it "is silent for a singleton method" do
    expect(fired("class A\n  def self.x = 1\nend\nclass B < A\n  private\n  def self.x = 1\nend\n")).to eq([])
  end

  it "is silent for `initialize`, which CRuby makes private whatever the section says" do
    source = "class A\n  def initialize = 1\nend\nclass B < A\n  private\n  def initialize = 1\nend\n"

    expect(fired(source)).to eq([])
  end

  it "is silent for `respond_to_missing?`, private for the same reason" do
    source = "class A\n  def respond_to_missing?(*) = 1\nend\nclass B < A\n  private\n  " \
             "def respond_to_missing?(*) = 1\nend\n"

    expect(fired(source)).to eq([])
  end

  it "reports only the instance method when a singleton method of the same name is written beside it" do
    source = "class A\n  def x = 1\nend\nclass B < A\n  private\n  def x = 1\n  public\n  def self.x = 1\nend\n"

    expect(fired(source).map(&:first)).to eq([6])
  end

  it "is silent when a later `define_method` gives the name another visibility" do
    source = "class A\n  def x = 1\nend\nclass B < A\n  def x = 1\n  private :x\n  define_method(:x) { 1 }\nend\n"

    expect(fired(source)).to eq([])
  end

  it "is silent when a later `alias_method` redefines the name" do
    source = "class A\n  def x = 1\nend\nclass B < A\n  def x = 1\n  def y = 1\n  private :x\n  " \
             "alias_method :x, :y\nend\n"

    expect(fired(source)).to eq([])
  end

  it "is silent when the `private :name` is conditional, a write the walk cannot place" do
    source = "class A\n  def x = 1\nend\nclass B < A\n  def x = 1\n  private :x if cond\nend\n"

    expect(fired(source)).to eq([])
  end

  it "is silent for the private instance copy `module_function` makes" do
    source = "module M\n  def x = 1\nend\nmodule N\n  include M\n  module_function\n  def x = 1\nend\n"

    expect(fired(source)).to eq([])
  end

  it "answers from the prepended module, not the class, when both define the name" do
    source = "module P\n  def x = 1\nend\nclass C\n  prepend P\n  private\n  def x = 1\nend\n"

    expect(fired(source)).to eq([])
  end

  it "names the IMPLICITLY_PRIVATE_METHODS the lifecycle hooks and `respond_to_missing?` make up" do
    expect(described_class::IMPLICITLY_PRIVATE_METHODS)
      .to eq(%i[initialize initialize_copy initialize_dup initialize_clone respond_to_missing?])
  end

  it "ranks public above protected above private, and shares them frozen" do
    expect([described_class::VISIBILITY_RANK, described_class::VISIBILITY_RANK.frozen?])
      .to eq([{ public: 2, protected: 1, private: 0 }, true])
  end
end
