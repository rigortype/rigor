# frozen_string_literal: true

require "prism"

module Rigor
  module Inference
    module MatchRebinding
      # Issue #2443, #1371 — the match globals a block enters with when the call that owns it matches before every
      # yield. `String#scan`, `#gsub`, `#gsub!`, `#sub` and `#sub!` set the caller's `$~` to the current match before
      # each run of their block, with a Regexp pattern or a String one, so the block reads that match on every run
      # whatever the enclosing frame held; the frame-wide entry ({MatchRebinding.block_entry}) would otherwise leave
      # it the narrowing at the call site or nothing at all.
      #
      # A receiver that is a String, or a `Dynamic` the analyzer cannot type ({Narrowing.string_match_receiver?}),
      # enters with the call's own match edge ({Narrowing.yielded_match_scope}), which forgets what the frame held.
      # A `Dynamic` receiver may be another object whose block-taking `scan` runs no match, and then the block reads
      # the caller's `$~`; the name is taken as String's there, the overwhelmingly common case. A receiver known to
      # be anything else — a project class, `Pathname`, a union with either — keeps the frame-wide entry: a method
      # defined in Ruby runs its matches in a frame of its own, so its block reads the caller's `$~` as the frame
      # rules leave it. So does an implicit-self call.
      #
      # The block form of `grep` and `grep_v` runs `pattern === element` in the caller's frame before each yield,
      # which a Regexp pattern answers by setting `$~`: `grep` yields after a match, `grep_v` after a failed one. With
      # a regex literal for the pattern, a `grep` block enters with that match edge and a `grep_v` block with the
      # globals unbound. `Enumerable` is mixed into classes of every kind, so any explicit receiver counts but one
      # whose `grep` the project defines ({ProjectMethodOwnership}): that method matches, if at all, in a frame of
      # its own, and its block keeps the frame-wide entry as a project `scan`'s does. Any other pattern
      # (`grep(Integer)`) keeps the frame-wide entry too, since its `===` may leave `$~` alone.
      module YieldingMatch
        NAMES = Set[:scan, :gsub, :gsub!, :sub, :sub!].freeze
        GREP_NAMES = Set[:grep, :grep_v].freeze
        private_constant :NAMES, :GREP_NAMES

        module_function

        # `scope` with the match globals `call_node`'s block enters with; `scope` itself for any other block.
        # `operand_scope` types the receiver.
        def entry(scope, block_node, call_node, operand_scope)
          return scope unless own_block_call?(block_node, call_node)

          name = call_node.name
          if NAMES.include?(name)
            string_entry(scope, call_node, operand_scope)
          elsif GREP_NAMES.include?(name)
            grep_entry(scope, call_node, operand_scope)
          else
            scope
          end
        end

        def string_entry(scope, call_node, operand_scope)
          return scope unless Narrowing.string_match_receiver?(operand_scope.type_of(call_node.receiver), operand_scope)

          Narrowing.yielded_match_scope(scope, pattern_argument(call_node))
        end

        def grep_entry(scope, call_node, operand_scope)
          pattern = pattern_argument(call_node)
          return scope unless pattern.is_a?(Prism::RegularExpressionNode) ||
                              pattern.is_a?(Prism::InterpolatedRegularExpressionNode)
          return scope if project_method?(call_node, operand_scope)
          return scope.forget_match_globals if call_node.name == :grep_v

          Narrowing.yielded_match_scope(scope, pattern)
        end

        # True when the receiver answers the call with a method the project defines, or is a carrier whose class
        # cannot be resolved; an untyped receiver is not one.
        def project_method?(call_node, operand_scope)
          targets = ProjectMethodOwnership.targets(operand_scope.type_of(call_node.receiver))
          return true if targets.nil?

          targets.any? do |class_name, kind|
            ProjectMethodOwnership.defines?(class_name, call_node.name, kind, operand_scope)
          end
        end

        # The call's first argument, which each of these methods takes as its pattern; nil without one.
        def pattern_argument(call_node)
          call_node.arguments&.arguments&.first
        end

        def own_block_call?(block_node, call_node)
          call_node.is_a?(Prism::CallNode) && !call_node.receiver.nil? &&
            block_node.is_a?(Prism::BlockNode) && call_node.block.equal?(block_node)
        end
        private_class_method :string_entry, :grep_entry, :project_method?, :pattern_argument, :own_block_call?
      end
    end
  end
end
