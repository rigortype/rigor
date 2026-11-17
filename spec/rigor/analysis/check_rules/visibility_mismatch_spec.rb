# frozen_string_literal: true

require "spec_helper"

# ADR-116 WD1 / C4 — {CheckRules::VisibilityMismatch.diagnostic} on a parsed snippet and its scope index, with no
# runner. `runner_check_rules_spec.rb` and `remaining_rule_families_spec.rb` pin the rule through the whole run.
#
# The snippet is indexed against an empty scope, so a call is judged on what the snippet itself records: the discovery
# tables the indexer builds and the file's `LexicalMethodSites`, with no project RBS.
#
# Mutation-proved: each guard line of `diagnostic`, `instance_visibility_mismatch`, `singleton_visibility_mismatch`
# and the helpers below was blanked in turn and an example here failed, except these, which no input here
# distinguishes (one line on what was tried each):
#
# - `return nil if scope.nil?` in `diagnostic`: every call of an indexed snippet has a scope.
# - `ReceiverPredicates.inferred_param_receiver?`: true only for a parameter whose type the whole-project run infers
#   from its call sites; the one-file snippets tried (`def t(o) = o.x` with and without a caller) leave `o` untyped.
# - `return nil if reached == :undecided`: the next line, `return nil unless reached.nil? || reached == :private`,
#   declines `:undecided` too; no input reaches the first line alone.
# - `return nil unless private_singleton_candidate?`: a table-only gate ahead of the chain read, whose observable
#   effect is the dependency edges the skipped read would file; the verdict is the same (the gate and its memo are
#   pinned directly under "the private-name set").
# - `return nil if singleton_wildcard_contested?`: `K.public_class_method(*names)`, `K.singleton_class.class_eval { }`
#   and the same on a subclass were tried; each already makes the reached definer `:undecided`.
# - `return true if rows.nil?` in `load_time_call?`: the indexer gives every snippet a row list, empty when it has no
#   `def`, so the table is never nil.
# - `return true if chain.truncated?` and `next false if entry.external?` in `missing_hook_on_chain?`: a 101-class chain
#   is declined earlier, by the reached definer; an external entry records no hook either way.
# - `return false if receiver.nil?` in `explicit_non_self_receiver?`: an implicit-self call has no receiver type, so
#   the dispatch on it picks neither branch.
RSpec.describe Rigor::Analysis::CheckRules::VisibilityMismatch do
  def calls_in(node, found = [])
    found << node if node.is_a?(Prism::CallNode)
    node.compact_child_nodes.each { |child| calls_in(child, found) }
    found
  end

  # `[line, message]` for each call of `source` the rule reports.
  def fired(source)
    program = Prism.parse(source).value
    scope_index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
    sites = Rigor::Analysis::CheckRules::LexicalMethodSites.new(program)
    calls_in(program).filter_map do |call|
      facts = Rigor::Analysis::CheckRules::CallFacts.new(call, scope_index)
      row = described_class.diagnostic("mem.rb", call, facts, sites)
      [call.location.start_line, row.message] if row
    end
  end

  def scope_of(source)
    program = Prism.parse(source).value
    scope_index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
    scope_index[calls_in(program).last]
  end

  describe "an instance receiver" do
    it "reports a call to a method made private with `private :name`" do
      rows = fired("class A\n  def x = 1\n  private :x\nend\nA.new.x\n")

      expect(rows).to eq([[5, "private method `x' called on A receiver"]])
    end

    it "reports a call to a method defined under a bare `private`" do
      expect(fired("class A\n  private\n  def x = 1\nend\nA.new.x\n").map(&:first)).to eq([5])
    end

    it "reports a call to a method defined by `private def`" do
      expect(fired("class A\n  private def x = 1\nend\nA.new.x\n").map(&:first)).to eq([4])
    end

    it "reports the call inside a method body too" do
      expect(fired("class A\n  def x = 1\n  private :x\nend\ndef t = A.new.x\n").map(&:first)).to eq([5])
    end

    it "carries the rule id, the error severity, the receiver type and the method name" do
      program = Prism.parse("class A\n  def x = 1\n  private :x\nend\nA.new.x\n").value
      scope_index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
      call = calls_in(program).find { |c| c.name == :x && c.receiver }
      row = described_class.diagnostic("mem.rb", call, Rigor::Analysis::CheckRules::CallFacts.new(call, scope_index))

      expect([row.rule, row.severity, row.receiver_type, row.method_name, row.path, row.line]).to eq(
        [Rigor::Analysis::CheckRules::RULE_VISIBILITY_MISMATCH, :error, "A", "x", "mem.rb", 5]
      )
    end

    it "is silent for a public method" do
      expect(fired("class A\n  def x = 1\nend\nA.new.x\n")).to eq([])
    end

    it "is silent for a protected method" do
      expect(fired("class A\n  def x = 1\n  protected :x\nend\nA.new.x\n")).to eq([])
    end

    it "is silent for an implicit-self call and for `self.x`" do
      expect(fired("class A\n  def x = 1\n  private :x\n  def t = [x, self.x]\nend\n")).to eq([])
    end

    it "is silent for a method nothing records" do
      expect(fired("class A\nend\nA.new.zzz\n")).to eq([])
    end

    it "is silent when a prepended module defines the name publicly ahead of the private one" do
      source = "module P\n  def x = 1\nend\nclass A\n  prepend P\n  def x = 1\n  private :x\nend\nA.new.x\n"

      expect(fired(source)).to eq([])
    end

    it "is silent for a subclass whose own table does not record the name (the own-table gate)" do
      expect(fired("class A\n  def x = 1\n  private :x\nend\nclass B < A; end\nB.new.x\n")).to eq([])
    end

    it "is silent when the subclass makes the name public again" do
      source = "class A\n  def x = 1\n  private :x\nend\nclass B < A\n  public\n  def x = 2\nend\nB.new.x\n"

      expect(fired(source)).to eq([])
    end

    it "is silent when the class defines `method_missing`, which Ruby sends a private call to" do
      source = "class A\n  def x = 1\n  private :x\n  def method_missing(n, *) = 1\nend\nA.new.x\n"

      expect(fired(source)).to eq([])
    end

    it "is silent when the class defines `respond_to_missing?`" do
      source = "class A\n  def x = 1\n  private :x\n  def respond_to_missing?(n, p = false) = true\nend\nA.new.x\n"

      expect(fired(source)).to eq([])
    end

    it "is silent when a refinement in effect may redefine the method publicly" do
      source = "class A\n  def x = 1\n  private :x\nend\nmodule R\n  refine A do\n    def x = 2\n  end\nend\n" \
               "using R\nA.new.x\n"

      expect(fired(source)).to eq([])
    end

    it "is silent for a union receiver, which has no single class identity" do
      source = "class A\n  def x = 1\n  private :x\nend\nclass B\n  def x = 1\nend\n" \
               "def t(f)\n  o = f ? A.new : B.new\n  o.x\nend\n"

      expect(fired(source)).to eq([])
    end
  end

  describe "a class-object receiver" do
    it "reports a `private_class_method` call from inside a method" do
      source = "class A\n  def self.k = 1\n  private_class_method :k\nend\ndef t = A.k\n"

      expect(fired(source)).to eq([[5, "private method `k' called on singleton(A) receiver"]])
    end

    it "reports a method made private under `class << self`" do
      source = "class A\n  class << self\n    private\n    def k = 1\n  end\nend\ndef t = A.k\n"

      expect(fired(source).map(&:first)).to eq([7])
    end

    it "reports through an inheriting class, naming the receiver's own class" do
      source = "class A\n  def self.k = 1\n  private_class_method :k\nend\nclass B < A; end\ndef t = B.k\n"

      expect(fired(source)).to eq([[6, "private method `k' called on singleton(B) receiver"]])
    end

    it "reports a private method of an extended module" do
      source = "module M\n  def k = 1\n  private :k\nend\nclass A\n  extend M\nend\ndef t = A.k\n"

      expect(fired(source).map(&:first)).to eq([8])
    end

    it "is silent when a refinement of the singleton class is in effect" do
      source = "class A\n  def self.k = 1\n  private_class_method :k\nend\nmodule R\n  " \
               "refine A.singleton_class do\n    " \
               "def k = 2\n  end\nend\nusing R\ndef t = A.k\n"

      expect(fired(source)).to eq([])
    end

    it "is silent at load time, outside every `def`" do
      expect(fired("class A\n  def self.k = 1\n  private_class_method :k\nend\nA.k\n")).to eq([])
    end

    it "is silent when the receiver is a local that may hold a subclass" do
      source = "class A\n  def self.k = 1\n  private_class_method :k\nend\ndef t\n  c = A\n  c.k\nend\n"

      expect(fired(source)).to eq([])
    end

    it "is silent when `public_class_method` makes the name public again" do
      source = "class A\n  def self.k = 1\n  private_class_method :k\n  public_class_method :k\nend\ndef t = A.k\n"

      expect(fired(source)).to eq([])
    end

    it "is silent when a `public_class_method(*names)` may have made every singleton name public" do
      source = "class A\n  def self.k = 1\n  private_class_method :k\n  public_class_method(*names)\nend\ndef t = A.k\n"

      expect(fired(source)).to eq([])
    end

    it "is silent when the class defines a singleton `method_missing`" do
      source = "class A\n  def self.k = 1\n  private_class_method :k\n  def self.method_missing(n, *) = 1\nend\n" \
               "def t = A.k\n"

      expect(fired(source)).to eq([])
    end

    it "is silent at load time in a file that defines no method at all" do
      source = "class A\n  class << self\n    private\n    attr_reader :k\n  end\nend\nA.k\n"

      expect(fired(source)).to eq([])
    end

    it "is silent when another class records the name private but the receiver's own definition is public" do
      source = "class A\n  def self.k = 1\n  private_class_method :k\nend\nclass B\n  def self.k = 1\nend\n" \
               "def t = B.k\n"

      expect(fired(source)).to eq([])
    end

    it "is silent when `define_singleton_method` defines the singleton hook" do
      source = "class A\n  def self.k = 1\n  private_class_method :k\n  " \
               "define_singleton_method(:method_missing) { |*| 1 }\nend\ndef t = A.k\n"

      expect(fired(source)).to eq([])
    end

    it "reads a chain of 99 classes, and declines one the walk limit truncates (101)" do
      chain = lambda do |count|
        (1..count).map { |n| "class C#{n} < #{n == 1 ? 'Object' : "C#{n - 1}"}; end\n" }.join
          .sub("class C1 < Object; end", "class C1\n  def self.k = 1\n  private_class_method :k\nend") +
          "def t = C#{count}.k\n"
      end

      expect([fired(chain.call(99)).size, fired(chain.call(101)).size]).to eq([1, 0])
    end

    it "is silent for a name no class records private" do
      expect(fired("class A\n  def self.k = 1\nend\ndef t = A.k\n")).to eq([])
    end
  end

  describe "the private-name set" do
    it "collects the names recorded :private on either side, whatever the slot's shape" do
      tables = { "A" => { x: :private, y: :public, %i[singleton k] => :private, %i[instance z] => :protected },
                 "B" => { w: :private } }

      expect(described_class.send(:private_recorded_names, tables)).to eq(Set[:x, :k, :w])
    end

    it "is memoised per discovery index, and recomputed for another" do
      one = scope_of("class A\n  def x = 1\n  private :x\nend\nA.new.x\n")
      other = scope_of("class B\n  def y = 1\n  private :y\nend\nB.new.y\n")

      expect([one, other, one].map { |scope| described_class.send(:private_singleton_candidate?, scope, :x) })
        .to eq([true, false, true])
    end
  end

  describe "the reached definer" do
    it "answers nil when nothing on the chain records the name" do
      scope = scope_of("class A\n  def x = 1\nend\nA.new.x\n")

      expect(described_class.send(:reached_definer_visibility, scope, "A", :nope)).to be_nil
    end

    it "answers the recorded visibility of the definition a call reaches" do
      scope = scope_of("class A\n  def x = 1\n  private :x\nend\nA.new.x\n")

      expect(described_class.send(:reached_definer_visibility, scope, "A", :x)).to eq(:private)
    end
  end
end
