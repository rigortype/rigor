# frozen_string_literal: true

require "prism"

require_relative "../source/node_children"
require_relative "../type"
require_relative "block_call_timing"
require_relative "stored_block_call"
require_relative "match_rebinding/frame"
require_relative "match_rebinding/operands"
require_relative "match_rebinding/calls"
require_relative "match_rebinding/self_calls"

module Rigor
  module Inference
    # Which code may rebind the regex match globals (`$~` and the `$&` / `` $` `` / `$'` / `$+` / `$1`..`$9` family
    # derived from it) that a scope's narrowing speaks for. Ruby keeps them in the method frame's special-variable
    # slot, and every block and closure made in the method reaches that same slot, so a match a block body runs
    # rebinds the enclosing method's `$~` (issue #1358). A `def`, class or module body runs in a frame of its own,
    # and so does every call into a method defined in Ruby: a match in the callee writes the callee's slot, never
    # its caller's (issue #1364).
    #
    # The block and closure scans are syntactic, resolving only constants and the variables a lookup argument
    # names, through the scope they are given. The code a statement runs outside a block is read by the types the
    # flow scope gives its operands ({Calls}, {.value_may_rebind?}; issue #1365). The scans short-circuit without a
    # `return` out of a child block, which would allocate once per frame it unwinds.
    module MatchRebinding
      # The block and closure scans read calls on narrower terms than the statement-level rule ({Calls}), because
      # inside a block `[]`, `split` and `index` are overwhelmingly lookups on hashes, arrays and strings whose key
      # the scan cannot type, and counting them dropped the narrowing on correct code
      # (`fields.each { |f| out[f] = row[f] }; $1.upcase`).
      #
      # These rebind `$~` whatever their argument: `sub` / `gsub` / `scan` with a String pattern still set it, and
      # `!~` runs `=~`.
      ALWAYS_MATCHING = Set[:=~, :!~, :match, :sub, :sub!, :gsub, :gsub!, :scan].freeze
      # These rebind it only with a Regexp argument, so they count only when an argument is known to be one
      # ({Operands.regexp_argument?}). `match?` never sets `$~`.
      REGEXP_ARGUMENT = Set[
        :[], :slice, :slice!, :index, :rindex, :partition, :rpartition, :split, :grep, :grep_v,
        :start_with?, :byteindex, :byterindex, :any?, :all?, :none?, :one?
      ].freeze
      # `grep` / `grep_v` rebind the caller's `$~` only in their block form.
      BLOCK_FORM_ONLY = Set[:grep, :grep_v].freeze
      # `&:name` block arguments that rebind `$~`: the method runs on the element in the caller's frame. `===` with
      # an unknown operand may be a Regexp's. Compared as Strings, as {SelfCalls} explains.
      MATCHING_SYMBOL_PROCS = (ALWAYS_MATCHING | Set[:===]).to_set(&:to_s).freeze
      # The broad reading ({.broad_may_match?}) also counts these with any argument that may be a Regexp.
      BROAD_ARGUMENT = (REGEXP_ARGUMENT | Set[:[]=]).freeze
      # The names issue #1364 added to the block scan. The entry of a `tap` / `then` / `yield_self` block reads its
      # body without them ({.block_entry}).
      ADDED_NAMES = Set[:!~, :start_with?, :byteindex, :byterindex, :any?, :all?, :none?, :one?].freeze
      # The calls on the method's own `&block` parameter that run it, which the broad reading counts.
      BLOCK_INVOCATIONS = Set[:call, :yield, :[], :===].freeze

      # A body that runs in a frame of its own, or never runs (`defined?` evaluates nothing).
      OWN_FRAME_NODES = Set[
        Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode, Prism::DefinedNode
      ].freeze
      # A bare regex condition (`if /re/`) matches against `$_`.
      LAST_LINE_MATCHES = Set[Prism::MatchLastLineNode, Prism::InterpolatedMatchLastLineNode].freeze
      GLOBAL_WRITES = Set[
        Prism::GlobalVariableWriteNode, Prism::GlobalVariableOperatorWriteNode, Prism::GlobalVariableOrWriteNode,
        Prism::GlobalVariableAndWriteNode, Prism::GlobalVariableTargetNode
      ].freeze
      private_constant :ALWAYS_MATCHING, :REGEXP_ARGUMENT, :BLOCK_FORM_ONLY, :MATCHING_SYMBOL_PROCS, :BROAD_ARGUMENT,
                       :ADDED_NAMES, :BLOCK_INVOCATIONS,
                       :OWN_FRAME_NODES, :LAST_LINE_MATCHES, :GLOBAL_WRITES

      module_function

      # True when running `node` may run a regex match in the frame it runs in, anywhere in `node` but a nested
      # `def`, class or module body: a call {.call_matches?} counts; so does a `when` condition of a `case` with a
      # subject, or an `in` / `=>` pattern value, that may be a Regexp ({Operands}); a bare regex condition; a
      # write to `$~`; or a block argument {.block_argument_may_match?} counts. A block or lambda inside `node`
      # counts, since it runs in the same frame. `scope` resolves constants and the variables a lookup argument
      # names, and names the frame; the answer for a node is kept on that frame while those bindings stay the same.
      def may_match?(node, scope = nil)
        return false unless node.is_a?(Prism::Node)

        frame = scope&.match_frame
        return scan(node, scope) if frame.nil?

        frame.memo(node, scope) { scan(node, scope) }
      end

      # `base` reads the body without {ADDED_NAMES}.
      def scan(node, scope, base: false)
        return true if matching_node?(node, scope, base: base)
        return false if OWN_FRAME_NODES.include?(node.class)

        found = false
        node.rigor_each_child { |child| found ||= scan(child, scope, base: base) }
        found
      end
      private_class_method :scan

      # `broad` reads an unresolved constant as a possible Regexp ({Operands}).
      def matching_node?(node, scope, broad: false, base: false)
        case node
        when Prism::CallNode then call_matches?(node, scope, broad: broad, base: base)
        when Prism::CaseNode then case_matches?(node, scope, broad: broad)
        when Prism::BlockArgumentNode then block_argument_may_match?(node, scope, base: base)
        # `case … in`, `expr in pat` and `expr => pat` run `===` on each value in the pattern.
        when Prism::InNode, Prism::MatchPredicateNode, Prism::MatchRequiredNode
          Operands.pattern_matches?(node.pattern, scope, broad: broad)
        else
          LAST_LINE_MATCHES.include?(node.class) || (GLOBAL_WRITES.include?(node.class) && node.name == :$~)
        end
      end
      private_class_method :matching_node?

      # A call that rebinds `$~` in the frame it is made in: an {ALWAYS_MATCHING} name, a {REGEXP_ARGUMENT} name
      # with a known Regexp argument, or `===` on a receiver that may be a Regexp — `a === b` is `a`'s method, so
      # `String === re` runs no match.
      def call_matches?(node, scope, broad: false, base: false)
        name = node.name
        return false if base && ADDED_NAMES.include?(name)
        return true if ALWAYS_MATCHING.include?(name)

        if name == :===
          receiver = node.receiver
          return receiver.nil? || Operands.pattern_value?(receiver, scope, broad: broad)
        end
        arguments = node.arguments&.arguments
        return false unless arguments && REGEXP_ARGUMENT.include?(name)
        return false if BLOCK_FORM_ONLY.include?(name) && node.block.nil?

        arguments.any? { |argument| Operands.regexp_argument?(argument, scope) }
      end

      # A `case` with a subject runs `condition === subject` for each `when` condition. One without a subject tests
      # each condition for truth, which runs no `===`; a match inside a condition is scanned like any other code.
      def case_matches?(node, scope, broad: false)
        return false if node.predicate.nil?

        node.conditions.any? do |clause|
          clause.is_a?(Prism::WhenNode) &&
            clause.conditions.any? { |condition| Operands.pattern_value?(condition, scope, broad: broad) }
        end
      end
      private_class_method :call_matches?, :case_matches?

      # True when an implicit-self call's arguments may run a match in this frame (issue #1364), outside a block or
      # lambda, which {.value_may_rebind?} and the frame's closure rules answer for: a call {Calls} counts on any
      # receiver; a Symbol or String literal naming a method the table or {SelfCalls} names (`inject(:=~)`), which
      # the implicit-self call may run from C; a `yield`; or any other construct the block scan counts, an
      # unresolved constant read as a possible Regexp. An implicit-self call used to forget whatever it called, and
      # this keeps it forgetting on the literals and the `yield` it forgot on then; a call in an argument also
      # forgets by itself ({.operands_may_rebind?}, issue #1365).
      def operand_may_match?(node, scope = nil)
        return false unless node.is_a?(Prism::Node)

        case node
        when Prism::BlockNode, Prism::LambdaNode then return false
        when Prism::CallNode then return true if Calls.rebinds?(node, scope)
        when Prism::YieldNode then return true
        else
          return true if SelfCalls.method_name_literal?(node) || matching_node?(node, scope, broad: true)
        end
        return false if OWN_FRAME_NODES.include?(node.class)

        found = false
        node.rigor_each_child { |child| found ||= operand_may_match?(child, scope) }
        found
      end

      # True when `node`, a frame's body or parameters, hands its match globals to code the analyzer does not trace,
      # so an implicit-self call in the frame keeps forgetting them as every one did before issue #1364: a block or
      # lambda literal whose body may match by the broad reading ({.broad_may_match?}), since the call it is passed
      # to may keep it and run it from any later call; `binding` in any spelling, whose `eval` runs in this frame
      # wherever it is called; or a forward of the method's own block (`&blk` for the method's `&blk`, `&`, `...`),
      # which may be a C-function proc such as `&:=~`. `block_name` is the method's `&block` parameter.
      def self_call_fallback?(node, block_name, scope = nil)
        return false unless node.is_a?(Prism::Node)
        return true if fallback_node?(node, block_name, scope)
        return false if OWN_FRAME_NODES.include?(node.class)

        found = false
        node.rigor_each_child { |child| found ||= self_call_fallback?(child, block_name, scope) }
        found
      end

      def fallback_node?(node, block_name, scope)
        case node
        when Prism::BlockNode, Prism::LambdaNode then broad_may_match?(node.body, scope, block_name)
        when Prism::CallNode then node.name == :binding || SelfCalls.sends_binding?(node)
        when Prism::ForwardingArgumentsNode then true
        when Prism::BlockArgumentNode
          expression = node.expression
          expression.nil? || (expression.is_a?(Prism::LocalVariableReadNode) && expression.name == block_name)
        else false
        end
      end
      private_class_method :fallback_node?

      # {.may_match?} on broad terms, where over-counting costs no more than an implicit-self call forgetting as it
      # did before issue #1364: a {BROAD_ARGUMENT} name counts with any argument that may be a Regexp — a block
      # parameter, a method's return value, a constant that does not resolve (#1373) — and so does a call {SelfCalls}
      # reads by name, a literal naming one, a `yield`, or a call that runs the method's own `&block` (`block_name`),
      # either of which may run a C-function proc such as `&:=~` in this frame.
      def broad_may_match?(node, scope = nil, block_name = nil)
        return false unless node.is_a?(Prism::Node)
        return true if broad_matching_node?(node, scope, block_name)
        return false if OWN_FRAME_NODES.include?(node.class)

        found = false
        node.rigor_each_child { |child| found ||= broad_may_match?(child, scope, block_name) }
        found
      end

      def broad_matching_node?(node, scope, block_name)
        return true if node.is_a?(Prism::YieldNode)
        unless node.is_a?(Prism::CallNode)
          return matching_node?(node, scope, broad: true) || SelfCalls.method_name_literal?(node)
        end
        return true if call_matches?(node, scope, broad: true) || SelfCalls.named_match?(node)
        return true if own_block_call?(node, block_name)

        arguments = node.arguments&.arguments
        !arguments.nil? && BROAD_ARGUMENT.include?(node.name) &&
          arguments.any? { |argument| Operands.pattern_value?(argument, scope, broad: true) }
      end

      def own_block_call?(call_node, block_name)
        receiver = call_node.receiver
        !block_name.nil? && receiver.is_a?(Prism::LocalVariableReadNode) && receiver.name == block_name &&
          BLOCK_INVOCATIONS.include?(call_node.name)
      end
      private_class_method :broad_matching_node?, :own_block_call?

      # True when the block `call_node` passes may rebind the frame's match globals while the call runs: a block
      # literal whose body {.may_match?}, or a block argument that {.block_argument_may_match?}.
      def block_may_match?(call_node, scope = nil)
        block = call_node.block
        case block
        when Prism::BlockNode then may_match?(block.body, scope)
        when Prism::BlockArgumentNode then block_argument_may_match?(block, scope)
        else false
        end
      end

      # True when a `&expr` block argument may pass a proc made in this frame. Not an anonymous `&`, nor the method's
      # own `&block` parameter while the body never rebinds or shadows it ({Frame#forwarded_block?}): either
      # forwards the block the caller made, in the caller's frame. Not a `&:name` whose method cannot match
      # ({MATCHING_SYMBOL_PROCS}).
      def block_argument_may_match?(block_argument, scope, base: false)
        expression = block_argument.expression
        case expression
        when nil then false
        when Prism::SymbolNode
          name = expression.unescaped
          MATCHING_SYMBOL_PROCS.include?(name) && !(base && name == "!~")
        when Prism::LocalVariableReadNode
          frame = scope&.match_frame
          frame.nil? || !frame.forwarded_block?(expression.name)
        else true
        end
      end

      # True when `call_node` itself may rebind the match globals of the frame it is made in, once its operands
      # have run: the method it calls matches on this frame's behalf ({Calls.rebinds?}, on any receiver); or it is
      # an implicit-self or `self.` call that may reach the frame's slot although its name does not match — where
      # the frame hands its slot to code the analyzer does not trace ({Frame#self_call_fallback?}), where no body
      # stamped a frame, or where its arguments hold a literal or `yield` {.operand_may_match?} counts. Any other
      # call runs a method in a frame of its own (issue #1364) or a C method that does not match.
      def call_rebinds?(call_node, scope)
        return true if Calls.rebinds?(call_node, scope)

        receiver = call_node.receiver
        return false unless receiver.nil? || receiver.is_a?(Prism::SelfNode)

        frame = scope&.match_frame
        frame.nil? || frame.self_call_fallback?(scope) || operand_may_match?(call_node.arguments, scope)
      end

      # True when running a call's receiver chain and arguments, which Ruby does before the method, may rebind the
      # frame's match globals ({.value_may_rebind?}).
      def operands_may_rebind?(call_node, scope)
        value_may_rebind?(call_node.receiver, scope) || value_may_rebind?(call_node.arguments, scope)
      end

      # True when evaluating `node` for its value — a call's receiver chain or arguments, an array, hash or
      # interpolation literal, a `rescue` modifier, a `super` or `yield` — may rebind the frame's match globals
      # (issue #1365): a call in it whose method matches on this frame's behalf ({Calls.rebinds?}); an index write
      # whose index may be a Regexp (`s[re] ||= v`); a block literal on a call in it whose body {.may_match?}, or a
      # block argument {.block_argument_may_match?} counts; or any other construct the block scan counts (a `when`
      # or `in` value that may be a Regexp, a bare regex condition, a write to `$~`). An implicit-self call there
      # is read by what it calls alone: the frame-wide fallback of {.call_rebinds?} stays with statement-position
      # calls, as before, where an operand's `value.upcase` or `name.strip` would otherwise forget at every
      # attribute read. A lambda literal does not run where it is written ({.matching_closure?} answers for it),
      # and a `def`, class or module body or a `defined?` operand does not run in this frame.
      def value_may_rebind?(node, scope)
        return false unless node.is_a?(Prism::Node)

        case node
        when Prism::BlockNode then return may_match?(node.body, scope)
        when Prism::LambdaNode then return false
        when Prism::CallNode, Prism::IndexOrWriteNode, Prism::IndexAndWriteNode, Prism::IndexOperatorWriteNode
          return true if Calls.rebinds?(node, scope)
        else return true if matching_node?(node, scope)
        end
        return false if OWN_FRAME_NODES.include?(node.class)

        found = false
        node.rigor_each_child { |child| found ||= value_may_rebind?(child, scope) }
        found
      end

      # True when `node`, a frame's body or parameters, makes a closure that may rebind the frame's match globals
      # whenever it is invoked: a `->` literal, or the block of a call that keeps it to run later
      # ({StoredBlockCall}: `lambda`, `proc`, `Proc.new`, `define_method`, …), whose body {.may_match?}.
      # Invocations are not traced — the closure can be called through any later call, or run by a method it was
      # handed to — so {Frame} answers for the whole frame.
      def matching_closure?(node, scope = nil)
        return false unless node.is_a?(Prism::Node)
        return false if OWN_FRAME_NODES.include?(node.class)
        return true if node.is_a?(Prism::LambdaNode) && may_match?(node.body, scope)
        return true if node.is_a?(Prism::CallNode) && stored_matching_block?(node, scope)

        found = false
        node.rigor_each_child { |child| found ||= matching_closure?(child, scope) }
        found
      end

      def stored_matching_block?(call_node, scope)
        block = call_node.block
        return false unless block.is_a?(Prism::BlockNode)

        StoredBlockCall.stores_block?(call_node) && may_match?(block.body, scope)
      end
      private_class_method :stored_matching_block?

      # The scope a block or lambda body enters with: `scope` with its match globals forgotten when the body may
      # match, or when the frame makes a closure that may. The body can run on a later iteration, after an earlier
      # one — or a call to that closure — rebound them, so no iteration may read the narrowing the call site holds.
      # A body with neither keeps it: blocks share the frame, so `s =~ /(\d+)/; items.map { $1 }` reads the
      # guard's `$1`. The block of a call named `tap`, `then` or `yield_self` ({BlockCallTiming}) is read as the scan
      # read every block before issue #1364, without {ADDED_NAMES}, so its entry is what it was: the name alone
      # cannot show the block runs once (a user `then` may keep it, and a loop runs the call again, #1375). Both
      # block-entry passes ({StatementEvaluator#build_block_entry_scope} and the block-return pass in
      # {ExpressionTyper}) enter through here, so they cannot disagree.
      def block_entry(scope, block_node, call_node = nil)
        return scope unless scope.match_globals_bound?
        return scope unless entry_may_match?(block_node.body, scope, call_node) || scope.match_rebinding_closure?

        scope.forget_match_globals
      end

      def entry_may_match?(body, scope, call_node)
        return may_match?(body, scope) unless call_node.is_a?(Prism::CallNode) &&
                                              BlockCallTiming.candidate_name?(call_node.name)

        body.is_a?(Prism::Node) && scan(body, scope, base: true)
      end
      private_class_method :entry_may_match?
    end
  end
end
