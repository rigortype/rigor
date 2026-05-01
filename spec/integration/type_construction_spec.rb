# frozen_string_literal: true

# Integration spec: the engine should construct precise types for
# small but realistic Ruby snippets. These tests are intentionally
# readable end-to-end — each example is a complete program that a
# Ruby user might write — so the file doubles as living
# documentation for the inference engine's capability surface.

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "Rigor type construction (integration)" do # rubocop:disable RSpec/DescribeClass
  let(:scope) { Rigor::Scope.empty(environment: Rigor::Environment.default) }

  # Parses a program and returns the [type, post_scope] pair for the
  # whole program (i.e. the type of the LAST top-level statement).
  def evaluate(source)
    scope.evaluate(Prism.parse(source).value)
  end

  # Resolves the type at a given (line, column) — 1-indexed —
  # through `Inference::ScopeIndexer` so locals / ivars bound earlier
  # in the program are visible at the probed position.
  def type_at(source, line:, column:)
    tree = Prism.parse(source).value
    index = Rigor::Inference::ScopeIndexer.index(tree, default_scope: scope)
    locator = Rigor::Source::NodeLocator.new(source: source, root: tree)
    node = locator.at_position(line: line, column: column)
    index[node].type_of(node)
  end

  describe "predicate methods returning Symbol literals (even / odd)" do
    it "builds `Constant[:even] | Constant[:odd]` from an if-else over a predicate" do
      type, _post = evaluate(<<~RUBY)
        n = 4
        if n.even?
          :even
        else
          :odd
        end
      RUBY
      members = type.members.map(&:value)
      expect(members).to contain_exactly(:even, :odd)
    end

    it "binds the if-else result to a local with the constructed union" do
      _type, post = evaluate(<<~RUBY)
        n = 4
        result = if n.even?
          :even
        else
          :odd
        end
      RUBY
      result_type = post.local(:result)
      expect(result_type).to be_a(Rigor::Type::Union)
      expect(result_type.members.map(&:value)).to contain_exactly(:even, :odd)
    end
  end

  describe "case / when constructing a Symbol-literal union" do
    it "classifies an integer into one of three labels via case-when on Range/`==`" do
      type, _post = evaluate(<<~RUBY)
        n = 0
        case n
        when 0 then :zero
        when 1..9 then :small
        else :large
        end
      RUBY
      members = type.members.map(&:value)
      expect(members).to contain_exactly(:zero, :small, :large)
    end
  end

  describe "operator dispatch through compound writes" do
    it "constant-folds `n += k` so `n` is bound to the resulting Constant" do
      _type, post = evaluate(<<~RUBY)
        n = 10
        n += 5
        n -= 3
      RUBY
      expect(post.local(:n)).to eq(Rigor::Type::Combinator.constant_of(12))
    end

    it "`||=` on a nil-bound local replaces it with the rvalue type" do
      _type, post = evaluate(<<~RUBY)
        cached = nil
        cached ||= "hit"
      RUBY
      expect(post.local(:cached)).to eq(Rigor::Type::Combinator.constant_of("hit"))
    end
  end

  describe "is_a? narrowing — String | NilClass receiver" do
    it "narrows the body to String on the truthy branch and NilClass on the falsey branch" do # rubocop:disable RSpec/ExampleLength
      source = <<~RUBY
        x = if rand < 0.5
          "hello"
        else
          nil
        end
        if x.is_a?(String)
          x
        else
          x
        end
      RUBY
      truthy = type_at(source, line: 7, column: 3)
      falsey = type_at(source, line: 9, column: 3)
      expect(truthy).to eq(Rigor::Type::Combinator.constant_of("hello"))
      expect(falsey).to eq(Rigor::Type::Combinator.constant_of(nil))
    end
  end

  describe "Tuple element typing for small array literals" do
    it "exposes precise element types via `xs[index]` and `xs.first` / `xs.last`" do
      source = <<~RUBY
        xs = [10, 20, 30]
        first = xs.first
        middle = xs[1]
        last = xs.last
      RUBY
      _type, post = scope.evaluate(Prism.parse(source).value)
      expect(post.local(:first)).to eq(Rigor::Type::Combinator.constant_of(10))
      expect(post.local(:middle)).to eq(Rigor::Type::Combinator.constant_of(20))
      expect(post.local(:last)).to eq(Rigor::Type::Combinator.constant_of(30))
    end
  end

  describe "HashShape entry typing for symbol-key hashes" do
    it "resolves `h[:key]` and `h.fetch(:key)` to the precise entry value" do
      source = <<~RUBY
        h = { name: "Alice", age: 30 }
        n = h[:name]
        a = h.fetch(:age)
      RUBY
      _type, post = scope.evaluate(Prism.parse(source).value)
      expect(post.local(:n)).to eq(Rigor::Type::Combinator.constant_of("Alice"))
      expect(post.local(:a)).to eq(Rigor::Type::Combinator.constant_of(30))
    end
  end

  describe "block return type uplift through Array#map" do
    it "types `Array#map { |n| n.to_s }` as `Array[String]`" do
      project_scope = Rigor::Scope.empty(environment: Rigor::Environment.default)
      type = project_scope.type_of(Prism.parse("[1, 2, 3].map { |n| n.to_s }").value.statements.body.first)
      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Array")
      expect(type.type_args.first).to be_a(Rigor::Type::Nominal)
      expect(type.type_args.first.class_name).to eq("String")
    end
  end

  describe "user-authored predicate via RBS::Extended" do
    it "narrows a parameter on `predicate-if-true` / `predicate-if-false` edges" do # rubocop:disable RSpec/ExampleLength
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "sig"))
        File.write(File.join(dir, "sig/parity.rbs"), <<~RBS)
          class Parity
            %a{rigor:v1:predicate-if-true value is Integer}
            %a{rigor:v1:predicate-if-false value is NilClass}
            def integer?: (untyped value) -> bool
          end
        RBS
        Dir.chdir(dir) do
          source = <<~RUBY
            def f(value)
              p = Parity.new
              if p.integer?(value)
                value
              else
                value
              end
            end
          RUBY
          File.write("demo.rb", source)
          env = Rigor::Environment.for_project
          tree = Prism.parse(source).value
          base = Rigor::Scope.empty(environment: env)
          index = Rigor::Inference::ScopeIndexer.index(tree, default_scope: base)
          locator = Rigor::Source::NodeLocator.new(source: source, root: tree)
          truthy = index[locator.at_position(line: 4, column: 5)].type_of(locator.at_position(line: 4, column: 5))
          falsey = index[locator.at_position(line: 6, column: 5)].type_of(locator.at_position(line: 6, column: 5))
          expect(truthy).to be_a(Rigor::Type::Nominal)
          expect(truthy.class_name).to eq("Integer")
          expect(falsey).to be_a(Rigor::Type::Nominal)
          expect(falsey.class_name).to eq("NilClass")
        end
      end
    end
  end

  describe "early-return narrowing on a guarded local" do
    it "drops nil from `String | nil` after `return if x.nil?`" do # rubocop:disable RSpec/ExampleLength
      source = <<~RUBY
        def go(_)
          x = if rand < 0.5
            "hello"
          else
            nil
          end
          return if x.nil?
          x
        end
      RUBY
      tree = Prism.parse(source).value
      index = Rigor::Inference::ScopeIndexer.index(tree, default_scope: scope)
      locator = Rigor::Source::NodeLocator.new(source: source, root: tree)
      node = locator.at_position(line: 8, column: 3)
      narrowed = index[node].type_of(node)
      expect(narrowed).to eq(Rigor::Type::Combinator.constant_of("hello"))
    end
  end
end
