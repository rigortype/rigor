# frozen_string_literal: true

require_relative "../../type"
require_relative "regexp_folding"

module Rigor
  module Inference
    module MethodDispatcher
      # Issue #1381 — slice reads of the proven `$~`. On a proven-match edge the flow engine narrows `$~` to
      # `MatchData` and each unconditional group's `$N` to `String` (see `Narrowing#regex_match_predicate_scopes`).
      # The Integer overload of RBS `MatchData#[]` already reads `String`, but the Range and `(start, length)`
      # overloads and `values_at` read `Array[String?]`, and destructuring that binds every slot `String?`.
      # This tier answers those reads with a Tuple, one slot per group, using the rule
      # {RegexpFolding.fold_last_match_group} applies to `Regexp.last_match(N)`: `String` when `$N` is bound,
      # `String?` when it is not (an optional or alternation-reachable group is nil on a successful match).
      # Index 0 is the whole match, always a `String`.
      #
      # Supported, all with compile-time constant Integer arguments:
      #
      # * `$~[a..b]` / `$~[a...b]`
      # * `$~[start, length]`
      # * `$~.values_at(i, j, ...)`
      #
      # The receiver must be the `$~` read itself or a no-argument `Regexp.last_match`: a local MatchData carries
      # no group facts, and the scope's `$N` describe only the frame's current match.
      #
      # The scope does not record the regex's group count, and a slice past the last group is shorter than the
      # range asked for (`$~[1..3]` on a one-group match is `["x"]`) while `values_at` pads with nil. The highest
      # bound `$K` is a lower bound on the count — `Scope#join_bindings` keeps a key only when both sides bind
      # it — so every index must be at most K. Declines (RBS answers) when:
      #
      # - `$~` is not proven non-nil, or no scope is threaded through,
      # - no `$1`..`$9` narrows to `String` (every group optional, no group at all, `when /a/, /b/`),
      # - any index is above K, negative, or not a constant Integer, or a Range bound is nil (endless /
      #   beginless),
      # - the slice is empty.
      #
      # K is read from `$1`..`$9` only: `Scope#forget_match_globals` does not clear `$10` and above (#1384), so a
      # binding there may belong to an earlier match.
      module MatchDataFolding
        MAX_GROUP_GLOBAL = 9
        private_constant :MAX_GROUP_GLOBAL

        module_function

        # @return folded Tuple, or nil to defer.
        def try_dispatch(context)
          receiver = context.receiver
          return nil unless receiver.is_a?(Type::Nominal) && receiver.class_name == "MatchData"

          scope = context.scope
          return nil if scope.nil?
          return nil unless last_match_read?(context.call_node, scope)
          return nil unless RegexpFolding.proven_match?(scope.global(:$~))

          highest = highest_bound_group(scope)
          return nil if highest.nil?

          indices = slot_indices(context.method_name, context.args, highest)
          return nil if indices.nil?

          Type::Combinator.tuple_of(*indices.map { |index| slot_type(index, scope) })
        end

        # The receiver expression reads the frame's current match: `$~`, or `last_match` with no arguments and no block
        # on an expression that types as the core `Regexp` class. A project class that happens to be named `Regexp`
        # (`Foo::Regexp` read as `Regexp` inside `module Foo`) types as its own singleton and does not count.
        def last_match_read?(call_node, scope)
          return false unless call_node.is_a?(Prism::CallNode)

          receiver = call_node.receiver
          case receiver
          when Prism::GlobalVariableReadNode
            receiver.name == :$~
          when Prism::CallNode
            receiver.name == :last_match && receiver.arguments.nil? && receiver.block.nil? &&
              regexp_class?(receiver.receiver, scope)
          else
            false
          end
        end

        def regexp_class?(node, scope)
          return false if node.nil?

          type = scope.type_of(node)
          type.is_a?(Type::Singleton) && type.class_name == "Regexp"
        end

        # The highest N in 1..9 whose `$N` is narrowed to `String`, or nil when none is.
        def highest_bound_group(scope)
          MAX_GROUP_GLOBAL.downto(1).find { |index| string_global?(scope.global(:"$#{index}")) }
        end

        def string_global?(type)
          type.is_a?(Type::Nominal) && type.class_name == "String"
        end

        # The group indices the call reads, in result order, or nil when the call shape is not folded or any index
        # falls outside `0..highest`.
        def slot_indices(method_name, args, highest)
          indices =
            case method_name
            when :[] then index_slice(args)
            when :values_at then values_at_indices(args)
            end
          return nil if indices.nil? || indices.none?
          return nil unless indices.all? { |index| index.between?(0, highest) }

          indices.to_a
        end

        # `[range]` or `[start, length]`. A single Integer index is left to RBS, which already reads `String`.
        def index_slice(args)
          case args.size
          when 1 then range_indices(args.first)
          when 2 then start_length_indices(*args)
          end
        end

        def range_indices(arg)
          range = constant_value(arg)
          return nil unless range.is_a?(Range)

          first = range.begin
          last = range.end
          return nil unless first.is_a?(Integer) && last.is_a?(Integer)
          return nil if first.negative? || last.negative?

          range
        end

        def start_length_indices(start_arg, length_arg)
          start = constant_value(start_arg)
          length = constant_value(length_arg)
          return nil unless start.is_a?(Integer) && length.is_a?(Integer)
          return nil if start.negative? || length.negative?

          start...(start + length)
        end

        def values_at_indices(args)
          indices = args.map { |arg| constant_value(arg) }
          indices.all?(Integer) ? indices : nil
        end

        def constant_value(type)
          type.is_a?(Type::Constant) ? type.value : nil
        end

        def slot_type(index, scope)
          return Type::Combinator.nominal_of("String") if index.zero?

          RegexpFolding.fold_last_match_group(Type::Combinator.constant_of(index), scope)
        end
      end
    end
  end
end
