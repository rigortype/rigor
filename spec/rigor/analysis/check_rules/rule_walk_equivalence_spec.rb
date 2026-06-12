# frozen_string_literal: true

require "spec_helper"

# ADR-53 Track B — the permanent equivalence harness for the engine-owned
# CheckRules::RuleWalk. Every collector hosted on the walk keeps its
# legacy single-collector walk as the oracle; this spec runs both over
# sources that exercise the shared traversal contract (loop / block
# suppression, nesting, firing and non-firing shapes) plus the whole
# integration fixture corpus, and requires identical per-collector
# results. A collector may only migrate onto the walk while this oracle
# comparison holds; the corpus-scale companion is the
# `RIGOR_SHADOW_RULE_WALK=1` mode in `CheckRules.flow_collector_results`.
module RuleWalkEquivalenceCases
  # Curated shapes: each exercises a distinct part of the traversal
  # contract. Firing shapes are present for BOTH collectors so the
  # harness can never pass vacuously (asserted in the spec).
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
    "ivar writes inside a nested def are not double-collected" => <<~RUBY
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
  }.freeze

  FIXTURE_FILES = Dir[File.expand_path("../../../integration/fixtures/*.rb", __dir__)].freeze

  # Every {RuleWalk}-hosted collector, in the order it is added to the
  # shared walk. Each keeps its legacy `#collect` walk as the oracle.
  HOSTED_COLLECTOR_CLASSES = [
    Rigor::Analysis::CheckRules::AlwaysTruthyConditionCollector,
    Rigor::Analysis::CheckRules::UnreachableClauseCollector,
    Rigor::Analysis::CheckRules::IvarWriteCollector
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

  describe "curated traversal shapes" do
    RuleWalkEquivalenceCases::CURATED.each do |name, source|
      it "matches the legacy collectors on: #{name}" do
        root, scope_index = parse_and_index(source)
        raise "curated source failed to parse: #{name}" if root.nil?

        expect(walk_results(root, scope_index)).to eq(legacy_results(root, scope_index))
      end
    end

    it "is not vacuous: the curated set fires every hosted collector" do
      totals = Array.new(RuleWalkEquivalenceCases::HOSTED_COLLECTOR_CLASSES.size, 0)
      RuleWalkEquivalenceCases::CURATED.each_value do |source|
        root, scope_index = parse_and_index(source)
        # Array collectors (flow) count entries; the IvarWrite Hash counts
        # the classes that carry recorded writes — both are positive only
        # when the collector actually fired.
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

        expect(walk_results(root, scope_index)).to eq(legacy_results(root, scope_index))
      end
    end
  end
end
