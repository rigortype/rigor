# frozen_string_literal: true

require "spec_helper"

# ADR-53 Track B — the permanent equivalence harness for the engine-owned CheckRules::RuleWalk. Every collector hosted
# on the walk keeps its legacy single-collector walk as the oracle; this spec runs both over sources that exercise the
# shared traversal contract (loop / block suppression, nesting, firing and non-firing shapes) plus the whole integration
# fixture corpus, and requires identical per-collector results. A collector may only migrate onto the walk while this
# oracle comparison holds; the corpus-scale companion is the `RIGOR_SHADOW_RULE_WALK=1` mode in
# `CheckRules.run_node_collectors`.
module RuleWalkEquivalenceCases
  # Curated shapes: each exercises a distinct part of the traversal contract. Firing shapes are present for BOTH
  # collectors so the harness can never pass vacuously (asserted in the spec).
  CURATED = {
    "top-level firing if (always-truthy)" => <<~RUBY,
      x = 1
      if x
        puts "yes"
      end
    RUBY
    "unless + ternary forms" => <<~RUBY,
      x = nil
      unless x
        puts "no"
      end
      y = 2
      z = y ? 1 : 2
      puts z
    RUBY
    "suppressed inside while body" => <<~RUBY,
      x = 1
      while ENV["loop"]
        if x
          puts "suspect"
        end
      end
    RUBY
    "suppressed inside block, firing outside" => <<~RUBY,
      x = 1
      [1, 2].each do |i|
        if x
          puts i
        end
      end
      if x
        puts "outer"
      end
    RUBY
    "nested blocks and until / for" => <<~RUBY,
      x = 1
      until ENV["done"]
        [1].map { if x then 1 end }
      end
      for i in [1, 2]
        if x
          puts i
        end
      end
    RUBY
    "dead when clause (disjoint)" => <<~RUBY,
      x = 1
      case x
      when Integer
        puts "live"
      when String
        puts "dead"
      end
    RUBY
    "dead in clause + exhausted else" => <<~RUBY,
      x = 1
      case x
      in Integer
        puts "live"
      in String
        puts "dead"
      end
      y = :sym
      case y
      when Symbol
        puts "live"
      else
        puts "dead else"
      end
    RUBY
    "case suppressed inside block" => <<~RUBY,
      x = 1
      [1].each do
        case x
        when String
          puts "inside block: not collected"
        end
      end
    RUBY
    "defensive else and defensive predicates (non-firing paths)" => <<~RUBY,
      x = 1
      case x
      when Integer
        puts "live"
      else
        raise "unreachable"
      end
      if x.nil?
        puts "defensive"
      end
    RUBY
    "if nested in case body, case nested in if body" => <<~RUBY,
      x = 1
      case x
      when Integer
        if x
          puts "nested if"
        end
      end
      if x
        case x
        when String
          puts "nested dead clause"
        end
      end
    RUBY
    "ivar writes across nested classes and a barrier def" => <<~RUBY,
      class Outer
        def set_a
          @a = 1
          @a = "two"
        end

        class Inner
          def set_b
            @b = :sym
          end
        end

        def with_nested_def
          @c = 1
          define = lambda { @c = "shadowed-by-block-not-recorded" }
          define
        end
      end
    RUBY
    "ivar writes skipped in singleton + top-level defs, suppressed in loop/block" => <<~RUBY,
      @top = 1
      @top = "x"

      class Skips
        def self.singleton_write
          @s = 1
          @s = "two"
        end

        def loop_write
          [1, 2].each do
            @looped = 1
            @looped = "two"
          end
        end
      end
    RUBY
    "ivar writes inside a nested def are not double-collected" => <<~RUBY,
      class Holder
        def outer
          @x = 1
          def inner
            @x = "nested-def-ivar"
          end
          @x = "after"
        end
      end
    RUBY
    "dead assignments across nested defs, underscore, trailing write, reads" => <<~RUBY,
      def with_dead
        dead = 1
        live = 2
        _ignored = 3
        puts live

        def nested
          inner_dead = 9
          inner_live = 10
          inner_live
        end

        trailing = 4
      end

      def all_read
        a = 1
        b = a + 1
        b
      end
    RUBY
    "dead assignment suppressed by an or-write read and a closure read" => <<~RUBY
      def or_write_reads
        x = 1
        x ||= 2
        captured = 5
        [1].each { captured }
        x
      end
    RUBY
  }.freeze

  FIXTURE_FILES = Dir[File.expand_path("../../../integration/fixtures/*.rb", __dir__)].freeze

  # Every {RuleWalk}-hosted collector, in the order it is added to the shared walk. Each keeps its legacy `#collect`
  # walk as the oracle.
  HOSTED_COLLECTOR_CLASSES = [
    Rigor::Analysis::CheckRules::AlwaysTruthyConditionCollector,
    Rigor::Analysis::CheckRules::UnreachableClauseCollector,
    Rigor::Analysis::CheckRules::IvarWriteCollector,
    Rigor::Analysis::CheckRules::DeadAssignmentCollector
  ].freeze
end

RSpec.describe Rigor::Analysis::CheckRules::RuleWalk do
  def parse_and_index(source)
    parsed = Prism.parse(source)
    return nil if parsed.errors.any?

    root = parsed.value
    [root, Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty)]
  end

  def legacy_results(root, scope_index)
    RuleWalkEquivalenceCases::HOSTED_COLLECTOR_CLASSES.map { |klass| klass.new(scope_index).collect(root) }
  end

  def walk_results(root, scope_index)
    collectors = RuleWalkEquivalenceCases::HOSTED_COLLECTOR_CLASSES.map { |klass| klass.new(scope_index) }
    described_class.run(root, collectors)
    collectors.map(&:results)
  end

  # ADR-53 B4 — drive the SAME collectors through the converged {Plugin::NodeRuleWalk} traversal (with no plugins, so
  # only the built-in {CollectorDriver} runs) instead of the standalone `RuleWalk.run`. Asserts the convergence
  # preserves per-collector results byte-for-byte against the legacy oracle.
  def converged_walk_results(root, scope_index)
    collectors = RuleWalkEquivalenceCases::HOSTED_COLLECTOR_CLASSES.map { |klass| klass.new(scope_index) }
    driver = described_class::CollectorDriver.new(collectors)
    walk = Rigor::Plugin::NodeRuleWalk.new([])
    walk.diagnostics_for_file(path: "(spec)", scope: Rigor::Scope.empty, root: root, collector_driver: driver)
    collectors.map(&:results)
  end

  describe "curated traversal shapes" do
    RuleWalkEquivalenceCases::CURATED.each do |name, source|
      it "matches the legacy collectors on: #{name}" do
        root, scope_index = parse_and_index(source)
        raise "curated source failed to parse: #{name}" if root.nil?

        expect(walk_results(root, scope_index)).to eq(legacy_results(root, scope_index))
      end

      it "the converged plugin-walk matches the legacy collectors on: #{name}" do
        root, scope_index = parse_and_index(source)
        raise "curated source failed to parse: #{name}" if root.nil?

        expect(converged_walk_results(root, scope_index)).to eq(legacy_results(root, scope_index))
      end
    end

    it "is not vacuous: the curated set fires every hosted collector" do
      totals = Array.new(RuleWalkEquivalenceCases::HOSTED_COLLECTOR_CLASSES.size, 0)
      RuleWalkEquivalenceCases::CURATED.each_value do |source|
        root, scope_index = parse_and_index(source)
        # Array collectors (flow) count entries; the IvarWrite Hash counts the classes that carry recorded writes — both
        # are positive only when the collector actually fired.
        legacy_results(root, scope_index).each_with_index { |results, i| totals[i] += results.size }
      end
      expect(totals).to all(be_positive)
    end
  end

  describe "integration fixture corpus" do
    it "covers the fixture corpus" do
      expect(RuleWalkEquivalenceCases::FIXTURE_FILES.size).to be > 20
    end

    RuleWalkEquivalenceCases::FIXTURE_FILES.each do |path|
      it "matches the legacy collectors on fixtures/#{File.basename(path)}" do
        root, scope_index = parse_and_index(File.read(path))
        skip "fixture does not parse standalone" if root.nil?

        legacy = legacy_results(root, scope_index)
        expect(walk_results(root, scope_index)).to eq(legacy)
        expect(converged_walk_results(root, scope_index)).to eq(legacy)
      end
    end
  end

  # ADR-53 B3c — the stateless main pass rides the same {RuleWalk}; its `#results` are the per-node diagnostics, so its
  # oracle is the former inline `Source::NodeWalker.each` `case` (`CheckRules.main_pass_oracle`). Equivalence is
  # order-sensitive byte equality (the text formatter emits `result.diagnostics` in array order, unsorted), so we
  # compare the full serialised diagnostic list.
  describe "main pass on the shared walk vs the inline oracle" do
    def main_pass_walk(path, root, scope_index)
      node_diagnostics = ->(node) { Rigor::Analysis::CheckRules.main_pass_node_diagnostics(path, node, scope_index) }
      collector = Rigor::Analysis::CheckRules::MainPassCollector.new(node_diagnostics)
      described_class.run(root, [collector])
      collector.results.map(&:to_h)
    end

    # ADR-53 B4 — drive the main pass through the converged {Plugin::NodeRuleWalk} traversal (no plugins, so only the
    # built-in {CollectorDriver} runs). The main pass is a {RuleWalk}-hosted collector like the others, so the converged
    # walk must reproduce the inline oracle byte-for-byte too — this is the converged-walk coverage for the fifth
    # (main-pass) collector.
    def main_pass_converged_walk(path, root, scope_index)
      node_diagnostics = ->(node) { Rigor::Analysis::CheckRules.main_pass_node_diagnostics(path, node, scope_index) }
      collector = Rigor::Analysis::CheckRules::MainPassCollector.new(node_diagnostics)
      driver = described_class::CollectorDriver.new([collector])
      walk = Rigor::Plugin::NodeRuleWalk.new([])
      walk.diagnostics_for_file(path: "(spec)", scope: Rigor::Scope.empty, root: root, collector_driver: driver)
      collector.results.map(&:to_h)
    end

    def main_pass_oracle(path, root, scope_index)
      Rigor::Analysis::CheckRules.main_pass_oracle(path, root, scope_index).map(&:to_h)
    end

    RuleWalkEquivalenceCases::FIXTURE_FILES.each do |path|
      it "matches the inline oracle on fixtures/#{File.basename(path)}" do
        root, scope_index = parse_and_index(File.read(path))
        skip "fixture does not parse standalone" if root.nil?

        rel = "fixtures/#{File.basename(path)}"
        oracle = main_pass_oracle(rel, root, scope_index)
        expect(main_pass_walk(rel, root, scope_index)).to eq(oracle)
        expect(main_pass_converged_walk(rel, root, scope_index)).to eq(oracle)
      end
    end

    it "fires the main pass somewhere in the fixture corpus (non-vacuity)" do
      total = RuleWalkEquivalenceCases::FIXTURE_FILES.sum do |path|
        root, scope_index = parse_and_index(File.read(path))
        next 0 if root.nil?

        main_pass_oracle("f", root, scope_index).size
      end
      expect(total).to be_positive
    end
  end
end
