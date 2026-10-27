# frozen_string_literal: true

require "prism"

module Rigor
  module Inference
    module MatchRebinding
      # Issue #2443 — the match globals a block enters with when the call that owns it matches before every yield.
      # `String#scan`, `#gsub`, `#gsub!`, `#sub` and `#sub!` set the caller's `$~` to the current match before each
      # run of their block, with a Regexp pattern or a String one, so the block reads that match on every run
      # whatever the enclosing frame held; the frame-wide entry ({MatchRebinding.block_entry}) would otherwise leave
      # it the narrowing at the call site (issue #1371) or nothing at all, and `Regexp.last_match.begin(0)` in the
      # block read `MatchData?`.
      #
      # A receiver that is a String, or a `Dynamic` the analyzer cannot type ({Narrowing.string_match_receiver?}),
      # enters with the call's own match edge ({Narrowing.yielded_match_scope}). A `Dynamic` receiver may be another
      # object whose block-taking `scan` runs no match, and then the block reads the caller's `$~`; narrowing it
      # anyway can only drop a diagnostic, never add one (ADR-5). A receiver known to be anything else — a project
      # class, `Pathname`, a union with either — keeps the frame-wide entry: a method defined in Ruby runs its
      # matches in a frame of its own, so its block reads the caller's `$~` as the frame rules leave it. So does an
      # implicit-self call.
      module YieldingMatch
        NAMES = Set[:scan, :gsub, :gsub!, :sub, :sub!].freeze
        private_constant :NAMES

        module_function

        # `scope` with the match globals `call_node`'s block enters with; `scope` itself for any other block.
        # `operand_scope` types the receiver.
        def entry(scope, block_node, call_node, operand_scope)
          return scope unless yielding_call?(block_node, call_node) &&
                              Narrowing.string_match_receiver?(operand_scope.type_of(call_node.receiver), operand_scope)

          Narrowing.yielded_match_scope(scope)
        end

        def yielding_call?(block_node, call_node)
          call_node.is_a?(Prism::CallNode) && NAMES.include?(call_node.name) && !call_node.receiver.nil? &&
            block_node.is_a?(Prism::BlockNode) && call_node.block.equal?(block_node)
        end
        private_class_method :yielding_call?
      end
    end
  end
end
