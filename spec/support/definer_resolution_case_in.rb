# frozen_string_literal: true

require "prism"

# The Prism scan behind `spec/rigor/inference/definer_resolution_case_in_spec.rb`: finds every
# `DefinerResolution.resolve` call and reports the ones that are not the direct predicate of a `case/in` with
# exactly the arms `Known(...)`, `UNKNOWN` and `ABSENT`, and no `else`. It also reports any other reference to the
# `DefinerResolution` constant (an `include`, an `extend`, `DefinerResolution.method(:resolve)`, a stored `UNKNOWN`)
# that is neither the receiver of such a call nor a pattern constant, and any `send(:resolve)` family call.
module DefinerResolutionCaseIn
  ARMS = %i[Known UNKNOWN ABSENT].freeze
  REACHING_CALLS = %i[send public_send __send__ method instance_method].freeze
  CONSTANT = :DefinerResolution

  # Marks every constant node of a pattern as an approved reference.
  class PatternConstants < Prism::Visitor
    def initialize(allowed)
      super()
      @allowed = allowed
    end

    def visit_constant_read_node(node) = (@allowed[node] = true)

    def visit_constant_path_node(node)
      @allowed[node] = true
      super
    end
  end

  # Finds `DefinerResolution.resolve` calls and the ones that are a `case/in` predicate with the three arms.
  class Scan < Prism::Visitor
    attr_reader :violations

    def initialize(path)
      super()
      @path = path
      @violations = []
      @blessed = {}.compare_by_identity
      @allowed = {}.compare_by_identity
    end

    def visit_in_node(node)
      node.pattern.accept(PatternConstants.new(@allowed))
      super
    end

    def visit_module_node(node)
      node.constant_path.accept(PatternConstants.new(@allowed))
      super
    end

    def visit_constant_read_node(node)
      check_constant(node)
      super
    end

    def visit_constant_path_node(node)
      check_constant(node)
      super
    end

    def visit_case_match_node(node)
      if resolve_call?(node.predicate)
        @blessed[node.predicate] = true
        @allowed[node.predicate.receiver] = true
        problem = arms_problem(node)
        @violations << "#{@path}:#{node.location.start_line}: #{problem}" if problem
      end
      super
    end

    def visit_call_node(node)
      if resolve_call?(node) && !@blessed[node]
        @violations << "#{@path}:#{node.location.start_line}: DefinerResolution.resolve is not a case/in predicate"
      end
      @violations << "#{@path}:#{node.location.start_line}: reaches `resolve` by name" if reaches_resolve?(node)
      super
    end

    private

    def check_constant(node)
      return unless node.name == CONSTANT && !@allowed[node]

      @violations << "#{@path}:#{node.location.start_line}: DefinerResolution is referenced outside a resolve " \
                     "call or a case/in pattern"
    end

    def reaches_resolve?(node)
      return false unless REACHING_CALLS.include?(node.name)

      first = node.arguments&.arguments&.first
      first.is_a?(Prism::SymbolNode) && first.unescaped == "resolve"
    end

    def resolve_call?(node)
      return false unless node.is_a?(Prism::CallNode) && node.name == :resolve

      receiver = node.receiver
      receiver.respond_to?(:name) && receiver.name == :DefinerResolution
    end

    def arms_problem(node)
      return "case/in over DefinerResolution.resolve has an else arm" if node.else_clause

      names = node.conditions.map { |arm| arm_name(arm.pattern) }
      return nil if names.sort == ARMS.sort

      "case/in over DefinerResolution.resolve must have exactly the arms #{ARMS.join(', ')} (has #{names.inspect})"
    end

    def arm_name(pattern)
      constant = pattern.respond_to?(:constant) && pattern.constant ? pattern.constant : pattern
      constant.respond_to?(:name) ? constant.name : nil
    end
  end

  def self.violations_in(source, path = "(source)")
    scan = Scan.new(path)
    Prism.parse(source).value.accept(scan)
    scan.violations
  end
end
