# frozen_string_literal: true

require "prism"

require_relative "../source/node_children"
require_relative "stored_block_call"

module Rigor
  module Inference
    # Which code may rebind the regex match globals (`$~` and the `$&` / `` $` `` / `$'` / `$+` / `$1`..`$9` family
    # derived from it) that a scope's narrowing speaks for. Ruby keeps them in the method frame's special-variable
    # slot, and every block and closure made in the method reaches that same slot, so a match a block body runs
    # rebinds the enclosing method's `$~` (issue #1358). A `def`, class or module body runs in a frame of its own.
    #
    # The scans are syntactic and one-directional: they may answer "may match" for code that never matches, which
    # only drops a narrowing. They short-circuit without a `return` out of a child block, which would allocate once
    # per frame it unwinds.
    module MatchRebinding
      # Method names that (may) run a regex match and therefore rebind the `$~` family. Conservative
      # over-approximation — a few set globals only with a Regexp argument, but we do not inspect args.
      MATCH_CAPABLE_METHODS = %i[
        =~ match match? gsub gsub! sub sub! scan split slice slice!
        [] partition rpartition index rindex === grep grep_v
      ].freeze

      # A body that runs in a frame of its own, or never runs (`defined?` evaluates nothing).
      OWN_FRAME_NODES = Set[
        Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode, Prism::DefinedNode
      ].freeze
      REGEX_LITERALS = Set[Prism::RegularExpressionNode, Prism::InterpolatedRegularExpressionNode].freeze
      # A bare regex condition (`if /re/`) matches against `$_`.
      LAST_LINE_MATCHES = Set[Prism::MatchLastLineNode, Prism::InterpolatedMatchLastLineNode].freeze
      # The nodes whose `pattern` a regex in runs `Regexp#===`: `case … in`, `expr in pat` and `expr => pat`.
      PATTERN_NODES = Set[Prism::InNode, Prism::MatchPredicateNode, Prism::MatchRequiredNode].freeze
      private_constant :OWN_FRAME_NODES, :REGEX_LITERALS, :LAST_LINE_MATCHES, :PATTERN_NODES

      module_function

      # True when running `node` may run a regex match in the frame it runs in: a call to a
      # {MATCH_CAPABLE_METHODS} name, a regex `when` condition or pattern, or a bare regex condition, anywhere in
      # `node` but a nested `def`, class or module body. A block or lambda inside `node` counts, since it runs in
      # the same frame.
      def may_match?(node)
        return false unless node.is_a?(Prism::Node)

        klass = node.class
        return true if matching_node?(node, klass)
        return false if OWN_FRAME_NODES.include?(klass)

        found = false
        node.rigor_each_child { |child| found ||= may_match?(child) }
        found
      end

      def matching_node?(node, klass)
        if klass == Prism::CallNode
          MATCH_CAPABLE_METHODS.include?(node.name)
        elsif klass == Prism::WhenNode
          node.conditions.any? { |condition| REGEX_LITERALS.include?(condition.class) }
        elsif PATTERN_NODES.include?(klass)
          regex_in?(node.pattern)
        else
          LAST_LINE_MATCHES.include?(klass)
        end
      end
      private_class_method :matching_node?

      def regex_in?(node)
        return true if REGEX_LITERALS.include?(node.class)

        found = false
        node.rigor_each_child { |child| found ||= regex_in?(child) }
        found
      end
      private_class_method :regex_in?

      # True when the block `call_node` passes may rebind the frame's match globals while the call runs: a block
      # literal whose body {.may_match?}, or a `&expr` block argument other than a Symbol literal, which may be a
      # proc made in this frame. An anonymous `&` forwards the block this method was called with, which was made
      # in the caller's frame.
      def block_may_match?(call_node)
        block = call_node.block
        case block
        when Prism::BlockNode then may_match?(block.body)
        when Prism::BlockArgumentNode
          expression = block.expression
          !expression.nil? && !expression.is_a?(Prism::SymbolNode)
        else false
        end
      end

      # True when `node`, a frame's body, makes a closure that may rebind the frame's match globals whenever it is
      # invoked: a `->` literal, or the block of a call that keeps it to run later ({StoredBlockCall}: `lambda`,
      # `proc`, `Proc.new`, `define_method`, …), whose body {.may_match?}. Invocations are not traced — the closure
      # can be called through any later call, or run by a method it was handed to — so {Frame} answers for the
      # whole frame.
      def matching_closure?(node)
        return false unless node.is_a?(Prism::Node)

        klass = node.class
        return false if OWN_FRAME_NODES.include?(klass)
        return true if node.is_a?(Prism::LambdaNode) && may_match?(node.body)
        return true if node.is_a?(Prism::CallNode) && stored_matching_block?(node)

        found = false
        node.rigor_each_child { |child| found ||= matching_closure?(child) }
        found
      end

      def stored_matching_block?(call_node)
        block = call_node.block
        return false unless block.is_a?(Prism::BlockNode)

        StoredBlockCall.stores_block?(call_node) && may_match?(block.body)
      end
      private_class_method :stored_matching_block?

      # The scope a block or lambda body enters with: `scope` with its match globals forgotten when the body may
      # match, or when the frame makes a closure that may. The body can run on a later iteration, after an earlier
      # one — or a call to that closure — rebound them, so no iteration may read the narrowing the call site holds.
      # A body with neither keeps it: blocks share the frame, so `s =~ /(\d+)/; items.map { $1 }` reads the
      # guard's `$1`. Both block-entry passes ({StatementEvaluator#build_block_entry_scope} and the block-return
      # pass in {ExpressionTyper}) enter through here, so they cannot disagree.
      def block_entry(scope, block_node)
        return scope unless scope.match_globals_bound?
        return scope unless may_match?(block_node.body) || scope.match_rebinding_closure?

        scope.forget_match_globals
      end

      # The frame a body runs in, stamped on its entry scope ({Scope#with_match_frame}) and shared by every scope
      # derived from it, blocks included, since they run in the same frame. {#matching_closure?} is computed on
      # the first ask — only a call made while a match global is narrowed asks — and kept for the rest of the
      # body.
      class Frame
        def initialize(body)
          @body = body
          @matching_closure = nil
        end

        def matching_closure?
          @matching_closure = MatchRebinding.matching_closure?(@body) if @matching_closure.nil?
          @matching_closure
        end
      end
    end
  end
end
