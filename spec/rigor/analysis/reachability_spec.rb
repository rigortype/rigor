# frozen_string_literal: true

require "spec_helper"
require "rigor/analysis/reachability/scan"
require "rigor/analysis/reachability/graph"
require "rigor/analysis/reachability/signature_scan"

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

    # #1751 — end-to-end trees are test code; tooling trees and same-named namespace dirs are not.
    it "reads end-to-end trees as test and leaves tooling and nested namespace directories alone" do
      role = ->(path) { Rigor::Analysis::Reachability::Scan.role_for(path) }
      expect(%w[qa/qa/page/login.rb e2e/support/helper.rb features/step_definitions/a.rb ./qa/x.rb].map(&role))
        .to all(eq(:test))
      expect(%w[rubocop/cop/a.rb keeps/k.rb tooling/t.rb scripts/s.rb metrics_server/m.rb
                app/models/features/flag.rb lib/qa/runner.rb].map(&role)).to all(eq(:production))
    end

    # The CLI hands the scan ABSOLUTE paths, so the role must be decided against the project root: a rule
    # anchored on the absolute path never fires for qa/, and an unanchored one fires on any directory above
    # the project (a checkout under ~/src/test/myapp).
    it "decides the role from the path relative to the project root" do
      scan = lambda do |root, rel|
        Rigor::Analysis::Reachability::Scan.call(path: "#{root}/#{rel}", source: "class A\n  B.new\nend\n", root: root)
                                           .references.first.role
      end
      expect(scan.call("/home/me/proj", "qa/page.rb")).to eq(:test)
      expect(scan.call("/home/me/proj", "e2e/x.rb")).to eq(:test)
      expect(scan.call("/home/me/proj", "spec/x_spec.rb")).to eq(:test)
      expect(scan.call("/home/me/proj", "lib/a.rb")).to eq(:production)
      expect(scan.call("/home/me/test/proj", "lib/a.rb")).to eq(:production)
      expect(scan.call("/home/me/spec/proj", "config/a.rb")).to eq(:config)
      expect(scan.call("/home/me/qa/proj", "lib/a.rb")).to eq(:production)
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
    def report_for(files, roots: [], dynamic: [])
      decls = []
      refs = []
      dyn = dynamic.dup
      files.each do |path, source|
        result = Rigor::Analysis::Reachability::Scan.call(path: path, source: source)
        decls.concat(result.declarations)
        refs.concat(result.references)
        dyn.concat(result.dynamic_uses)
      end
      Rigor::Analysis::Reachability::Graph.new(declarations: decls, references: refs, dynamic_uses: dyn,
                                               root_fqns: roots).report
    end

    # What `CLI::UnusedCommand#template_mentions` contributes for a name found in a `.yml` / `.json` /
    # template: a prefix with no exact name, which is what makes it evidence rather than a reference.
    def dynamic_mention(fqn, file)
      Rigor::Analysis::Reachability::Scan::DynamicUse.new(
        name: nil, prefix: fqn, site: nil, reason: "named as a string in #{file}", path: file, line: 1,
        scope: :exact
      )
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

    # #370 — the tier contract says a data-file mention "MUST demote to this tier", and the sweep asked
    # only about the UNREACHED, so a declaration a spec references and a scheduler config names kept its
    # evidence discarded and landed under "live test, dead production path". That heading is an assertion
    # about production; a `config/recurring.yml` entry is evidence against it.
    it "demotes a test-only declaration that a data file also names" do
      report = report_for(
        { "app/jobs/reminder_job.rb" => "class ReminderJob\nend\n",
          "spec/jobs/reminder_job_spec.rb" => "ReminderJob\n" },
        dynamic: [dynamic_mention("ReminderJob", "config/recurring.yml")]
      )

      expect(report.test_only.map(&:fqn)).not_to include("ReminderJob")
      row = report.undecidable.find { |u| u.fqn == "ReminderJob" }
      expect(row).not_to be_nil
      expect(row.reason).to include("config/recurring.yml")
    end

    # The control, and the reason the example above is not merely "the tier swallowed a row": the SAME
    # declaration with no data-file mention still reports as test-only, which is the answer that section
    # exists to give.
    it "keeps a test-only declaration with no data-file mention in the test-only section" do
      report = report_for(
        { "app/jobs/reminder_job.rb" => "class ReminderJob\nend\n",
          "spec/jobs/reminder_job_spec.rb" => "ReminderJob\n" }
      )

      expect(report.test_only.map(&:fqn)).to eq(["ReminderJob"])
      expect(report.undecidable).to be_empty
    end

    # #370 — the two kinds of weak evidence are not the same shape, and conflating them is what made the
    # fix above dangerous before this. An interpolated `constantize` can CONSTRUCT any name under its
    # literal head, so it taints descendants; a data file merely CONTAINS a name, which says nothing about
    # that name's children. Read as a namespace taint, one Afrikaans word ("Administrasie" contains
    # "Admin") demoted 18 unrelated `Admin::*` rows on Mastodon, and the word "Redmine" in a YAML file
    # demoted 47 `Redmine::*` rows out of `candidates`.
    it "taints only the named declaration for a data-file mention, not its children" do
      report = report_for(
        { "app/admin.rb" => "module Admin\nend\n",
          "app/admin/policy.rb" => "module Admin\n  class Policy\n  end\nend\n" },
        dynamic: [dynamic_mention("Admin", "config/locales/af.yml")]
      )

      expect(report.undecidable.map(&:fqn)).to eq(["Admin"])
      expect(report.candidates.map(&:fqn)).to include("Admin::Policy")
    end

    # The control for the rule above: an interpolated site keeps tainting the whole namespace, because it
    # can genuinely build any of those names.
    it "still taints descendants for an interpolated constantize" do
      report = report_for({ "lib/a.rb" => %(class Root\n  def go(k) = "Admin::\#{k}".constantize\nend\n),
                            "lib/b.rb" => "module Admin\n  class Policy\n  end\nend\n" }, roots: ["Root"])

      expect(report.undecidable.map(&:fqn)).to include("Admin", "Admin::Policy")
    end

    # An unbounded site taints nothing rather than everything: poisoning the whole project would empty the
    # report and teach the reader the tier means nothing.
    it "does not let an unbounded dynamic site poison the whole project" do
      report = report_for({ "lib/a.rb" => "class Root\n  def go(k) = k.constantize\nend\n",
                            "lib/b.rb" => "class Orphan\nend\n" }, roots: ["Root"])
      expect(report.candidates.map(&:fqn)).to eq(["Orphan"])
      expect(report.undecidable).to be_empty
    end

    # Issue #1734 — an interpolated `const_get` reaches into its receiver's namespace, and an implicit
    # receiver is the enclosing declaration. GitLab's `Migration[2.2]` builds the name one line up and looks it
    # up with `inherit = false`; nothing marked the `V*` family, so every version was a false candidate.
    describe "an interpolated const_get taints the receiver's namespace (#1734)" do
      let(:migration) do
        <<~RUBY
          module Gitlab
            module Database
              class Migration
                class V1_0; end
                class V2_0 < V1_0; end
                class Helper; end

                def self.[](version)
                  version = version.to_s
                  name = "V\#{version.tr('.', '_')}"
                  raise ArgumentError, "Unknown migration version: \#{version}" unless const_defined?(name, false)

                  const_get(name, false)
                end
              end
            end
          end
          class V9; end
        RUBY
      end

      it "demotes the members whose name starts with the literal head (the GitLab Migration[...] shape)" do
        report = report_for({ "lib/migration.rb" => migration,
                              "lib/main.rb" => "Gitlab::Database::Migration[2.2]\n" })
        expect(report.undecidable.to_h { [it.fqn, it.reason] })
          .to include("Gitlab::Database::Migration::V1_0" => a_string_including("const_get on an interpolated string"),
                      "Gitlab::Database::Migration::V2_0" => a_string_including("lib/migration.rb:13"))
        # A member the head cannot spell stays a candidate, and `inherit = false` keeps the lookup out of the
        # top level.
        expect(report.candidates.map(&:fqn)).to eq(%w[Gitlab::Database::Migration::Helper V9])
      end

      it "reads an inline interpolation the same way, and falls through to the top level by default" do
        report = report_for({ "lib/a.rb" => <<~RUBY, "lib/main.rb" => "Reg.for(1)\n" })
          class Reg
            class V1; end
            class Other; end
            def self.for(v) = const_get("V\#{v}")
          end
          class V9; end
          class W9; end
        RUBY
        expect(report.undecidable.map(&:fqn)).to contain_exactly("Reg::V1", "V9")
        expect(report.candidates.map(&:fqn)).to eq(%w[Reg::Other W9])
      end

      it "resolves a constant receiver against the call site's nesting" do
        report = report_for({ "lib/a.rb" => <<~RUBY, "lib/main.rb" => "Ns::Reg.for(1)\n" })
          module Ns
            module Handlers
              class HAlpha; end
              class Other; end
            end
            class Reg
              def self.for(k) = Handlers.const_get("H\#{k}", false)
            end
          end
        RUBY
        expect(report.undecidable.map(&:fqn)).to eq(["Ns::Handlers::HAlpha"])
        expect(report.candidates.map(&:fqn)).to eq(["Ns::Handlers::Other"])
      end

      # `Foo::Bar` declares nothing itself, so resolving it peels to `Foo`; anchoring there alone would look
      # for `Foo::V*` and miss the member the call can reach. An undeclared receiver may be an alias of
      # either, so both anchors stay.
      it "anchors at the written receiver as well when only part of it resolves" do
        report = report_for({ "lib/a.rb" => "module Foo; end\nclass Foo::Bar::V1; end\nclass Foo::V2; end\n" \
                                            "Foo::Bar.const_get(\"V\#{ARGV.first}\")\n" })
        expect(report.undecidable.map(&:fqn)).to contain_exactly("Foo::Bar::V1", "Foo::V2")
      end

      # A block parameter shadows the method's local: the literal assigned outside the block is not what the
      # block passes, and reading it as a reference hid a dead constant only that literal named.
      it "reads a name a block parameter or block-local shadows as a computed value" do
        report = report_for({ "lib/a.rb" => <<~RUBY })
          class TopLit; end
          class LocalLit; end
          module Shadow
            def self.go(list)
              name = "TopLit"
              list.each { |name| const_get(name) }
              other = "LocalLit"
              list.each { |x; other| const_get(other) }
            end
          end
          Shadow.go([])
        RUBY
        expect(report.candidates.map(&:fqn)).to eq(%w[LocalLit TopLit])
      end

      # A head that does not end in `::` is the start of a name for `constantize` too, which reaches the
      # top level only.
      it "taints every top-level name an interpolated constantize head starts" do
        decls = "class SubAlpha; end\nclass Sub; end\nmodule Ns\n  class SubBeta; end\nend\n"
        report = report_for({ "lib/a.rb" => "class Root\n  def go(k) = \"Sub\#{k}\".constantize\nend\n",
                              "lib/b.rb" => decls }, roots: ["Root"])
        expect(report.undecidable.map(&:fqn)).to contain_exactly("Sub", "SubAlpha")
        expect(report.candidates.map(&:fqn)).to eq(%w[Ns Ns::SubBeta])
      end
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

  # Issue #373 — a class must not root itself through its own signature. The scan records a name as written
  # with its nesting; hand-building the qualified form instead produced `SignageResource::Alba::Resource`,
  # which `resolve` peels to its owner (a reference to a member is a reference to its owner) and so rooted
  # `SignageResource`. On the project where this was found it hid three genuinely dead classes.
  describe "signature references do not root their own declaration" do
    it "leaves a class declared only in its own signature as a candidate" do
      source = Rigor::Analysis::Reachability::Scan.call(
        path: "app/resources/signage_resource.rb",
        source: "class SignageResource\n  include Alba::Resource\nend\n"
      )
      root = Rigor::Analysis::Reachability::Scan.call(path: "lib/root.rb", source: "class Root\nend\n")
      signature = Rigor::Analysis::Reachability::SignatureScan.call(
        File.join(__dir__, "..", "..", "fixtures", "signage_resource.rbs")
      )

      report = Rigor::Analysis::Reachability::Graph.new(
        declarations: source.declarations + root.declarations,
        references: source.references + root.references + signature,
        root_fqns: ["Root"]
      ).report

      expect(report.candidates.map(&:fqn)).to include("SignageResource")
    end
  end

  # Issue #1720 — a superclass (or a meta-new rvalue's argument) is part of the subclass's declaration, so the
  # edge to the base leaves the SUBCLASS. Crediting the enclosing scope instead left a base nested in a module
  # that is never reached itself unreachable, and rooted a top-level base even when every subclass was dead.
  describe "a superclass reference is credited to the subclass (#1720)" do
    # `declared:` mirrors `rigor unused`'s split: declarations come from `paths:` only, references from every
    # file. Defaults to every file declaring.
    def report_for(files, roots: [], declared: files.keys)
      decls = []
      refs = []
      uses = []
      files.each do |path, source|
        result = Rigor::Analysis::Reachability::Scan.call(path: path, source: source)
        raise "fixture #{path} did not parse" if result.nil?

        decls.concat(result.declarations) if declared.include?(path)
        refs.concat(result.references)
        uses.concat(result.dynamic_uses)
      end
      Rigor::Analysis::Reachability::Graph.new(declarations: decls, references: refs, root_fqns: roots,
                                               dynamic_uses: uses).report
    end

    let(:hierarchy) do
      <<~RUBY
        class Base; end
        class Child < Base; end

        module Outer
          class OBase; end
          class OChild < OBase; end
        end
      RUBY
    end

    it "reaches a base nested in a namespace through its reachable subclass" do
      report = report_for({ "lib/a.rb" => hierarchy, "lib/main.rb" => "Child.new\nOuter::OChild.new\n" })
      expect(report.candidates.map(&:fqn)).to be_empty
    end

    it "reports a top-level base whose only subclass is dead" do
      report = report_for({ "lib/a.rb" => hierarchy, "lib/main.rb" => "Outer::OChild.new\n" })
      expect(report.candidates.map(&:fqn)).to eq(%w[Base Child])
    end

    it "reports a nested base whose only subclass is dead" do
      report = report_for({ "lib/a.rb" => hierarchy, "lib/main.rb" => "Child.new\n" })
      expect(report.candidates.map(&:fqn)).to eq(%w[Outer Outer::OBase Outer::OChild])
    end

    it "resolves the superclass against the outer nesting, not the subclass's body" do
      result = Rigor::Analysis::Reachability::Scan.call(path: "lib/a.rb", source: hierarchy)
      superclass = result.references.find { |ref| ref.as_written == "OBase" }
      expect([superclass.from, superclass.nesting]).to eq(["Outer::OChild", ["Outer"]])
    end

    it "credits a meta-new rvalue's arguments and block to the declared constant" do
      source = <<~RUBY
        class LiveBase; end
        class DeadBase; end
        class Helper; end
        module Ns
          Live = Class.new(LiveBase) do
            def go = Helper.new
          end
          Dead = Class.new(DeadBase)
        end
      RUBY
      report = report_for({ "lib/a.rb" => source, "lib/main.rb" => "Ns::Live.new\n" })
      expect(report.candidates.map(&:fqn)).to eq(%w[DeadBase Ns::Dead])
    end

    it "does not leak a meta-new credit into a class declared inside its block" do
      result = Rigor::Analysis::Reachability::Scan.call(path: "lib/a.rb", source: <<~RUBY)
        Made = Class.new do
          class Inner
            def go = Target.new
          end
        end
      RUBY
      expect(result.references.find { |ref| ref.as_written == "Target" }.from).to eq("Inner")
    end

    it "reaches a base named by any one opening of a reopened subclass" do
      report = report_for({ "lib/a.rb" => "class Base; end\nclass Child < Base; end\n",
                            "lib/b.rb" => "class Child\n  def go = 1\nend\n",
                            "lib/main.rb" => "Child.new\n" })
      expect(report.candidates.map(&:fqn)).to be_empty
    end

    # A subclass declared outside `paths:` is not a node, so its liveness cannot be judged; its superclass
    # reference counts as file-level code of the spec (#1732), keeping the test-only answer it had before.
    it "keeps a base subclassed only by an undeclared spec class test-reachable" do
      report = report_for({ "lib/base.rb" => "class Base; end\nclass Root; end\n",
                            "spec/support/fake.rb" => "class FakeBase < Base; end\n" },
                          roots: ["Root"], declared: ["lib/base.rb"])
      expect(report.candidates.map(&:fqn)).to be_empty
      expect(report.test_only.map(&:fqn)).to eq(["Base"])
    end

    # A base whose only subclass cannot be decided cannot be decided either: listing it as a definite
    # candidate invites deleting the base of a class that may be live.
    it "demotes the base of an undecidable subclass to undecidable, naming the subclass" do
      report = report_for({ "lib/a.rb" => "class Base; end\nclass Sub < Base; end\n",
                            "lib/m.rb" => "\"Sub\#{ARGV.first}\".constantize\n" })
      expect(report.candidates.map(&:fqn)).to be_empty
      expect(report.undecidable.to_h { [it.fqn, it.reason] })
        .to include("Sub" => a_string_including("constantize"),
                    "Base" => "reachable from Sub, which cannot be decided")
    end

    it "still reports a base that only a dead subclass names when another class is undecidable" do
      report = report_for({ "lib/a.rb" => "class Base; end\nclass Dead < Base; end\nclass Other; end\n",
                            "lib/m.rb" => "\"Other\#{ARGV.first}\".constantize\n" })
      expect(report.candidates.map(&:fqn)).to eq(%w[Base Dead])
    end

    # Ruby reads the superclass before `Api::User` exists, so `User` there is `::User`.
    it "never resolves a superclass to the subclass it declares" do
      report = report_for({ "lib/a.rb" => "class User; end\nmodule Api\n  class User < User; end\nend\n",
                            "lib/m.rb" => "Api::User.new\n" })
      expect(report.candidates.map(&:fqn)).to be_empty
    end

    it "keeps the role of the subclass's file on the superclass edge" do
      report = report_for({ "lib/a.rb" => "class Base; end\nclass Child < Base; end\n",
                            "spec/child_spec.rb" => "Child.new\n" })
      expect(report.candidates.map(&:fqn)).to be_empty
      expect(report.test_only.map(&:fqn)).to eq(%w[Base Child])
    end
  end

  # Issue #1733 — a superclass that is a call rather than a constant names constants in its receiver and
  # arguments. Only a constant superclass was ever read, so those were never recorded and every one of them
  # was a false candidate.
  describe "a non-constant superclass expression is walked (#1733)" do
    def report_for(files, roots: [])
      decls = []
      refs = []
      files.each do |path, source|
        result = Rigor::Analysis::Reachability::Scan.call(path: path, source: source)
        raise "fixture #{path} did not parse" if result.nil?

        decls.concat(result.declarations)
        refs.concat(result.references)
      end
      Rigor::Analysis::Reachability::Graph.new(declarations: decls, references: refs, root_fqns: roots).report
    end

    {
      "DelegateClass(Foo)" => "class Foo; end\nclass Sub < DelegateClass(Foo); end\n",
      "Struct.new(:a, Foo::X)" => "module Foo\n  X = 1\nend\nclass Sub < Struct.new(:a, Foo::X); end\n",
      "ActiveRecord::Migration[7.1]" => "module ActiveRecord\n  class Migration; end\nend\n" \
                                        "class Sub < ActiveRecord::Migration[7.1]; end\n"
    }.each do |superclass, source|
      it "reaches what `#{superclass}` names through its reachable subclass" do
        report = report_for({ "lib/a.rb" => source, "lib/main.rb" => "Sub.new\n" })
        expect(report.candidates.map(&:fqn)).to be_empty
      end
    end

    # The edge leaves the subclass, as a constant superclass's does (#1720): a dead subclass leaves what its
    # superclass expression names dead too, rather than rooting it from the enclosing scope.
    it "credits the superclass expression to the subclass" do
      report = report_for({ "lib/a.rb" => "class Foo; end\nclass Sub < DelegateClass(Foo); end\n",
                            "lib/main.rb" => "1\n" })
      expect(report.candidates.map(&:fqn)).to eq(%w[Foo Sub])
    end

    # The GitLab shape `< ::Gitlab::Database::Migration[2.2]::MigrationRecord`: a constant path on a computed
    # base names nothing resolvable, but the call it hangs from does.
    it "walks the computed base of a constant-path superclass" do
      report = report_for({ "lib/a.rb" => "class Mig\n  def self.[](v) = self\n  class Rec; end\nend\n" \
                                          "class UsesMig < Mig[2.2]::Rec; end\n",
                            "lib/main.rb" => "UsesMig.new\n" })
      expect(report.candidates.map(&:fqn)).not_to include("Mig")
    end

    it "resolves the superclass expression against the outer nesting" do
      result = Rigor::Analysis::Reachability::Scan.call(path: "lib/a.rb", source: <<~RUBY)
        module Outer
          class Sub < DelegateClass(Inner); end
        end
      RUBY
      ref = result.references.find { |r| r.as_written == "Inner" }
      expect([ref.from, ref.nesting]).to eq(["Outer::Sub", ["Outer"]])
    end
  end

  # Issue #1732 — a reference written inside a class body declared OUTSIDE `paths:` (an initializer, the
  # Rails `Application`, a spec helper) or in a reopened gem class names a scope that is not a node, so the
  # walk can never start from it. It counts as file-level code of its own file instead, in that file's role.
  describe "a reference from a class that is not an owned node is file-level (#1732)" do
    def report_for(files, declared:, roots: [], foreign: ->(_fqn) { false })
      decls = []
      shadows = []
      refs = []
      uses = []
      files.each do |path, source|
        result = Rigor::Analysis::Reachability::Scan.call(path: path, source: source)
        raise "fixture #{path} did not parse" if result.nil?

        (declared.include?(path) ? decls : shadows).concat(result.declarations)
        refs.concat(result.references)
        uses.concat(result.dynamic_uses)
      end
      Rigor::Analysis::Reachability::Graph.new(declarations: decls, references: refs, root_fqns: roots,
                                               dynamic_uses: uses, shadows: shadows, foreign: foreign).report
    end

    it "keeps a class used from an initializer's class body live in production" do
      report = report_for({ "app/services/svc.rb" => "class Svc; end
class Dead; end
",
                            "config/initializers/mw.rb" => "class Mw\n  def call = Svc.new\nend\n" },
                          declared: ["app/services/svc.rb"])
      expect(report.candidates.map(&:fqn)).to eq(["Dead"])
      expect(report.test_only).to be_empty
    end

    it "keeps a middleware named in config/application.rb's Application body live in production" do
      application = <<~RUBY
        module MyApp
          class Application < Rails::Application
            config.middleware.use MyMw
          end
        end
      RUBY
      report = report_for({ "lib/my_mw.rb" => "class MyMw; end\n", "config/application.rb" => application },
                          declared: ["lib/my_mw.rb"])
      expect(report.candidates.map(&:fqn)).to be_empty
      expect(report.test_only).to be_empty
    end

    it "keeps a base subclassed only by a nested spec class test-reachable" do
      report = report_for({ "lib/outer.rb" => "module Outer\n  class OBase; end\nend\nclass Root; end\n",
                            "spec/support/fake.rb" => "module Outer\n  class Fake < OBase; end\nend\n" },
                          declared: ["lib/outer.rb"], roots: ["Root"])
      expect(report.candidates.map(&:fqn)).to be_empty
      # `Outer` wraps nothing production reaches, so it is listed with its member (S2 below).
      expect(report.test_only.map(&:fqn)).to eq(%w[Outer Outer::OBase])
    end

    it "keeps a class used from a spec helper's method body test-reachable, not production" do
      helper = "module Helpers\n  class Fake\n    def go = Svc.new\n  end\nend\n"
      report = report_for({ "lib/svc.rb" => "class Svc; end\n", "spec/support/helper.rb" => helper },
                          declared: ["lib/svc.rb"])
      expect(report.candidates.map(&:fqn)).to be_empty
      expect(report.test_only.map(&:fqn)).to eq(["Svc"])
    end

    it "treats a reopened gem class inside paths as file-level code" do
      report = report_for({ "lib/ext.rb" => "class String\n  def to_svc = Svc.new\nend\nclass Svc; end\n" },
                          declared: ["lib/ext.rb"], foreign: ->(fqn) { fqn == "String" })
      expect(report.candidates.map(&:fqn)).to be_empty
    end

    # Test classes now contribute their references, so a test naming a namespace's own constant reaches the
    # namespace; one whose members production reaches is not "dead production code with a live test".
    it "does not report a namespace with a production-reachable member as test-only" do
      report = report_for({ "lib/ns.rb" => "module Ns\n  CONST = 1\n  class Live; end\nend\n",
                            "lib/main.rb" => "Ns::Live.new\n",
                            "test/ns_test.rb" => "class NsTest\n  def test_it = Ns::CONST\nend\n" },
                          declared: ["lib/ns.rb", "lib/main.rb"])
      expect(report.candidates.map(&:fqn)).to be_empty
      expect(report.test_only).to be_empty
    end

    # A spec class naming `Mid::Error` hides `Mid` as a namespace; the undecidable evidence from the worker
    # must still reach the service `Mid` calls rather than leaving it "reachable only from tests".
    it "spreads undecidable through a class hidden as a namespace" do
      lib = <<~RUBY
        class Worker
          def go = Mid.new
        end
        class Mid
          class Error < StandardError; end
          def go = Leaf.new
        end
        class Leaf; end
      RUBY
      report = report_for({ "lib/a.rb" => lib,
                            "lib/m.rb" => "\"Worker\#{ARGV.first}\".constantize\n",
                            "spec/mid_spec.rb" => "class MidSpec\n  def go = [Mid::Error, Leaf]\nend\n" },
                          declared: ["lib/a.rb", "lib/m.rb"])
      expect(report.test_only.map(&:fqn)).to eq(["Mid::Error"])
      expect(report.undecidable.to_h { [it.fqn, it.reason] })
        .to include("Leaf" => "reachable from Mid, which cannot be decided")
    end

    # The same when production names `Mid::Error` and a spec names `Mid`: `Mid` is hidden as a live
    # namespace rather than listed test-only, and the evidence must still pass through it.
    it "spreads undecidable through a test-reached class with a production-reachable member" do
      lib = <<~RUBY
        class Worker
          def go = Mid.new
        end
        class Mid
          class Error < StandardError; end
          def go = Leaf.new
        end
        class Leaf; end
      RUBY
      report = report_for({ "lib/a.rb" => lib,
                            "lib/m.rb" => "\"Worker\#{ARGV.first}\".constantize\nMid::Error\n",
                            "spec/mid_spec.rb" => "class MidSpec\n  def go = [Mid, Leaf]\nend\n" },
                          declared: ["lib/a.rb", "lib/m.rb"])
      expect(report.test_only).to be_empty
      expect(report.undecidable.to_h { [it.fqn, it.reason] })
        .to include("Leaf" => "reachable from Mid, which cannot be decided")
    end

    # A namespace is excused only by a member production reaches. One whose members only tests reach is dead
    # production code with them, and must not vanish from every bucket.
    it "lists a namespace whose members only tests reach as test-only" do
      report = report_for({ "lib/foo.rb" => "module Foo\n  def self.run = 1\n  class Bar; end\nend\n",
                            "test/foo_test.rb" => "class FooTest < Minitest::Test\n  def t = Foo::Bar.new\nend\n" },
                          declared: ["lib/foo.rb"])
      expect(report.candidates).to be_empty
      expect(report.test_only.map(&:fqn)).to eq(%w[Foo Foo::Bar])
    end

    # #1751 — a class-body reference from an end-to-end tree outside paths: is test evidence; the same
    # reference from a tooling tree stays production, because deleting the class breaks the tooling.
    it "reads a qa/ class-body reference as test evidence and a tooling one as production" do
      report = report_for({ "lib/e2e_only.rb" => "class E2eOnly; end\n",
                            "lib/tool_only.rb" => "class ToolOnly; end\n",
                            "qa/page.rb" => "class Page\n  E2eOnly.new\nend\n",
                            "rubocop/cop.rb" => "class Cop\n  ToolOnly.new\nend\n" },
                          declared: ["lib/e2e_only.rb", "lib/tool_only.rb"])
      expect(report.test_only.map(&:fqn)).to eq(["E2eOnly"])
      expect(report.candidates.map(&:fqn)).not_to include("ToolOnly")
    end

    it "keeps a tainted namespace whose members only tests reach undecidable" do
      report = report_for({ "lib/fmt.rb" => "module Fmt\n  class Textile; end\nend\n",
                            "lib/use.rb" => "\"Fmt::\#{ARGV.first}\".constantize\n",
                            "test/t_test.rb" => "class TTest\n  def t = Fmt::Textile\nend\n" },
                          declared: ["lib/fmt.rb", "lib/use.rb"])
      expect(report.test_only).to be_empty
      expect(report.undecidable.map(&:fqn)).to contain_exactly("Fmt", "Fmt::Textile")
    end

    it "still hides a namespace with a member production reaches" do
      report = report_for({ "lib/foo.rb" => "module Foo\n  class Bar; end\n  class Baz; end\nend\n",
                            "lib/main.rb" => "Foo::Bar.new\n",
                            "test/foo_test.rb" => "class FooTest\n  def test_it = Foo::Baz.new\nend\n" },
                          declared: ["lib/foo.rb", "lib/main.rb"])
      expect(report.candidates).to be_empty
      expect(report.test_only.map(&:fqn)).to eq(["Foo::Baz"])
    end

    # A migration's local model stub is what its own body names, as in Ruby; rooting the app's dead model of
    # the same name instead would hide it.
    it "resolves a name to a class its own file declares outside paths first" do
      migration = <<~RUBY
        class Drop < ActiveRecord::Migration[7.0]
          class LegacyThing < ActiveRecord::Base; end
          def up = LegacyThing.delete_all
        end
      RUBY
      report = report_for({ "app/models/legacy_thing.rb" => "class LegacyThing < ApplicationRecord; end\n",
                            "db/migrate/1_drop.rb" => migration },
                          declared: ["app/models/legacy_thing.rb"])
      expect(report.candidates.map(&:fqn)).to eq(["LegacyThing"])
    end

    it "resolves a spec helper's sibling to the helper's own file, not to a same-named app class" do
      helper = "module H\n  class Formatter; end\n  class Fake\n    def x = Formatter.new\n  end\nend\n"
      report = report_for({ "app/fmt.rb" => "class Formatter; end\n", "spec/support/h.rb" => helper },
                          declared: ["app/fmt.rb"])
      expect(report.candidates.map(&:fqn)).to eq(["Formatter"])
      expect(report.test_only).to be_empty
    end

    # A spec support stub is loaded with the specs only, so it must not shadow another file's reference.
    it "does not let another file's outside-paths declaration shadow a reference" do
      report = report_for({ "app/user.rb" => "class User; end\n",
                            "spec/support/stub.rb" => "module Admin\n  class User; end\nend\n",
                            "config/initializers/admin.rb" => "module Admin\n  def self.go = User.new\nend\n" },
                          declared: ["app/user.rb"])
      expect(report.candidates).to be_empty
      expect(report.test_only).to be_empty
    end

    # The fallback is only for scopes that are not nodes: an owned class's body still credits the class, so a
    # dead owned class keeps what it names dead.
    it "still credits an owned class reopened outside paths to that class" do
      report = report_for({ "lib/a.rb" => "class Owned; end\nclass Svc; end\n",
                            "config/initializers/owned.rb" => "class Owned\n  def go = Svc.new\nend\n" },
                          declared: ["lib/a.rb"])
      expect(report.candidates.map(&:fqn)).to eq(%w[Owned Svc])
    end
  end
end
