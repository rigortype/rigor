# frozen_string_literal: true

require "prism"

require_relative "../source/constant_path"
require_relative "../source/node_children"
require_relative "ivar_writer_census"
require_relative "stored_block_call"

module Rigor
  module Inference
    # Issue #1367 — the program facts the `global.*` write rules read, gathered syntactically over every file:
    #
    # - `[:alias, name]` — a global variable name an `alias $new $old` statement names, on either side. After it,
    #   `$new` is `$old`'s variable, setter included, so both rules exempt the name.
    # - `[:defines, name]` — a method named after one of {ANSWER_NAMES} is defined somewhere, in any spelling and on
    #   any receiver: `def`, `def obj.m`, a `class << obj` body, `define_method`, `define_singleton_method`,
    #   `alias`, `alias_method`, `attr_*`, a delegation macro, or the same call through `send`. The
    #   type check does not ask where it lands: an object can reach any of them (`class << nil`, `K = Integer;
    #   class K`, `[Integer].each { |k| k.define_method(:write) }`), so a literal of any class declines.
    # - {DEFINES_ANY} — a definition whose name no literal spells: a computed `define_method` name, a `send` whose
    #   method name is computed, a string `eval` / `class_eval` whose code is interpolated or not a literal, a name
    #   literal whose bytes are not valid in its encoding, or a top-level mixin of a non-constant. A node the
    #   collector fails to read records it too ({Collector#visit}).
    # - `[:refines, name]` / {REFINES_ANY} — the same, inside a `refine` block. A refinement changes what
    #   `respond_to?(:write)` answers where a `using` is in effect, and nothing else the setters consult: an
    #   implicit conversion and a refined `respond_to?` / `respond_to_missing?` ignore it, so these entries are
    #   kept apart from `[:defines, …]`.
    # - `[:main_mixin, name]` — a module a top-level `include`, `prepend` or `extend` mixes into `Object` (or
    #   `main`), as written. A module RBS does not know may carry any method, so it reaches every class.
    # - the instance-variable writer entries of {IvarWriterCensus} (issue #1154): `[:ivar_set, name]`,
    #   `[:ivar_set_class, class_name]` and `[:own_write, class_name, name, path]`.
    # - `[:global_writer, name, method]` — issue #2314: a write of the global `name` inside a method body, keyed by
    #   the `def`'s name (or the literal name a `define_method` block defines), or by nil inside a lambda or a block
    #   its call keeps to run later ({StoredBlockCall}). A write in a block its call runs at once belongs to the
    #   enclosing body. A write at the top level or in a class body records nothing. {GlobalWriterReach} reads these.
    #
    # The census is a `Set` of those frozen entries, merged by union across files, the project pre-pass and the
    # `pre_eval:` files. It is recorded inside descents that already visit every node ({Collector#visit}), never
    # by a walk of its own, except for a `pre_eval:` file ({.scan}).
    module GlobalWriteCensus
      # The methods whose presence lets an object answer a setter: the one it asks `respond_to?` about (`write`),
      # the implicit conversions (`to_str`, `to_int`), and the escape hatches both consult.
      ANSWER_NAMES = %i[write to_str to_int method_missing respond_to_missing? respond_to?].to_set.freeze

      DEFINES_ANY = [:defines_any].freeze
      REFINES_ANY = [:refines_any].freeze

      # `define_method`-family calls whose first argument names the method they define.
      NAMING_CALLS = %i[define_method define_singleton_method alias_method].to_set.freeze
      # Calls every literal argument of which may name a method they define.
      ATTRIBUTE_CALLS = %i[attr attr_reader attr_writer attr_accessor].to_set.freeze
      DELEGATION_CALLS = %i[
        def_delegator def_delegators def_instance_delegator def_instance_delegators def_single_delegator
        def_single_delegators delegate instance_delegate single_delegate
      ].to_set.freeze
      # `delegate_missing_to` defines `method_missing` and `respond_to_missing?` whatever it is handed.
      MISSING_DELEGATION_CALLS = %i[delegate_missing_to].to_set.freeze
      SEND_CALLS = %i[send __send__ public_send].to_set.freeze
      EVAL_CALLS = %i[eval class_eval module_eval instance_eval].to_set.freeze
      MIXIN_CALLS = %i[include prepend extend].to_set.freeze
      DEFINING_CALLS =
        (NAMING_CALLS | ATTRIBUTE_CALLS | DELEGATION_CALLS | MISSING_DELEGATION_CALLS | EVAL_CALLS).freeze
      # Every call name {Collector#visit} reads; any other call is skipped at once.
      VISITED_CALLS = (DEFINING_CALLS | SEND_CALLS | MIXIN_CALLS | %i[import_methods]).freeze
      NO_ARGUMENTS = [].freeze
      NAME_PATTERN = /(?<![\w@$])(?:write|to_str|to_int|method_missing|respond_to_missing\?|respond_to\?)(?![\w?!=])/
      private_constant :NAMING_CALLS, :ATTRIBUTE_CALLS, :DELEGATION_CALLS, :MISSING_DELEGATION_CALLS,
                       :SEND_CALLS, :EVAL_CALLS, :MIXIN_CALLS, :DEFINING_CALLS, :VISITED_CALLS, :NO_ARGUMENTS,
                       :NAME_PATTERN

      EMPTY = Set.new.freeze

      module_function

      def alias_entry(name) = [:alias, name].freeze

      def aliased?(census, name) = census.include?([:alias, name])

      # Whether the program may define one of `names` somewhere, outside a refinement.
      def defines_any_of?(census, names)
        census.include?(DEFINES_ANY) || names.any? { |name| census.include?([:defines, name]) }
      end

      # #1154 — the {IvarWriterCensus} entries of `census`, for the incremental diff and its readers.
      IVAR_KINDS = %i[ivar_set ivar_set_class own_write].to_set.freeze

      def ivar_set_entries(census) = census.select { |entry| IVAR_KINDS.include?(entry.first) }.to_set

      # The negative-dependency key an {IvarWriterCensus} entry fires, the one `UnseenIvarWriters` records.
      def ivar_key(entry)
        case entry.first
        when :ivar_set then "ivar_set:#{entry[1]}"
        when :ivar_set_class then "ivar_set_class:#{entry[1]}"
        else "own_write:#{entry[1]}##{entry[2]}"
        end
      end

      # Whether some refinement may add `write`.
      def refines_write?(census) = census.include?(REFINES_ANY) || census.include?(%i[refines write])

      # The module names the top-level mixins spell.
      def main_mixins(census) = census.filter_map { |entry| entry[1] if entry[0] == :main_mixin }

      # Issue #2158 — the `global_census:` dependency key a census entry moves, without the kind prefix: `alias:$x`,
      # `defines:write`, `refines:write`, `defines_any`, `refines_any`, and `main_mixin` for every top-level mixin: its
      # reader asks about each, and one shared key is a deliberate precision trade-off (a mixin moving anywhere
      # re-checks every write that read them). The rules that read the census record these keys
      # (`CheckRules#record_global_census`), and `Analysis::Incremental.changed_global_census_keys` fires them for
      # every entry that appeared in or vanished from a file's census.
      def dependency_key(entry)
        case entry
        when DEFINES_ANY then "defines_any"
        when REFINES_ANY then "refines_any"
        else entry[0] == :main_mixin ? "main_mixin" : "#{entry[0]}:#{entry[1]}"
        end
      end

      # A standalone walk, for a file no existing descent visits (a `pre_eval:` entry).
      def scan(root)
        collector = Collector.new(InEffectRefinements.new(root))
        walk(root, collector, true)
        collector.census.freeze
      end

      def walk(node, collector, top_level)
        return unless node.is_a?(Prism::Node)

        collector.visit(node, top_level: top_level)
        inner = top_level && !(node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode))
        node.rigor_each_child { |child| walk(child, collector, inner) }
      end
      private_class_method :walk

      # Accumulates one file's census, fed each node of a pre-order descent. `top_level` says whether the node sits
      # outside every `class` / `module` body; it is the host walk's to track. `refine` blocks are remembered by
      # offset as they are met, so a node inside one is known without the host walk tracking it. `in_effect` is the
      # file's {InEffectRefinements}: a `refine` it places where `self` is a class is the class's own method, so its
      # block is not a refinement (issue #1689).
      class Collector
        attr_reader :census

        def initialize(in_effect)
          @census = Set.new
          @refine_ranges = []
          @ivar_writers = IvarWriterCensus.new(@census)
          @in_effect = in_effect
          @bodies = []
        end

        # A node the collector cannot read must not fail the analysis of its file, nor of every file the pre-pass
        # feeds: the census then counts it as a definition of every name, which only declines a report.
        # `owner` is the qualified name of the class whose body the node sits in, for {IvarWriterCensus} (nil where
        # the host walk does not track it, or no class owns an instance there).
        def visit(node, top_level:, owner: nil)
          @ivar_writers.visit(node, owner)
          visit_global_writer(node)
          case node
          when Prism::AliasGlobalVariableNode then visit_global_alias(node)
          when Prism::DefNode then record(node, node.name)
          when Prism::AliasMethodNode then record_argument(node, node.new_name)
          when Prism::CallNode then visit_call(node, top_level)
          end
        rescue StandardError
          @census << DEFINES_ANY
        end

        private

        # Issue #2314 — tracks the method bodies, lambdas and stored blocks of a pre-order descent as flat
        # `start, end, label` triples (`@bodies`, innermost last), and records a global write inside one
        # ({GlobalWriterReach}). A body ending before the write starts is closed. Only those nodes read their location.
        def visit_global_writer(node)
          case node
          when Prism::DefNode then open_body(node, node.name)
          when Prism::LambdaNode then open_body(node, nil)
          when Prism::CallNode then open_stored_block(node)
          when Prism::GlobalVariableWriteNode, Prism::GlobalVariableOrWriteNode, Prism::GlobalVariableAndWriteNode,
               Prism::GlobalVariableOperatorWriteNode, Prism::GlobalVariableTargetNode
            record_global_writer(node)
          end
        end

        def record_global_writer(node)
          start = node.location.start_offset
          bodies = @bodies
          bodies.pop(3) while !bodies.empty? && bodies[-2] <= start
          index = bodies.size - 3
          index -= 3 while index >= 0 && !(bodies[index] <= start && start < bodies[index + 1])
          @census << [:global_writer, node.name, bodies[index + 2]].freeze if index >= 0
        end

        def open_body(node, label)
          location = node.location
          @bodies.push(location.start_offset, location.end_offset, label)
        end

        def open_stored_block(node)
          block = node.block
          return unless block.is_a?(Prism::BlockNode) && StoredBlockCall.stores_block?(node)

          definer = %i[define_method define_singleton_method].include?(node.name)
          open_body(block, definer ? literal_name(node.arguments&.arguments&.first) : nil)
        end

        def visit_global_alias(node)
          [node.new_name, node.old_name].each do |side|
            @census << GlobalWriteCensus.alias_entry(side.name) if side.is_a?(Prism::GlobalVariableReadNode)
          end
        end

        def visit_call(node, top_level)
          remember_refine(node)
          name = node.name
          return unless VISITED_CALLS.include?(name)

          arguments = node.arguments&.arguments || NO_ARGUMENTS
          if SEND_CALLS.include?(name)
            return if arguments.empty?

            # A method name no literal spells (computed, or with bytes invalid in its encoding) may be any of them. A
            # literal one is read as that call written directly: `send(:include, M)` at the top level is a mixin, and
            # `send(:size)` defines nothing.
            first = literal_name(arguments.first)
            return @census << any_entry(node) if first.nil?

            name = first
            arguments = arguments.drop(1)
          end
          visit_defining_call(node, name, arguments)
          visit_main_mixin(node, arguments) if top_level && MIXIN_CALLS.include?(name) && self_receiver?(node)
        end

        def visit_defining_call(node, name, arguments)
          if NAMING_CALLS.include?(name)
            record_argument(node, arguments.first)
          elsif ATTRIBUTE_CALLS.include?(name) || DELEGATION_CALLS.include?(name)
            arguments.each { |argument| record_every_literal(node, argument) }
          elsif MISSING_DELEGATION_CALLS.include?(name)
            record(node, :method_missing)
            record(node, :respond_to_missing?)
          elsif EVAL_CALLS.include?(name)
            # Only the first argument is code; the rest are a binding, a file name and a line number.
            record_eval_text(node, arguments.first) unless arguments.empty?
          elsif name == :import_methods && inside_refine?(node)
            @census << REFINES_ANY
          end
        end

        # A top-level `include M` / `prepend M` / `extend M` mixes M into `Object` (or `main`).
        def visit_main_mixin(node, arguments)
          arguments.each do |argument|
            constant = Source::ConstantPath.qualified_name(argument) if constant_node?(argument)
            @census << (constant ? [:main_mixin, constant.delete_prefix("::").freeze].freeze : any_entry(node))
          end
        end

        def record(node, name)
          return unless ANSWER_NAMES.include?(name)

          @census << [inside_refine?(node) ? :refines : :defines, name].freeze
        end

        # A literal method name, or any name when the argument spells none.
        def record_argument(node, argument)
          name = literal_name(argument)
          name ? record(node, name) : @census << any_entry(node)
        end

        def record_every_literal(node, argument)
          case argument
          when Prism::SymbolNode, Prism::StringNode then record_argument(node, argument)
          when Prism::ArrayNode then argument.elements.each { |element| record_every_literal(node, element) }
          when Prism::KeywordHashNode, Prism::HashNode
            argument.elements.each { |pair| record_every_literal(node, pair) }
          when Prism::AssocNode
            record_every_literal(node, argument.key)
            record_every_literal(node, argument.value)
          else @census << any_entry(node)
          end
        end

        def record_eval_text(node, argument)
          if argument.is_a?(Prism::StringNode) && argument.unescaped.valid_encoding?
            argument.unescaped.scan(NAME_PATTERN) { |name| record(node, name.to_sym) }
          else
            @census << any_entry(node)
          end
        end

        def any_entry(node) = inside_refine?(node) ? REFINES_ANY : DEFINES_ANY

        # The name a Symbol or String literal spells, or nil for any other node and for a literal whose bytes are
        # not valid in its encoding, which names no method Ruby can define.
        def literal_name(argument)
          return unless argument.is_a?(Prism::SymbolNode) || argument.is_a?(Prism::StringNode)

          text = argument.unescaped
          text.to_sym if text.valid_encoding?
        end

        def constant_node?(node) = node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

        def self_receiver?(node) = node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)

        def remember_refine(node)
          return unless ScopeIndexer.refine_call?(node) && !@in_effect.class_body_refine?(node)

          location = node.block.location
          @refine_ranges << (location.start_offset...location.end_offset)
        end

        def inside_refine?(node)
          offset = node.location.start_offset
          @refine_ranges.any? { |range| range.cover?(offset) }
        end
      end
    end
  end
end
