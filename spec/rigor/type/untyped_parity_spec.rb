# frozen_string_literal: true

require "spec_helper"
require "prism"

# ADR-130 WD2's lint gate. A site that keys a leniency on `untyped` asks `Type::Combinator.untyped?`; spelled raw, it
# misses every facet parity reads as `untyped` (WD1's erased facets), and a plugin-interface value falls out of the
# leniency. The scan reads the AST of `lib/`, `plugins/*/lib` and `examples/*/lib`, so a comment, a string, an operand
# order or a variable name does not hide a form. It flags two classes:
#
# - **a `Top` operand in a comparison or a type test.** `Type::Top`, `Top.instance`, `Combinator.top`, a bare `top`,
#   or an alias any of them was assigned to, as an operand of `is_a?` / `kind_of?` / `instance_of?`, `===`, `==`, `!=`,
#   `equal?`, `eql?`, an Enumerable pattern argument (`grep`, `any?`, `include?`, ...), a `when` or a pattern. A
#   facet is never named here: whatever holds it, a test for `Top` is the raw form. The one exempt shape is the
#   outer-type family test, where the same expression or `case` also tests the same subject for `Dynamic`
#   (`x.is_a?(Type::Dynamic) || x.is_a?(Type::Top)`, `when Type::Dynamic, Type::Top`): `Dynamic[top]` is a
#   `Dynamic`, so the `Top` arm there is the real top type.
# - **`untyped` as an operand or a key.** `Combinator.untyped`, or an alias of it (a constant, an ivar, a local of any
#   name, a bare `untyped`), compared (`==`, `!=`, `equal?`, `eql?`, `===`, `when`), passed to a membership or
#   lookup method (`include?`, `key?`, `index`, `delete`, `[]`, ...), or used as a hash-literal key.
#
# `Combinator` is exempt: `untyped?` is the one test, and `dynamic`'s fold of a `Top` facet is the constructor.
# `ALLOWED` names each other method the scan may not flag, with why. The lint knows these spellings only; the
# behavioural gate (`spec/integration/interface_parity_spec.rb`) is the one that binds.
module UntypedParityLint
  ROOT = File.expand_path("../../..", __dir__)
  TREES = ["lib", *Dir.glob("{plugins,examples}/*/lib", base: ROOT).sort].freeze
  EXEMPT = ["lib/rigor/type/combinator.rb"].freeze

  # `[file, method]` => why a `Top` test there is not an untyped test.
  ALLOWED = {
    ["lib/rigor/type/top.rb", :==] => "the Top carrier's own equality",
    ["lib/rigor/inference/key_presence_guard.rb", :value_may_be_nil?] =>
      "reads a hash-shape value, an outer type; a Dynamic value falls to the `else false` arm"
  }.freeze

  TYPE_TESTS = %i[is_a? kind_of? instance_of?].freeze
  COMPARISONS = %i[== != equal? eql? ===].freeze
  PATTERN_ARGS = %i[grep grep_v any? all? none? one? include? member? count index find_index rindex delete].freeze
  LOOKUPS = (PATTERN_ARGS + %i[key? has_key? value? has_value? fetch dig [] []= assoc rassoc]).freeze
  BOOLEAN_CHAIN = [Prism::AndNode, Prism::OrNode, Prism::ParenthesesNode, Prism::StatementsNode].freeze

  # Scans one file's AST.
  class Scanner
    WRITES = [
      Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode, Prism::ClassVariableWriteNode,
      Prism::GlobalVariableWriteNode, Prism::ConstantWriteNode, Prism::LocalVariableOrWriteNode,
      Prism::InstanceVariableOrWriteNode, Prism::ConstantOrWriteNode
    ].freeze

    def initialize(source)
      @root = Prism.parse(source).value
      @aliases = { top: Set.new, untyped: Set.new }
      collect_aliases
      @hits = []
    end

    # `[line, method, source]` for every raw form.
    def hits
      walk(@root, [], nil)
      @hits
    end

    private

    def walk(node, ancestors, method)
      method = node.name if node.is_a?(Prism::DefNode)
      @hits << [node.location.start_line, method, node.slice.lines.first.strip] if raw?(node, ancestors)
      ancestors.push(node)
      node.compact_child_nodes.each { |child| walk(child, ancestors, method) }
      ancestors.pop
    end

    def raw?(node, ancestors)
      case node
      when Prism::CallNode then raw_call?(node, ancestors)
      when Prism::WhenNode then raw_when?(node, ancestors.last)
      when Prism::InNode then contains_top?(node.pattern) && !family_case?(ancestors.last)
      when Prism::MatchPredicateNode, Prism::MatchRequiredNode then contains_top?(node.pattern)
      when Prism::AssocNode then untyped?(node.key)
      else false
      end
    end

    def raw_call?(node, ancestors)
      args = arguments(node)
      return !family_test?(node, ancestors) if top_test?(node, args)

      (COMPARISONS.include?(node.name) && (untyped?(node.receiver) || args.any? { |a| untyped?(a) })) ||
        (LOOKUPS.include?(node.name) && key_arguments(node.name, args).any? { |a| untyped?(a) })
    end

    def top_test?(node, args)
      ((TYPE_TESTS + COMPARISONS + PATTERN_ARGS).include?(node.name) && args.any? { |a| top?(a) }) ||
        (COMPARISONS.include?(node.name) && top?(node.receiver))
    end

    def arguments(node) = node.arguments&.arguments || []

    # The arguments a lookup reads as keys or patterns: not the value `[]=` stores or the default `fetch` returns.
    def key_arguments(name, args)
      case name
      when :[]= then args[0...-1]
      when :fetch then args.first(1)
      else args
      end
    end

    def raw_when?(node, case_node)
      node.conditions.any? { |c| untyped?(c) } ||
        (node.conditions.any? { |c| top?(c) } && !family_case?(case_node))
    end

    # The outer-type family test: the boolean expression this test sits in also tests its subject for `Dynamic`.
    def family_test?(node, ancestors)
      subject = test_subject(node)
      return false unless subject

      chain = node
      ancestors.reverse_each do |parent|
        break unless BOOLEAN_CHAIN.include?(parent.class) || (parent.is_a?(Prism::CallNode) && parent.name == :!)

        chain = parent
      end
      dynamic_test_subjects(chain).include?(subject)
    end

    def test_subject(node)
      if TYPE_TESTS.include?(node.name) then node.receiver&.slice
      elsif COMPARISONS.include?(node.name)
        top?(node.receiver) ? arguments(node).first&.slice : node.receiver&.slice
      end
    end

    # The subjects `node`'s descendants test for `Dynamic`.
    def dynamic_test_subjects(node)
      descendants(node).filter_map do |current|
        next unless current.is_a?(Prism::CallNode) && TYPE_TESTS.include?(current.name)
        next unless arguments(current).any? { |a| constant?(a, :Dynamic) }

        current.receiver&.slice
      end
    end

    # A `case` that also branches on `Dynamic`, so its `Top` branch sees the real top type.
    def family_case?(case_node)
      clauses = case_node.respond_to?(:conditions) ? case_node.conditions : []
      clauses.any? do |clause|
        tests = clause.is_a?(Prism::WhenNode) ? clause.conditions : [clause.pattern]
        tests.any? { |test| descendants(test).any? { |n| constant?(n, :Dynamic) } }
      end
    end

    def contains_top?(node) = descendants(node).any? { |n| top?(n) }

    def descendants(node)
      all = []
      stack = [node]
      until stack.empty?
        current = stack.pop
        all << current
        stack.concat(current.compact_child_nodes)
      end
      all
    end

    # `Top`, `Type::Top`, `Rigor::Type::Top`, `Top.instance`, `Combinator.top`, a bare `top`, or an alias of one.
    def top?(node)
      case node
      when Prism::ConstantReadNode, Prism::ConstantPathNode then constant?(node, :Top) || alias?(node, :top)
      when Prism::CallNode then top_call?(node)
      else alias?(node, :top)
      end
    end

    def top_call?(node)
      return false unless node.arguments.nil?

      (node.name == :instance && constant?(node.receiver, :Top)) ||
        (node.name == :top && (node.variable_call? || constant?(node.receiver, :Combinator)))
    end

    # `Combinator.untyped`, a bare `untyped`, or an alias of it.
    def untyped?(node)
      case node
      when Prism::CallNode
        node.name == :untyped && node.arguments.nil? && (node.variable_call? || constant?(node.receiver, :Combinator))
      else alias?(node, :untyped)
      end
    end

    # A Rigor type constant: `Name`, `Type::Name`, `Rigor::Type::Name`, `::Rigor::Type::Name`. `RBS::...::Top` is
    # not one.
    def constant?(node, name)
      case node
      when Prism::ConstantReadNode then node.name == name
      when Prism::ConstantPathNode
        node.name == name && (node.parent.nil? || node.parent.slice.match?(/\A(?:::)?(?:Rigor::)?Type\z/))
      else false
      end
    end

    def alias?(node, kind)
      name =
        case node
        when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode, Prism::ClassVariableReadNode,
             Prism::GlobalVariableReadNode, Prism::ConstantReadNode
          node.name
        end
      !name.nil? && @aliases[kind].include?(name)
    end

    # Names assigned a `Top` or an `untyped` reference anywhere in the file, to a fixed point.
    def collect_aliases
      writes = descendants(@root).select { |n| WRITES.include?(n.class) }
      loop do
        before = @aliases.values.sum(&:size)
        writes.each do |write|
          @aliases[:top] << write.name if top?(write.value)
          @aliases[:untyped] << write.name if untyped?(write.value)
        end
        break if @aliases.values.sum(&:size) == before
      end
    end
  end

  module_function

  def scan_source(source) = Scanner.new(source).hits

  def files
    TREES.flat_map { |tree| Dir.glob("#{tree}/**/*.rb", base: ROOT) }.sort - EXEMPT
  end

  def scan
    files.flat_map do |path|
      scan_source(File.read(File.join(ROOT, path))).filter_map do |line, method, text|
        "#{path}:#{line}: #{text}" unless ALLOWED.key?([path, method])
      end
    end
  end
end

RSpec.describe "ADR-130 untyped parity lint" do
  def flagged(source) = UntypedParityLint.scan_source(source).map(&:first)

  it "finds no raw untyped test in lib/, plugins/*/lib or examples/*/lib outside Combinator" do
    expect(UntypedParityLint.scan).to eq([])
  end

  it "scans every tree it names" do
    expect(UntypedParityLint.files).to include("lib/rigor/type.rb", a_string_starting_with("plugins/"),
                                               a_string_starting_with("examples/"))
  end

  it "allows only methods that exist" do
    UntypedParityLint::ALLOWED.each_key do |path, method|
      expect(File.read(File.join(UntypedParityLint::ROOT, path))).to match(/def (self\.)?#{Regexp.escape(method)}[ (]/)
    end
  end

  # The controls: each planted line is one raw spelling and must be flagged; each `ok` line must not be.
  it "flags a Top operand in every comparison and type test, wherever the operand comes from" do
    raw = <<~RUBY.lines
      a.static_facet.is_a?(Type::Top)
      facet.is_a?(Top)
      inner.kind_of?(::Rigor::Type::Top)
      member.static_facet.instance_of?(Rigor::Type::Top)
      Type::Top === x.static_facet
      x.static_facet == Type::Top.instance
      Type::Combinator.top.equal?(f)
      f.eql?(top)
      f != Type::Combinator.top
      types.map(&:static_facet).any?(Type::Top)
      facets.grep(Type::Top)
      facets.include?(Type::Top.instance)
      T = Type::Top; f.is_a?(T)
      @t = Type::Combinator.top; f == @t
      x.static_facet in Type::Top
      x.static_facet => Type::Top
      t.is_a?(Type::Top)
    RUBY

    raw.each_with_index { |line, index| expect(flagged(line)).to eq([1]), "line #{index + 1}: #{line}" }
  end

  it "flags a Top branch of a case that does not branch on Dynamic" do
    expect(flagged(<<~RUBY)).to eq([3])
      case facet
      when Type::Nominal then 1
      when Type::Top then 2
      end
    RUBY
    expect(flagged(<<~RUBY)).to eq([2])
      case facet
      in Type::Top then 1
      end
    RUBY
  end

  it "flags untyped compared, looked up, or used as a key, through any alias" do
    raw = <<~RUBY.lines
      t.equal?(Type::Combinator.untyped)
      t == Rigor::Type::Combinator.untyped
      Type::Combinator.untyped == t
      t != untyped
      types.include?(Type::Combinator.untyped)
      types.index(untyped)
      seen.key?(Type::Combinator.untyped)
      table[Type::Combinator.untyped]
      table.delete(Type::Combinator.untyped)
      table[Type::Combinator.untyped] = 1
      table.fetch(Type::Combinator.untyped, 1)
      { Type::Combinator.untyped => 1 }
      UNTYPED = Type::Combinator.untyped; types.include?(UNTYPED)
      @gradual = Type::Combinator.untyped; t == @gradual
      u = Type::Combinator.untyped; t.equal?(u)
      u = Type::Combinator.untyped; v = u; types.any?(v)
    RUBY

    raw.each_with_index { |line, index| expect(flagged(line)).to eq([1]), "line #{index + 1}: #{line}" }
    expect(flagged(<<~RUBY)).to eq([2])
      case t
      when Type::Combinator.untyped then 1
      end
    RUBY
  end

  it "passes the predicate, the outer-type family test and what is not a comparison" do
    ok = <<~RUBY
      Type::Combinator.untyped?(t)
      x.is_a?(Type::Dynamic) || x.is_a?(Type::Top)
      return true if type.is_a?(Rigor::Type::Dynamic) || type.is_a?(Rigor::Type::Top) || type.is_a?(Rigor::Type::Bot)
      !arg.is_a?(Type::Dynamic) && !arg.is_a?(Type::Top)
      element.is_a?(Type::Dynamic) || element.is_a?(Type::Top) ? nil : element
      x.static_facet.is_a?(Type::Nominal)
      [Type::Combinator.untyped]
      scope.with_local(name, Type::Combinator.untyped)
      args[0] || Type::Combinator.untyped
      bindings[name] = Type::Combinator.untyped
      table.fetch(name, Type::Combinator.untyped)
      t.is_a?(RBS::Types::Bases::Top)
      case type
      when Type::Dynamic, Type::Top then false
      end
      case type
      when Type::Top then :top
      when Type::Dynamic then :dynamic
      end
    RUBY

    expect(flagged(ok)).to eq([])
  end
end
