# frozen_string_literal: true

require "prism"

require_relative "../source/node_walker"
require_relative "../type"
require_relative "block_parameter_binder"
require_relative "captured_locals"
require_relative "index_write_widening"
require_relative "mutation_widening"
require_relative "unknown_store_widening"

module Rigor
  module Inference
    # The index `||=` sites of a repeating block body whose slot an EARLIER run of the body may already have
    # filled. `StatementEvaluator#index_compound_write_value` reads a `||=` whose slot types as a lone `Dynamic`
    # as the memoization idiom and answers the rvalue, on the ADR-5 reading that nothing the analyzer saw set
    # the slot. A block-return pass types every run of the body from one entry scope, so under it that reading
    # is wrong for a slot an earlier run stored into: the per-element fold's second position of
    # `cache = {}; [1, 2].find { |e| (cache[:first] ||= e) == 2 }` answered its own `2`, where Ruby keeps the
    # first iteration's `1`, folded `find` to `2` and reported `found == 2` always-truthy. The pass marks the
    # sites this module returns (`Scope#with_repeated_or_writes`), and the reading is withheld at a marked site.
    #
    # The mark is per site, not per receiver, because nothing about the receiver's type can say that its slot
    # was filled: `{}` widens to `Hash[Dynamic[top], Dynamic[top]]`, a bare `Hash.new` is not widened at all, and
    # a constant, class variable, attribute reader or nested memo (`(cache[:a] ||= {})[:b] ||= e`) is no binding
    # the fold rebinds. A narrowing or a rebind of the receiver's variable leaves the mark where it is.
    #
    # Every `||=` in the body is marked (at any depth, short of a nested `def` body, which runs only when called)
    # except one whose receiver is fresh at every run — a hash or array literal, or a `.new` call on a constant —
    # and one the pass shows no earlier run can reach:
    #
    # - It must be ISOLATED ({.isolated?}): no other store in the body can fill its slot.
    # - Under the per-element fold its rvalue is one position's, so it must also sit at the body's own level (not
    #   in a nested block or loop, which runs it more than once per position) and take a key whose value differs
    #   at every position ({.distinct_keys?}): `pool = {}; %w[a b].map { |s| pool[s] ||= s.upcase }` stores each
    #   position under its own key, so the memo reading still types `["A", "B"]`.
    # - The generic block-return pass types the rvalue from the signature's parameter type, which covers every
    #   run's store, so an isolated site is left unmarked there: `words.map { |w| pool[w] ||= w }` keeps
    #   `Array[String]`. Two sites storing different rvalues into one slot are not isolated.
    module RepeatedOrWrites
      # A body walk's findings: the `||=` sites whose receiver is not fresh, every store node whose receiver is
      # not fresh (those sites included), and the `||=` sites at the body's own level.
      Scan = Data.define(:or_writes, :stores, :top_level)

      STORE_NODES = IndexWriteWidening::CONTENT_WRITE_NODE_CLASSES

      # The nodes whose children run more than once for each run of the body that contains them.
      REPEATING_NODES = Set[
        Prism::BlockNode, Prism::LambdaNode, Prism::WhileNode, Prism::UntilNode, Prism::ForNode
      ].freeze

      # The written forms a key expression may not contain; see {.fixed_parameter_key?}.
      KEY_WRITE_NODES = (CapturedLocals::LOCAL_WRITE_NODES | CapturedLocals::NON_LOCAL_WRITE_NODES).freeze

      # The other nodes a key expression may not contain: a variable the body can rebind between positions, or a
      # block or lambda.
      KEY_UNFIXED_NODES = Set[
        Prism::InstanceVariableReadNode, Prism::ClassVariableReadNode, Prism::GlobalVariableReadNode,
        Prism::BlockNode, Prism::LambdaNode
      ].freeze

      NONE = [].freeze
      private_constant :STORE_NODES, :REPEATING_NODES, :KEY_WRITE_NODES, :KEY_UNFIXED_NODES, :NONE

      module_function

      # @param block — the repeating block.
      # @param stores — {CapturedLocals.content_mutations} of the block (with `non_locals: true`): the captured
      #   variables its body mutates in place, each with its sites.
      # @param scope — the call-site scope, in which a per-element fold's positions bind their parameters.
      # @param element_types — the per-element fold's position types, one per position; nil for the generic
      #   block-return pass.
      # @return the `IndexOrWriteNode` sites to mark, empty for the overwhelmingly common body with none.
      def sites(block, stores, scope, element_types: nil)
        body = block.body
        # One source slice is far cheaper than the walk, and a body that spells no `||=` holds no such site.
        return NONE if body.nil? || !body.slice.include?("||=")

        found = scan(body)
        return NONE if found.or_writes.empty?

        attribution = attribution(stores)
        found.or_writes.reject do |node|
          next false unless isolated?(node, found, attribution, stores)

          element_types.nil? ||
            (found.top_level.key?(node) && distinct_keys?(block, node, element_types, scope))
        end
      end

      def scan(body)
        found = Scan.new(or_writes: [], stores: [], top_level: {}.compare_by_identity)
        walk(body, true, found)
        found
      end

      def walk(node, top_level, found)
        return unless node.is_a?(Prism::Node)
        return if node.is_a?(Prism::DefNode)

        record(node, top_level, found)
        return if node.is_a?(Prism::DefinedNode)

        nested_level = top_level && !REPEATING_NODES.include?(node.class)
        node.rigor_each_child { |child| walk(child, nested_level, found) }
      end

      def record(node, top_level, found)
        return unless store_node?(node)
        return if fresh_receiver?(node.receiver)

        found.stores << node
        return unless node.is_a?(Prism::IndexOrWriteNode)

        found.or_writes << node
        found.top_level[node] = true if top_level
      end

      def store_node?(node)
        return true if STORE_NODES.include?(node.class)

        node.is_a?(Prism::CallNode) && (node.name == :[]= || MutationWidening::SHAPE_MUTATORS.include?(node.name))
      end

      # A receiver that evaluates to a new object at every run: a hash or array literal, or `.new` called on a
      # constant.
      def fresh_receiver?(receiver)
        case receiver
        when Prism::HashNode, Prism::ArrayNode then true
        when Prism::CallNode
          receiver.name == :new &&
            (receiver.receiver.is_a?(Prism::ConstantReadNode) || receiver.receiver.is_a?(Prism::ConstantPathNode))
        else false
        end
      end

      # `{ node => [name, ...] }` for every site {CapturedLocals.content_mutations} files under a captured name.
      def attribution(stores)
        stores.each_with_object({}.compare_by_identity) do |(name, sites), by_node|
          sites.each do |site|
            node = site.is_a?(UnknownStoreWidening::CalleeStore) ? site.call : site
            (by_node[node] ||= []) << name
          end
        end
      end

      # True when no other store in the body can fill `node`'s slot. A site filed under captured names is isolated
      # when it is the only site of each of them, callee stores included, and every store in the body is filed
      # under some captured name (a store the scan cannot attribute may reach any object). Any other site — its
      # receiver a constant, an attribute reader, a block parameter — is isolated only as the body's sole store.
      def isolated?(node, found, attribution, stores)
        names = attribution[node]
        return found.stores.size == 1 if names.nil?

        names.all? { |name| stores[name].size == 1 } && found.stores.all? { |store| attribution.key?(store) }
      end

      # True when `node`'s key is a distinct value at every position of the per-element fold, so no position reads
      # a slot an earlier one stored. One position has no earlier one. Otherwise the key must be a single index
      # argument that reads no variable but block parameters the body never writes ({.fixed_parameter_key?}), so
      # typing it in each position's parameter binding is typing what the position evaluates. Every answer must
      # be a `Constant` of one class — `Symbol`, `String`, or a non-negative `Integer`, since a negative index
      # names a slot a non-negative one may name — and no two may be equal. A key that fails to type is not shown
      # distinct, so the site stays marked, the wider answer.
      def distinct_keys?(block, node, element_types, scope)
        return true if element_types.size <= 1

        key = sole_key(node)
        return false if key.nil? || !fixed_parameter_key?(key, block)

        values = element_types.map do |element_type|
          type = BlockParameterBinder.new(expected_param_types: [element_type]).bind_onto(block, scope).type_of(key)
          return false unless type.is_a?(Type::Constant)

          type.value
        end
        distinct_values?(values)
      rescue StandardError
        false
      end

      def sole_key(node)
        arguments = node.arguments&.arguments
        return nil unless arguments&.size == 1 && node.block.nil?

        key = arguments.first
        key.is_a?(Prism::SplatNode) || key.is_a?(Prism::KeywordHashNode) ? nil : key
      end

      # True when `key` reads no variable but the block's own parameters, none of which the body writes, and
      # contains no write, instance-, class- or global-variable read, block or lambda.
      def fixed_parameter_key?(key, block)
        parameters = CapturedLocals.introduced_locals(block)
        written = written_locals(block.body)
        Source::NodeWalker.each(key) do |node|
          return false if KEY_WRITE_NODES.include?(node.class) || KEY_UNFIXED_NODES.include?(node.class)
          next unless node.is_a?(Prism::LocalVariableReadNode)
          return false unless node.depth.zero? && parameters.include?(node.name) && !written.include?(node.name)
        end
        true
      end

      def written_locals(body)
        names = Set.new
        Source::NodeWalker.each(body) do |node|
          names << node.name if CapturedLocals::LOCAL_WRITE_NODES.include?(node.class)
        end
        names
      end

      KEY_CLASSES = [Symbol, String, Integer].freeze
      private_constant :KEY_CLASSES

      def distinct_values?(values)
        key_class = KEY_CLASSES.find { |candidate| values.first.is_a?(candidate) }
        return false if key_class.nil? || !values.all?(key_class)
        return false if key_class == Integer && values.any?(&:negative?)

        values.uniq.size == values.size
      end
    end
  end
end
