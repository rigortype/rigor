# frozen_string_literal: true

require "spec_helper"
require_relative "../../support/ancestry_walker_scan"

# ADR-24 (amended for #1567) — `Scope::ResolutionChain` is the ONE transitive walker of the discovery tables'
# ancestry edges for "which definer does Ruby call". Before it existed, six consumers walked `includes_of` /
# `superclass_of` themselves, each breadth-first or level by level, and none in Ruby's order: #1567, #1568,
# #1570 and #1571 were four readers of that shape answering from the wrong definer. This spec keeps the
# number from growing again.
#
# The rule. A method under `lib/` or `plugins/*/lib/`, outside the chain builder
# (`lib/rigor/scope/resolution_chain.rb`), is a WALKER when it
#
# - reads two or more of the ten ancestry readers — `includes_of`, `prepends_of`, `superclass_of`,
#   `singleton_extends_of`, the raw tables `discovered_includes`, `discovered_prepends`,
#   `discovered_superclasses`, `discovered_extends` (a `DiscoveryIndex` member or its `Scope` pass-through),
#   and the two that hand out a class's direct ancestors one step at a time, `Scope#enqueue_ancestors` and
#   `ResolutionChain.direct_ancestors` (a loop over either is the breadth-first walk the chain replaced);
# - reads one inside a loop — a block, `while`, `until` or `for` body — directly or through a local it
#   assigned the table to (`supers = scope.discovered_superclasses` … `supers[current]`);
# - calls a method of the same file that reads one, inside a loop; or
# - reads one in a method that reaches itself through the file's own receiverless calls.
#
# A read whose result only answers membership or emptiness (`discovered_superclasses.key?(name)`,
# `includes_of(name).empty?`), and a table taken whole — merged (`discovered_includes.merge(per_file)`) or held
# in an instance variable — read no edge and do not count.
#
# Every walker must be in {ALLOWED_ANCESTRY_WALKERS} with the reason it may stay: it deliberately over-approximates
# (a union or universal over every ancestor, for withholding), answers a question other than "which definer",
# interleaves edges the tables do not carry, or copies the tables. A new walker fails until it is either
# migrated onto the chain or listed with its reason; a listed entry that no longer walks fails too, so the
# list shrinks as the migration proceeds.
#
# What the scan cannot see:
#
# - ancestry reached through `Reflection` or `Environment` (`rbs_loader.ancestor_names_for`, RBS class
#   ordering), which is RBS's ancestry, not the discovery tables';
# - a walk split across files — a helper in another file called in a loop, or a table read once and passed
#   into a helper that loops over it (`CheckRules#direct_subclasses`) — and mutual recursion across files;
# - dispatch through `send` / `public_send`, or a reader spelled as a String;
# - a copy of the tables held in an instance variable and walked there (`Effects::PluginFacts#ancestry`,
#   which walks the includes and superclasses its plugin facts were built from);
# - descendant walks that iterate a table whole (`SourceArity#children_by_parent`), which read no ancestor's
#   position.
# The allow-list: `file#method` => the reason it may keep walking.
ALLOWED_ANCESTRY_WALKERS = {
  "lib/rigor/inference/definer_resolution.rb#singleton_hooks?" =>
    "reads each module of the receiver's instance chain once for a hook, `:extend` listing or `Concern` extend " \
    "(ADR-119 WD3's singleton-side decline); a union over the chain's own entries, order-independent",
  "lib/rigor/analysis/check_rules.rb#method_defined_on_known_subclass?" =>
    "descendant walk over the inverted superclass table: any subclass defining the name withholds " \
    "`call.self-undefined-method`; order-independent",
  "lib/rigor/analysis/check_rules.rb#mixin_may_answer?" =>
    "union over every module an ancestor mixes in: any that may answer withholds a `global.*` write " \
    "diagnostic; order-independent",
  "lib/rigor/analysis/check_rules.rb#self_undefined_method_diagnostics" =>
    "calls the closedness gate once per recorded miss; the gate withholds `call.self-undefined-method` " \
    "unless the class's own direct edges and its subclass closure are closed, and walks no ancestor",
  "lib/rigor/analysis/check_rules/shadowed_rescue_collector.rb#project_chain_covered?" =>
    "subclass-of reachability along the superclass chain, interleaved with RBS class ordering at each hop; " \
    "asks whether an ancestor is there at all, not which one defines a method",
  "lib/rigor/inference/expression_typer.rb#ancestry_step_leaves_project?" =>
    "reporting-only union for the `coverage --protection` cause label: does any ancestor leave the project " \
    "into an RBS-less gem; order-independent and capped at 16 by design",
  "lib/rigor/inference/expression_typer.rb#external_gem_reached_through_ancestry?" =>
    "the loop of `ancestry_step_leaves_project?`, the same reporting-only union",
  "lib/rigor/inference/last_line/implicit_self.rb#class_side?" =>
    "universal over the class side's whole ancestry, project and RBS alike (no ancestor may carry a Ruby " \
    "reader), to withhold; order-independent, and it continues into RBS ancestors the chain does not expand",
  "lib/rigor/inference/last_line/implicit_self.rb#instance_side?" =>
    "the instance-side twin of `class_side?`: universal over project and RBS ancestry, to withhold",
  "lib/rigor/inference/last_line/implicit_self.rb#rbs_ancestry?" =>
    "the RBS half of `instance_side?` / `class_side?`: the project mixins of each RBS ancestor, universal, " \
    "to withhold",
  "lib/rigor/inference/macro_block_self_type.rb#singleton_extends_reach?" =>
    "singleton-side first definer (own `def self.`, then `extend`s nearest first, then the superclass) that " \
    "interleaves RBS-declared extends (`Environment#singleton_extended_modules`) the tables do not carry, and " \
    "reads the raw tables so it files no ADR-46 edge; already Ruby's singleton order for what it sees",
  "lib/rigor/inference/macro_block_self_type.rb#source_ancestors_reach?" =>
    "reachability of a DSL constraint class along the superclass chain, continued through RBS inheritance; " \
    "order-independent",
  "lib/rigor/inference/method_dispatcher/rbs_dispatch.rb#allowed_rbs_complete_extended_module" =>
    "the dispatch twin of `singleton_extends_reach?`: interleaves RBS-declared extends and files no ADR-46 edge",
  "lib/rigor/inference/method_dispatcher/rbs_dispatch.rb#each_source_ancestor_candidate" =>
    "yields every candidate spelling to three shadow guards and files no ADR-46 edge; two guards are unions, " \
    "the third (`allowed_rbs_complete_ancestor`) is a breadth-first first-definer walk deferred to #1572",
  "lib/rigor/scope.rb#singleton_extends_of" =>
    "union of every `extend` up the superclass chain, read by `Narrowing` only to withhold a `Bot`; " \
    "order-independent"
}.freeze

RSpec.describe "ancestry walkers outside Scope::ResolutionChain" do
  let(:root) { File.expand_path("../../..", __dir__) }
  let(:found) { AncestryWalkerScan.scan(root) }

  it "finds no ancestry walker that is not allow-listed with a reason" do
    unlisted = found.except(*ALLOWED_ANCESTRY_WALKERS.keys)
    expect(unlisted).to be_empty, lambda {
      "#{unlisted.size} method(s) walk the discovery tables' ancestry themselves. Read " \
      "`Scope::ResolutionChain` instead, or list the method in ALLOWED_ANCESTRY_WALKERS with the reason it " \
      "may stay:\n" + unlisted.map { |key, reasons| "  #{key}: #{reasons.join('; ')}" }.join("\n")
    }
  end

  it "lists no method that no longer walks" do
    stale = ALLOWED_ANCESTRY_WALKERS.keys - found.keys
    expect(stale).to be_empty,
                     "ALLOWED_ANCESTRY_WALKERS entries that no longer walk — remove them:\n  #{stale.join("\n  ")}"
  end

  it "gives every allow-listed walker a reason" do
    expect(ALLOWED_ANCESTRY_WALKERS.values).to all(match(/\S{3,}/))
  end

  # `ResolutionChain#settle` is the ONE place that decides whether a chain's answer stands or master's does
  # (ADR-24 § "Amendment 2026-09-28"): the retro world is private to it, and no reader compares two worlds, or
  # asks whether the chain was "contested", itself. Before it, eight readers each owned the rule, and each
  # could get the count of skips wrong.
  it "keeps the retro world and the skip decision inside the chain builder" do
    hits = Dir[File.join(root, "{lib,plugins}/**/*.rb")].flat_map do |path|
      relative = path.delete_prefix("#{root}/")
      next [] if AncestryWalkerScan::CHAIN_BUILDERS.include?(relative)

      File.readlines(path).each_with_index.filter_map do |line, index|
        "#{relative}:#{index + 1}: #{line.strip}" if line.match?(/\.retro\b|\bchain\.contested\?/)
      end
    end
    expect(hits).to be_empty,
                    "these read the chain's retro world themselves; ask `settle` instead:\n  #{hits.join("\n  ")}"
  end

  # ADR-119 WD2 — `settle`'s `unknown_for:` option is the one new decision, and its inputs (the fork count, the
  # marks, the unpositioned table) stay where it is made: no reader reads them, or passes the option, except the
  # chain's own files and `Inference::DefinerResolution`. `unsettled?` stays the boolean existing readers see.
  it "keeps the fork count, the marks and the unknown option inside the chain and the candidate-set read" do
    hits = Dir[File.join(root, "{lib,plugins}/**/*.rb")].flat_map do |path|
      relative = path.delete_prefix("#{root}/")
      next [] if AncestryWalkerScan::DECISION_READERS.include?(relative)

      File.readlines(path).each_with_index.filter_map do |line, index|
        "#{relative}:#{index + 1}: #{line.strip}" if line.match?(AncestryWalkerScan::DECISION_INPUTS)
      end
    end
    expect(hits).to be_empty,
                    "these read `settle`'s decision inputs themselves; ask `DefinerResolution`:\n  #{hits.join("\n  ")}"
  end

  it "matches the decision inputs it guards, and not `unsettled?`" do
    pattern = AncestryWalkerScan::DECISION_INPUTS
    guarded = [".forks", "chain.skip_count", "chain.marks.all?", "scope.discovery.unpositioned_mixins[name]",
               "chain.settle(scope, a, unknown_for: n)"]
    expect(guarded.map { |line| pattern.match?(line) }).to all(be(true))
    expect(pattern.match?("chain.unsettled?")).to be(false)
  end

  # The scan's positive control: each rule fires on a method written to trip it, so a scan that silently
  # stopped matching cannot pass the two examples above by finding nothing.
  describe "the scan itself" do
    def scan_source(source)
      visitor = AncestryWalkerScan::MethodVisitor.new
      Prism.parse(source).value.accept(visitor)
      AncestryWalkerScan.findings_for("lib/x.rb", visitor.methods).to_h { |finding| [finding.key, finding.reasons] }
    end

    it "flags two readers, a loop read, an aliased loop read, a looped helper call and recursion" do
      found = scan_source(<<~RUBY)
        class X
          def two(scope, c) = [scope.includes_of(c), scope.superclass_of(c)]
          def looped(scope, cs) = cs.map { |c| scope.includes_of(c) }
          def aliased(scope, cs)
            supers = scope.discovered_superclasses
            cs.each { |c| supers[c] }
          end
          def helper(scope, c) = scope.superclass_of(c)
          def driver(scope, cs) = cs.each { |c| helper(scope, c) }
          def recursive(scope, c)
            parent = scope.superclass_of(c)
            parent && recursive(scope, parent)
          end
        end
      RUBY
      expect(found.keys).to contain_exactly("lib/x.rb#two", "lib/x.rb#looped", "lib/x.rb#aliased",
                                            "lib/x.rb#driver", "lib/x.rb#recursive")
    end

    it "flags a loop over the one-step ancestor readers and not a single call" do
      found = scan_source(<<~RUBY)
        class X
          def bfs(scope, queue)
            queue.each { |current| scope.enqueue_ancestors(current, queue, {}) }
          end
          def chain_bfs(scope, names)
            names.flat_map { |name| Rigor::Scope::ResolutionChain.direct_ancestors(scope, name, true) }
          end
          def both(scope, name, queue)
            scope.enqueue_ancestors(name, queue, {})
            Rigor::Scope::ResolutionChain.direct_ancestors(scope, name, true)
          end
          def once(scope, name, queue) = scope.enqueue_ancestors(name, queue, {})
          def once_direct(scope, name) = Rigor::Scope::ResolutionChain.direct_ancestors(scope, name, false)
        end
      RUBY
      expect(found.keys).to contain_exactly("lib/x.rb#bfs", "lib/x.rb#chain_bfs", "lib/x.rb#both")
    end

    it "does not flag one direct read, a membership read inside a loop, or a table copied whole" do
      found = scan_source(<<~RUBY)
        class X
          def once(scope, c) = scope.includes_of(c).map(&:to_s)
          def member(scope, cs) = cs.select { |c| scope.discovered_superclasses.key?(c) }
          def seed(index)
            @includes = index.discovered_includes
            @supers = index.discovered_superclasses
          end
          def merged(scope, file) = [scope.discovered_includes.merge(file) { |_c, a, b| a + b }, scope.discovered_prepends.merge(file)]
        end
      RUBY
      expect(found).to be_empty
    end
  end
end
