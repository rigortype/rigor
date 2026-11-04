# frozen_string_literal: true

require "spec_helper"
require "prism"

# ADR-130 WD2's lint gate. A site that keys a leniency on `untyped` asks `Type::Combinator.untyped?`; spelled raw, it
# misses every facet parity reads as `untyped` (WD1's erased facets), and the plugin-interface value it sees falls out
# of the leniency. The raw forms are the two WD2 names:
#
# - a `Dynamic`'s facet tested for `Top` (`x.static_facet.is_a?(Type::Top)`, `facet.is_a?(Top)`, `Top === facet`,
#   `case facet when Type::Top`);
# - a type compared with `Combinator.untyped` (`==`, `!=`, `equal?`, `eql?`, `===`, `when`), the alias a local named
#   `untyped` holds included.
#
# `Combinator` itself is exempt: `untyped?` is the one test, and `dynamic`'s fold of a `Top` facet is the constructor.
# The scan reads the AST, so a comment, a string or the operand order does not hide a form. It only knows these
# spellings; the behavioural gate (`spec/integration/interface_parity_spec.rb`) is the one that binds.
module UntypedParityLint
  LIB = File.expand_path("../../../lib", __dir__)
  EXEMPT = [File.join(LIB, "rigor/type/combinator.rb")].freeze
  TYPE_TESTS = %i[is_a? kind_of? instance_of?].freeze
  COMPARISONS = %i[== != equal? eql? ===].freeze

  # Collects `[line, source]` for every raw form in one file's AST.
  class Visitor < Prism::Visitor
    attr_reader :hits

    def initialize
      super
      @hits = []
    end

    def visit_call_node(node)
      hit(node) if facet_top_test?(node) || untyped_comparison?(node)
      super
    end

    def visit_case_node(node)
      hit(node) if node.predicate && node.conditions.any? { |w| when_raw?(node.predicate, w) }
      super
    end

    private

    def hit(node)
      @hits << [node.location.start_line, node.slice.lines.first.strip]
    end

    def facet_top_test?(node)
      arg = sole_argument(node)
      return false unless arg

      (TYPE_TESTS.include?(node.name) && facet?(node.receiver) && top?(arg)) ||
        (node.name == :=== && top?(node.receiver) && facet?(arg))
    end

    def untyped_comparison?(node)
      arg = sole_argument(node)
      COMPARISONS.include?(node.name) && arg && (untyped_ref?(node.receiver) || untyped_ref?(arg))
    end

    def when_raw?(predicate, when_node)
      when_node.conditions.any? { |c| untyped_ref?(c) || (facet?(predicate) && top?(c)) }
    end

    def sole_argument(node)
      args = node.arguments&.arguments
      args.first if args&.size == 1
    end

    # `x.static_facet`, or a bare name that says it holds one (`facet = member.static_facet`). A bare name is a local
    # read in its method and a variable call in a parsed fragment; both count.
    def facet?(node)
      case node
      when Prism::CallNode then node.name == :static_facet || (node.variable_call? && node.name.end_with?("facet"))
      when Prism::LocalVariableReadNode then node.name.end_with?("facet")
      else false
      end
    end

    def top?(node)
      constant_named?(node, :Top)
    end

    # `Combinator.untyped` under any qualification, or a bare `untyped` (the local alias it is usually held in).
    def untyped_ref?(node)
      case node
      when Prism::CallNode
        node.name == :untyped && node.arguments.nil? &&
          (constant_named?(node.receiver, :Combinator) || node.variable_call?)
      when Prism::LocalVariableReadNode then node.name == :untyped
      else false
      end
    end

    def constant_named?(node, name)
      case node
      when Prism::ConstantReadNode, Prism::ConstantPathNode then node.name == name
      else false
      end
    end
  end

  module_function

  def scan_source(source)
    visitor = Visitor.new
    Prism.parse(source).value.accept(visitor)
    visitor.hits
  end

  def scan_lib
    Dir.glob(File.join(LIB, "**/*.rb")).flat_map do |path|
      next [] if EXEMPT.include?(path)

      scan_source(File.read(path)).map { |line, text| "#{path.delete_prefix("#{LIB}/")}:#{line}: #{text}" }
    end
  end
end

RSpec.describe "ADR-130 untyped parity lint" do
  it "finds no raw untyped test in lib/ outside Combinator" do
    expect(UntypedParityLint.scan_lib).to eq([])
  end

  # The control: each raw spelling is caught, and the routed form is not, so an empty scan above is a reading.
  it "catches every raw spelling it names, in either operand order, and passes the predicate" do
    planted = <<~RUBY
      a.static_facet.is_a?(Type::Top)
      facet.is_a?(Top)
      member.static_facet.instance_of?(::Rigor::Type::Top)
      Type::Top === x.static_facet
      case static_facet
      when Type::Top then 1
      end
      t.equal?(Type::Combinator.untyped)
      t == Rigor::Type::Combinator.untyped
      Type::Combinator.untyped == t
      t != untyped
      case t
      when Type::Combinator.untyped then 1
      end
      Type::Combinator.untyped?(t)
      t.is_a?(Type::Top)
      x.static_facet.is_a?(Type::Nominal)
      [Type::Combinator.untyped]
    RUBY
    lines = UntypedParityLint.scan_source(planted).map(&:first)

    expect(lines).to eq([1, 2, 3, 4, 5, 8, 9, 10, 11, 12])
  end
end
