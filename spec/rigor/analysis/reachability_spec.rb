# frozen_string_literal: true

require "spec_helper"
require "rigor/analysis/reachability/scan"
require "rigor/analysis/reachability/graph"

# ADR-102 — the reachability report's reference index and mark-and-sweep.
#
# The #345 measurement found the typing path loses references in five distinct ways, and a report built on a
# lossy index reports live code as dead. Every one of those losses has a fixture here, each paired with a
# must-still-be-found case: a report that finds nothing would pass a suite of decline assertions alone.
RSpec.describe Rigor::Analysis::Reachability do
  # Builds a graph from `{path => source}` and returns the candidate FQNs.
  def candidates(files, roots: [])
    decls = []
    refs = []
    files.each do |path, source|
      result = Rigor::Analysis::Reachability::Scan.call(path: path, source: source)
      raise "fixture #{path} did not parse" if result.nil?

      decls.concat(result.declarations)
      refs.concat(result.references)
    end
    Rigor::Analysis::Reachability::Graph.new(declarations: decls, references: refs,
                                             root_fqns: roots).report.candidates.map(&:fqn)
  end

  describe "the index finds references the typing path loses (#345)" do
    it "sees a bare cross-file reference" do
      found = candidates({ "lib/a.rb" => "class Root\n  def go = Target.new\nend\n",
                           "lib/b.rb" => "class Target\nend\n" }, roots: ["Root"])
      expect(found).not_to include("Target")
    end

    # The case that separates real constant resolution from grep: `A::B::C` written as bare `C` inside `A::B`.
    it "resolves a nesting-relative reference to its fully-qualified declaration" do
      found = candidates({ "lib/a.rb" => <<~RUBY }, roots: ["A::B::Caller"])
        module A
          module B
            class C
            end
            class Caller
              def go = C.new
            end
          end
        end
      RUBY
      expect(found).not_to include("A::B::C")
    end

    it "sees a reference in a parameter-default expression" do
      found = candidates({ "lib/a.rb" => "class Root\n  def go(x = Target)\n    x\n  end\nend\n",
                           "lib/b.rb" => "class Target\nend\n" }, roots: ["Root"])
      expect(found).not_to include("Target")
    end

    it "sees a reference inside a lambda body that is a constant's rvalue" do
      found = candidates({ "lib/a.rb" => "class Root\n  BUILDER = -> { Target.new }\nend\n",
                           "lib/b.rb" => "class Target\nend\n" }, roots: ["Root"])
      expect(found).not_to include("Target")
    end

    it "sees a superclass position as a reference" do
      found = candidates({ "lib/a.rb" => "class Root < Base\nend\n",
                           "lib/b.rb" => "class Base\nend\n" }, roots: ["Root"])
      expect(found).not_to include("Base")
    end

    # A `ConstantPathNode`'s intermediate segments are not references in their own right — the leaf is the
    # reference. Recording each segment produced 22 spurious candidates in the #345 probe; NOT recording them
    # would instead report every namespace module as unused, which is what the namespace bucket handles.
    it "counts the leaf as the reference and buckets the namespaces it passes through" do
      decls = []
      refs = []
      { "lib/a.rb" => "class Root\n  def go = A::B::Leaf.new\nend\n",
        "lib/b.rb" => "module A\n  module B\n    class Leaf\n    end\n  end\nend\n" }.each do |path, source|
        result = Rigor::Analysis::Reachability::Scan.call(path: path, source: source)
        decls.concat(result.declarations)
        refs.concat(result.references)
      end
      report = Rigor::Analysis::Reachability::Graph.new(declarations: decls, references: refs,
                                                        root_fqns: ["Root"]).report

      expect(report.candidates.map(&:fqn)).to be_empty
      expect(report.namespaces).to eq(2) # A and A::B wrap live code; neither is a finding
    end

    # ... but a namespace whose entire contents are dead IS a finding, and is not explained away.
    it "still reports a namespace whose contents are all unreachable" do
      found = candidates({ "lib/a.rb" => "class Root\nend\n",
                           "lib/b.rb" => "module Dead\n  class Inner\n  end\nend\n" }, roots: ["Root"])
      expect(found).to include("Dead", "Dead::Inner")
    end
  end

  # The controls. Without these the suite above passes for a report that simply never fires.
  describe "the report still fires" do
    it "reports a declaration nothing references" do
      expect(candidates({ "lib/a.rb" => "class Root\nend\n", "lib/b.rb" => "class Orphan\nend\n" },
                        roots: ["Root"])).to include("Orphan")
    end

    # Mark-and-sweep, not reference counting: each of these has a reference, and both are still dead.
    it "reports a cluster of mutually-referencing dead classes" do
      dead = "class DeadA\n  def go = DeadB.new\nend\n" \
             "class DeadB\n  def go = DeadA.new\nend\n"
      found = candidates({ "lib/a.rb" => "class Root\nend\n", "lib/b.rb" => dead }, roots: ["Root"])
      expect(found).to include("DeadA", "DeadB")
    end
  end

  describe "roles (WD8)" do
    it "classifies a file's role from its path" do
      expect(Rigor::Analysis::Reachability::Scan.role_for("spec/foo_spec.rb")).to eq(:test)
      expect(Rigor::Analysis::Reachability::Scan.role_for("test/foo_test.rb")).to eq(:test)
      expect(Rigor::Analysis::Reachability::Scan.role_for("lib/tasks/thing.rake")).to eq(:task)
      expect(Rigor::Analysis::Reachability::Scan.role_for("config/initializers/x.rb")).to eq(:config)
      expect(Rigor::Analysis::Reachability::Scan.role_for("lib/app/thing.rb")).to eq(:production)
    end

    # Reachable only from test code is its own answer — neither a candidate nor silently "used".
    it "separates a test-only reachable declaration from both buckets" do
      decls = []
      refs = []
      { "lib/a.rb" => "class Root\nend\n",
        "lib/b.rb" => "class TestOnly\nend\n",
        "spec/b_spec.rb" => "TestOnly.new\n" }.each do |path, source|
        result = Rigor::Analysis::Reachability::Scan.call(path: path, source: source)
        decls.concat(result.declarations)
        refs.concat(result.references)
      end
      report = Rigor::Analysis::Reachability::Graph.new(declarations: decls, references: refs,
                                                        root_fqns: ["Root"]).report

      expect(report.candidates.map(&:fqn)).not_to include("TestOnly")
      expect(report.test_only.map(&:fqn)).to eq(["TestOnly"])
    end
  end

  describe "ownership (WD6)" do
    # Reopening a gem or stdlib class registers it as a project declaration; three of redmine's artifacts came
    # from one initializer doing exactly this.
    it "never reports a declaration the foreign predicate claims" do
      result = Rigor::Analysis::Reachability::Scan.call(path: "config/initializers/patches.rb",
                                                        source: "module RBS\n  class Location\n  end\nend\n")
      report = Rigor::Analysis::Reachability::Graph.new(
        declarations: result.declarations, references: result.references,
        foreign: ->(fqn) { fqn.start_with?("RBS") }
      ).report
      expect(report.candidates).to be_empty
      expect(report.declared).to be_zero
    end
  end

  describe "a reference to a member is a reference to its owner" do
    # `Scope::DiscoveryIndex::EMPTY` reads a constant inside a class. The leaf is not a declaration, so without
    # peeling the trailing segment the reference resolves to nothing and the owner reads as unused — which is
    # exactly what this report did to `Rigor::Scope::DiscoveryIndex` on its first run against Rigor's own lib.
    it "resolves a reference to a constant nested inside a class" do
      found = candidates({ "lib/a.rb" => "class Root\n  def go = Holder::EMPTY\nend\n",
                           "lib/b.rb" => "class Holder\n  EMPTY = 1\nend\n" }, roots: ["Root"])
      expect(found).not_to include("Holder")
    end
  end

  # ADR-102 WD4 — a constant reachable by a mechanism this reading cannot follow is reported as undecidable,
  # never folded into "unused" and never silently treated as used.
  describe "the cannot-decide tier (WD4)" do
    def report_for(files, roots: [])
      decls = []
      refs = []
      dyn = []
      files.each do |path, source|
        result = Rigor::Analysis::Reachability::Scan.call(path: path, source: source)
        decls.concat(result.declarations)
        refs.concat(result.references)
        dyn.concat(result.dynamic_uses)
      end
      Rigor::Analysis::Reachability::Graph.new(declarations: decls, references: refs, dynamic_uses: dyn,
                                               root_fqns: roots).report
    end

    # The case that proves the tier is not a blanket namespace poison: Rigor knows the argument's shape, so a
    # literal names the exact constant and is as good as a written reference.
    it "resolves a literal-argument constantize to the named constant and marks it reachable" do
      report = report_for({ "lib/a.rb" => %(class Root\n  def go = "Target".constantize\nend\n),
                            "lib/b.rb" => "class Target\nend\n" }, roots: ["Root"])
      expect(report.candidates.map(&:fqn)).not_to include("Target")
      expect(report.undecidable.map(&:fqn)).not_to include("Target")
    end

    it "resolves a literal const_get argument the same way" do
      report = report_for({ "lib/a.rb" => %(class Root\n  def go = Object.const_get("Target")\nend\n),
                            "lib/b.rb" => "class Target\nend\n" }, roots: ["Root"])
      expect(report.candidates.map(&:fqn)).to be_empty
    end

    it "demotes a namespace an interpolated constantize can reach, with a reason" do
      report = report_for({ "lib/a.rb" => %(class Root\n  def go(k) = "H::\#{k}".constantize\nend\n),
                            "lib/b.rb" => "module H\n  class Alpha\n  end\nend\n" }, roots: ["Root"])
      expect(report.candidates.map(&:fqn)).to be_empty
      expect(report.undecidable.map(&:fqn)).to include("H", "H::Alpha")
      expect(report.undecidable.first.reason).to include("interpolated string")
    end

    # An unbounded site taints nothing rather than everything: poisoning the whole project would empty the
    # report and teach the reader the tier means nothing.
    it "does not let an unbounded dynamic site poison the whole project" do
      report = report_for({ "lib/a.rb" => "class Root\n  def go(k) = k.constantize\nend\n",
                            "lib/b.rb" => "class Orphan\nend\n" }, roots: ["Root"])
      expect(report.candidates.map(&:fqn)).to eq(["Orphan"])
      expect(report.undecidable).to be_empty
    end
  end

  # A byte sequence that is not valid UTF-8 cannot be a constant name. Carrying one forward crashed the whole
  # run on the first `String#sub` downstream — `rigor unused` on Rigor's own repository, which vendors a CRuby
  # checkout containing deliberately ill-encoded encoding fixtures.
  describe "ill-encoded source" do
    # The real shape, taken from the file that crashed the run: a magic encoding comment makes Prism parse
    # SUCCESSFULLY and hand back an `unescaped` string tagged Big5 / ISO-8859-9 whose bytes are not valid
    # UTF-8. A source that merely fails to parse would not reproduce this — the scan already contributes
    # nothing for those.
    let(:ill_encoded) do
      (+"# encoding: big5\nx = \"\xA7\xA6\".constantize\n").force_encoding(Encoding::ASCII_8BIT)
    end

    it "parses, and contributes no dynamic use rather than raising" do
      result = nil
      expect { result = Rigor::Analysis::Reachability::Scan.call(path: "lib/a.rb", source: ill_encoded) }
        .not_to raise_error
      expect(result).not_to be_nil # the premise: this source DOES parse
      expect(result.dynamic_uses).to eq([])
    end

    # The control: a well-formed literal in the same position must still be recorded, or the guard above would
    # be indistinguishable from dropping every literal `constantize`.
    it "still records a well-formed literal constantize" do
      result = Rigor::Analysis::Reachability::Scan.call(path: "lib/a.rb", source: %(x = "Target".constantize\n))
      expect(result.dynamic_uses.map(&:name)).to eq(["Target"])
    end
  end

  describe "meta-new declarations" do
    it "treats a constant assigned Class.new / Data.define as a declaration" do
      found = candidates({ "lib/a.rb" => "class Root\nend\n",
                           "lib/b.rb" => "Shape = Data.define(:x)\nMade = Class.new(StandardError)\n" },
                         roots: ["Root"])
      expect(found).to include("Shape", "Made")
    end
  end
end
