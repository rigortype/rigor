# frozen_string_literal: true

require "prism"

require_relative "../source/constant_path"
require_relative "../source/node_children"
require_relative "catalog"
require_relative "file_collection"
require_relative "label_set"
require_relative "mutation_classifier"
require_relative "origin"
require_relative "summary"

module Rigor
  module Effects
    # Scans one **effect unit** — a method body — into its direct {Summary} plus the unresolved edges the
    # propagator later closes over (ADR-103 WD4).
    #
    # Two rules shape the walk:
    #
    # - **Containment.** A block literal's origins always join the enclosing method's summary, whether the
    #   callee invokes the block now, later, or never; an envelope is a contract about the method's *code*.
    #   So the walk simply descends into `BlockNode`s and stops only at a nested `def` or at a
    #   `define_method` with a literal name, both of which are units of their own.
    # - **Observation.** Everything the walk knows about a receiver comes from what the typer already
    #   decided at that call node ({Collector::CallRecord}); the scan resolves nothing, walks no callee,
    #   and touches no `Scope`.
    #
    # What it cannot prove it taints, and a taint is never a finding — the summary reads "these effects,
    # and possibly more".
    class UnitScan
      # `$~` and friends are frame-local, not global state: a read of one is not `global.read`. (Prism
      # gives `$1` and `$&` node types of their own, so only the named specials need listing.)
      FRAME_LOCAL_GLOBALS = %w[$~ $_ $& $` $' $+ $!].to_set.freeze

      REFLECTIVE_SEND = %i[send public_send __send__].to_set.freeze

      GLOBAL_READ = LabelSet.new(["global.read"])
      GLOBAL_WRITE = LabelSet.new(["global.write"])
      MUTATE_STATIC = LabelSet.new(["mutate.static"])
      MUTATE_SELF = LabelSet.new(["mutate.self"])
      IO_PROCESS = LabelSet.new(["io.process"])

      # `define_method(:literal) { … }` — the block becomes `literal`'s body (WD14), so the call is a unit
      # declaration wherever it appears: in a class body it is the only way that method exists, and inside
      # another method it is a definition the enclosing method performs (`mutate.static`) rather than code
      # the enclosing method contains. A non-literal name has no key to file the block under, so it stays
      # contained in the enclosing method and this returns nil.
      #
      # @return [Array, nil] `[name, singleton, body, parameters]`
      def self.define_method_unit(node)
        return nil unless node.name == :define_method && node.receiver.nil?

        first = node.arguments&.arguments&.first
        return nil unless first.is_a?(Prism::SymbolNode) && first.unescaped

        block = node.block
        return nil unless block.is_a?(Prism::BlockNode)

        [first.unescaped, false, block.body, block.parameters]
      end

      # @param singleton [Boolean] whether the unit's `self` is the class object (`def self.x`,
      #   `class << self`) — the axis that separates `mutate.self` from `mutate.static` on an ivar write
      # @param block_parameter [String, nil] the unit's `&blk` parameter name, if any; a call on it is
      #   forwarding, not an opaque callable
      # @param calls [Hash] node-identity table of {Collector::CallRecord}s
      def initialize(singleton:, parameters:, block_parameter:, owned_locals:, calls:)
        @singleton = singleton
        @block_parameter = block_parameter
        @calls = calls
        @mutation = MutationClassifier.new(
          singleton: singleton, parameters: parameters, owned_locals: owned_locals
        )
        @bundles = {}
        @causes = []
        @edges = []
        @nested = []
      end

      # Units discovered inside this one — a nested `def`, or a `define_method` with a literal name whose
      # block becomes that method's body. Each is `[name, singleton, body_node, parameters_node]`.
      attr_reader :nested

      # Walks `body` and returns `[Summary, edges]`.
      def run(body)
        walk(body)
        [Summary.new(bundles: @bundles, exhaustive: @causes.empty?, causes: @causes), @edges]
      end

      private

      def add(origin, labels)
        return if labels.empty?

        @bundles[origin] = @bundles.key?(origin) ? @bundles[origin].join(labels) : labels
      end

      def taint(cause, detail = nil)
        @causes << [cause, detail]
      end

      def walk(node)
        return unless node.is_a?(Prism::Node)
        return if unit_boundary?(node)

        visit(node)
        node.rigor_each_child { |child| walk(child) }
      end

      # A nested unit is recorded and NOT descended into: its body belongs to its own summary, and the
      # enclosing method gets only the `mutate.static` of having defined it.
      def unit_boundary?(node)
        case node
        when Prism::DefNode
          @nested << [node.name.to_s, !node.receiver.nil?, node.body, node.parameters]
          true
        when Prism::CallNode
          declared = self.class.define_method_unit(node)
          return false unless declared

          @nested << declared
          add(Origin.construct("define-method"), MUTATE_STATIC)
          true
        else
          false
        end
      end

      def visit(node) # rubocop:disable Metrics/CyclomaticComplexity
        case node
        when Prism::CallNode then visit_call(node)
        when Prism::XStringNode, Prism::InterpolatedXStringNode
          add(Origin.construct("xstring"), IO_PROCESS)
        when Prism::GlobalVariableReadNode
          add(Origin.construct("gvar-read"), GLOBAL_READ) unless FRAME_LOCAL_GLOBALS.include?(node.name.to_s)
        when Prism::GlobalVariableWriteNode, Prism::GlobalVariableOperatorWriteNode,
             Prism::GlobalVariableOrWriteNode, Prism::GlobalVariableAndWriteNode
          add(Origin.construct("gvar-write"), GLOBAL_WRITE)
        when Prism::ClassVariableReadNode
          add(Origin.construct("cvar-read"), GLOBAL_READ)
        when Prism::ClassVariableWriteNode, Prism::ClassVariableOperatorWriteNode,
             Prism::ClassVariableOrWriteNode, Prism::ClassVariableAndWriteNode
          add(Origin.construct("cvar-write"), MUTATE_STATIC)
        when Prism::InstanceVariableWriteNode, Prism::InstanceVariableOperatorWriteNode,
             Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode
          add(Origin.construct("ivar-write"), @singleton ? MUTATE_STATIC : MUTATE_SELF)
        when Prism::AliasMethodNode, Prism::AliasGlobalVariableNode
          add(Origin.construct("alias"), MUTATE_STATIC)
        when Prism::UndefNode
          add(Origin.construct("undef"), MUTATE_STATIC)
        when Prism::IndexOperatorWriteNode, Prism::IndexOrWriteNode, Prism::IndexAndWriteNode,
             Prism::CallOperatorWriteNode, Prism::CallOrWriteNode, Prism::CallAndWriteNode
          classify_mutation(node.receiver)
        end
      end

      def visit_call(node)
        record = @calls[node]
        key = catalog_key(node, record)
        labels = key && Catalog.lookup(key, argument_count: positional_arity(node))
        if labels
          add(Origin.catalogue(key), labels)
        else
          visit_uncatalogued(node, record)
        end
        visit_block_argument(node)
      end

      def visit_uncatalogued(node, record)
        return visit_reflective_send(node, record) if REFLECTIVE_SEND.include?(node.name)

        # A write is a write whatever the receiver's type turns out to be, so ownership is classified
        # first and independently of the taints below: `params[:x] = 1` on an untyped `params` is a proven
        # `mutate.instance` *and* a `dynamic-receiver` taint — "this much, and possibly more".
        classify_mutation(node.receiver) if @mutation.mutating?(node, record&.receiver_class)

        # `opaque-callable` is checked before `dynamic-receiver` because it is the more specific reading of
        # the same site: a `.call` the analyzer cannot follow to a body says *what* was unfollowable, where
        # a bare Dynamic receiver says only that the receiver's class was unknown.
        return taint("opaque-callable") if opaque_callable?(node, record)
        return taint("dynamic-receiver", record.cause) if record&.dynamic

        record_edge(node, record)
      end

      # `send` / `public_send` / `__send__`: a literal selector is an ordinary edge, a computed one is the
      # `dynamic-send` taint.
      def visit_reflective_send(node, record)
        selector = literal_selector(node.arguments&.arguments&.first)
        return taint("dynamic-send") unless selector

        push_edge(record, selector, node.receiver.nil?)
      end

      def literal_selector(node)
        node.unescaped if node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
      end

      # A `.call` the analyzer cannot follow to a body. A call on the unit's own block parameter is
      # forwarding (∅ — the block's effects are accounted at the caller's literal), and a call on a
      # project object resolves as an ordinary edge.
      def opaque_callable?(node, record)
        receiver = node.receiver
        return false unless node.name == :call && receiver
        return false if receiver.is_a?(Prism::LambdaNode)
        return false if receiver.is_a?(Prism::LocalVariableReadNode) && receiver.name.to_s == @block_parameter

        record.nil? || record.receiver_class.nil? || %w[Proc Method].include?(record.receiver_class)
      end

      # The edge is recorded speculatively — only the propagator can say whether `(receiver class,
      # selector)` reaches a project definition — and the taint is decided independently, from the typer's
      # own verdict. The two are not exclusive: a call the typer could not resolve still names a receiver
      # class, and an edge that resolves to nothing is silently dropped rather than tainting, because most
      # such calls are ordinary inherited ones the catalogue simply has no row for.
      def record_edge(node, record)
        self_call = node.receiver.nil?
        push_edge(record, node.name.to_s, self_call)
        return unless self_call && (record.nil? || !record.resolved)

        taint("unresolved-self-call", node.name.to_s)
      end

      def push_edge(record, selector, self_call)
        return if record.nil? || record.receiver_class.nil?

        @edges << FileCollection::Edge.new(
          receiver_class: record.receiver_class, kind: record.kind, selector: selector, self_call: self_call
        )
      end

      def visit_block_argument(node)
        block = node.block
        return unless block.is_a?(Prism::BlockArgumentNode)

        expression = block.expression
        return if expression.nil? || expression.is_a?(Prism::SymbolNode)
        return if expression.is_a?(Prism::LocalVariableReadNode) && expression.name.to_s == @block_parameter

        taint("opaque-callable")
      end

      def classify_mutation(receiver)
        labels = @mutation.label_for(receiver)
        return taint("unknown-ownership") if labels.nil?

        add(Origin.construct("receiver-mutation"), labels)
      end

      # The catalogue key a call would match, spelled from the syntax where the syntax settles it and from
      # the typer's receiver otherwise. Nil when neither does.
      def catalog_key(node, record)
        name = node.name
        receiver = node.receiver
        return "Kernel##{name}" if receiver.nil? || receiver.is_a?(Prism::SelfNode)

        constant = Source::ConstantPath.qualified_name(receiver)
        return "#{constant}#{Catalog::OBJECT_CONSTANTS.include?(constant) ? '#' : '.'}#{name}" if constant
        return nil if record.nil? || record.receiver_class.nil?

        "#{record.receiver_class}#{record.kind == :singleton ? '.' : '#'}#{name}"
      end

      def positional_arity(node)
        node.arguments&.arguments&.count { |argument| !argument.is_a?(Prism::KeywordHashNode) } || 0
      end
    end
  end
end
