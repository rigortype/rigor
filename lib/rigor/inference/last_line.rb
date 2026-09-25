# frozen_string_literal: true

require "prism"

require_relative "../source/node_children"
require_relative "../reflection"
require_relative "../type"
require_relative "block_call_timing"
require_relative "fresh_frame_blocks"

module Rigor
  module Inference
    # Issue #1359 — which code may set `$_`, the last line read, that a scope's narrowing speaks for. Ruby keeps it in
    # the method frame's special-variable slot beside `$~`, so the frame rules are the match globals'
    # ({MatchRebinding}): a `def`, class, module or file body has a slot of its own; a block, and a closure made in
    # the body, shares it; a call into a method defined in Ruby writes that method's slot, never its caller's; and
    # the root block of a thread, fiber or ractor has one of its own ({FreshFrameBlocks}). Only a C-implemented
    # reader sets its caller's `$_`, to the line it returns: `Kernel#gets` / `#readline` and the same methods of
    # `IO`, `StringIO`, `ARGF` and `Zlib::GzipReader`; `IO.foreach` sets it to each line it yields. `each_line` and
    # `readlines` leave it alone.
    #
    # A call is read two ways, as the match globals' calls are:
    #
    # - {.reads_line?}: the call certainly is such a reader, run in this frame, so a condition on its value narrows
    #   `$_` on both edges ({Narrowing}). Apart from a write, that is the only place `$_` is bound.
    # - {.may_set?}: running the code may set `$_` in this frame, so a narrowing of it is forgotten: a reader's or
    #   `foreach`'s name on any receiver (a `Dynamic` one, or one whose method turns out to be defined in Ruby, which
    #   only costs the narrowing), a `send` that may name one, an eval of a String, a write, or a block argument that
    #   may run one.
    #
    # A reader that is not a condition leaves `$_` unbound, not bound to its `String?`: nothing proves the line
    # non-nil there, and a `String?` would report correct code that checks the reader's value another way before
    # it reads `$_` (`line = gets; return unless line; $_.chomp`). The scans run only while `$_` is bound.
    module LastLine
      # The C readers' names.
      READERS = Set[:gets, :readline].freeze
      # Every name that may set its caller's `$_`, on any receiver: the readers, and `IO.foreach`, which sets it to
      # each line before it yields the line and to nil once the input ends. Compared as Strings where a literal
      # names one.
      SETTERS = (READERS | Set[:foreach]).freeze
      SETTER_NAMES = SETTERS.to_set(&:to_s).freeze
      # The `Kernel` functions `ruby -n` / `-p` adds, which edit `$_` in place of an implicit-self receiver.
      LINE_EDITORS = Set[:sub, :gsub, :chop, :chomp].freeze
      # `$stdin`, and `$<`, which is `ARGF`, while the file binds them to nothing but a reader.
      READER_GLOBALS = Set[:$stdin, :$<].freeze
      # The RBS owners of a C reader. `Kernel`'s is private, and RBS places there any reader it does not declare
      # (`CSV#gets`, an alias of its Ruby `shift`, reads as `Kernel`'s), so it answers only the top level's implicit
      # `self` ({.self_reader?}); `Kernel.gets` itself is read by the receiver's type.
      READER_OWNERS = Set["::IO", "::StringIO", "::RBS::Unnamed::ARGFClass", "::Zlib::GzipReader"].freeze
      # RBS declares `Tempfile < File`, but its methods are `DelegateClass(File)`'s Ruby forwarders, so its `gets`
      # sets the forwarder's `$_` and never its caller's.
      DELEGATING_CLASSES = %w[Tempfile].freeze
      DELEGATING_ORDERINGS = Set[:equal, :subclass].freeze
      SENDS = Set[:send, :__send__, :public_send].freeze
      # These run a String of code in the frame that calls them; their block form is a block, scanned as one.
      EVALS = Set[:eval, :instance_eval, :class_eval, :module_eval].freeze
      WRITES = Set[
        Prism::GlobalVariableWriteNode, Prism::GlobalVariableOperatorWriteNode, Prism::GlobalVariableOrWriteNode,
        Prism::GlobalVariableAndWriteNode, Prism::GlobalVariableTargetNode
      ].freeze
      LAST_LINE = :$_
      # The calls that mix a module into their receiver, or refine for the rest of the file (`using`).
      MAIN_MIXINS = Set[:include, :extend, :prepend, :using].freeze
      MAIN_MIXIN_NAMES = MAIN_MIXINS.to_set(&:to_s).freeze
      ROOT_CLASSES = Set["Object", "Kernel", "BasicObject"].freeze
      CLASS_BODIES = Set[Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode].freeze
      private_constant :SETTER_NAMES, :LINE_EDITORS, :READER_GLOBALS, :READER_OWNERS, :DELEGATING_CLASSES,
                       :DELEGATING_ORDERINGS, :SENDS, :EVALS, :WRITES, :LAST_LINE, :MAIN_MIXINS, :MAIN_MIXIN_NAMES,
                       :ROOT_CLASSES, :CLASS_BODIES

      module_function

      # True when `call_node` certainly is a C reader run in this frame, so `$_` holds what it returns: `gets` or
      # `readline` without a block, on implicit `self` at the top level or in a top-level method ({.self_reader?}),
      # on the `Kernel` module, on `$stdin` or `$<`, or on a receiver typed as a class whose reader RBS places in
      # `IO`, `StringIO`, `ARGF` or `Zlib::GzipReader`, other than `Tempfile` (`STDIN` and `ARGF` read so by their
      # types, and a project constant that shadows either reads by its own). A program that defines a method of
      # that name anywhere, or patches one in, gets no answer but false, as {BlockCallTiming.project_defines_anywhere?}
      # reads it. A receiver typed `IO` or `File` that is a subclass instance at runtime is read as the class it is
      # typed as.
      def reads_line?(call_node, scope)
        return false unless call_node.is_a?(Prism::CallNode) && READERS.include?(call_node.name)
        return false unless call_node.block.nil?
        return false if BlockCallTiming.project_defines_anywhere?(call_node.name, scope)

        receiver = call_node.receiver
        case receiver
        when nil, Prism::SelfNode then self_reader?(call_node.name, scope)
        when Prism::GlobalVariableReadNode then reader_global?(receiver.name, call_node.name, scope)
        else reader_receiver?(scope.type_of(receiver), call_node.name, scope)
        end
      rescue StandardError
        false
      end

      # The edges of a condition whose value is `call_node`'s ({.reads_line?}): `pair`, the edges the condition
      # narrows otherwise (nil for none), with `$_` bound on each to the line the call returned, narrowed as that
      # value is — `String` where it is truthy and `nil` where it is not, for `gets`. The line is typed by the
      # readers' RBS return, which every owner {.reads_line?} accepts declares alike (`String?` for `gets`, `String`
      # for `readline`), rather than by the call's inferred type, which is `Dynamic[top]` on `$stdin`. A
      # safe-navigation call answers nil without reading when its receiver is nil, so its falsey edge leaves `$_` as
      # the call left it.
      def predicate_scopes(call_node, scope, pair)
        return pair unless reads_line?(call_node, scope)

        line = line_type(call_node.name)
        truthy, falsey = pair || [scope, scope]
        truthy = truthy.with_global(LAST_LINE, Narrowing.narrow_truthy(line))
        falsey = falsey.with_global(LAST_LINE, Narrowing.narrow_falsey(line)) unless call_node.safe_navigation?
        [truthy, falsey]
      end

      # True when running `node` may set `$_` in the frame it runs in, anywhere in `node` but a nested `def`, class
      # or module body or a root block ({FreshFrameBlocks.any_frame_child?}): a call {.call_may_set?} counts, a write
      # to `$_`, or a block argument {.block_argument_may_set?} counts. A block or lambda inside `node` counts, since
      # it runs in the same frame. Kept on `scope`'s frame as {MatchRebinding.may_match?} is.
      def may_set?(node, scope = nil)
        return false unless node.is_a?(Prism::Node)

        MatchRebinding.remember(node, scope, :last_line) { scan(node, scope) }
      end

      def scan(node, scope)
        return true if setting_node?(node, scope)
        return false if MatchRebinding::OWN_FRAME_NODES.include?(node.class)

        FreshFrameBlocks.any_frame_child?(node, scope) { |child| scan(child, scope) }
      end

      def setting_node?(node, scope)
        case node
        when Prism::CallNode then call_may_set?(node)
        when Prism::BlockArgumentNode then block_argument_may_set?(node, scope)
        else WRITES.include?(node.class) && node.name == LAST_LINE
        end
      end
      private_class_method :scan, :setting_node?

      # True when `call_node` itself may set its caller's `$_`: a {SETTERS} name on any receiver, a {LINE_EDITORS}
      # name on implicit `self`, a `send` whose name is not a literal or names a setter, or an eval of a String.
      def call_may_set?(call_node)
        name = call_node.name
        return true if SETTERS.include?(name) || (call_node.receiver.nil? && LINE_EDITORS.include?(name))

        arguments = call_node.arguments&.arguments
        return sent_reader?(arguments&.first) if SENDS.include?(name)

        EVALS.include?(name) && !arguments.nil?
      end

      # True when a `&expr` block argument may pass a proc that sets `$_` in this frame: a `&:gets` or `&:readline`,
      # which the method runs from C, or a proc made in this frame, as {MatchRebinding.block_argument_may_match?}
      # reads one — not an anonymous `&`, nor the method's own `&block` it only forwards.
      def block_argument_may_set?(block_argument, scope)
        expression = block_argument.expression
        case expression
        when nil then false
        when Prism::SymbolNode then SETTER_NAMES.include?(expression.unescaped)
        when Prism::LocalVariableReadNode
          frame = scope&.match_frame
          frame.nil? || !frame.forwarded_block?(expression.name)
        else true
        end
      end

      # True when the block `call_node` passes may set `$_` while the call runs, as {MatchRebinding.block_may_match?}
      # reads a block: a root block never does, though a root `&expr` argument's expression runs here first.
      def block_may_set?(call_node, scope)
        block = call_node.block
        if FreshFrameBlocks.root_call?(call_node, scope)
          return block.is_a?(Prism::BlockArgumentNode) && may_set?(block.expression, scope)
        end

        case block
        when Prism::BlockNode then may_set?(block.body, scope)
        when Prism::BlockArgumentNode then block_argument_may_set?(block, scope)
        else false
        end
      end

      # True when a call's receiver chain or arguments, which Ruby runs before the method, may set `$_`.
      def operands_may_set?(call_node, scope)
        may_set?(call_node.receiver, scope) || may_set?(call_node.arguments, scope)
      end

      # True when a statement's own call may set `$_` in this frame, once its operands ran: it may itself
      # ({.call_may_set?}), its block may ({.block_may_set?}), the frame makes a closure that may, which any call
      # can run ({.closure?}), or it is an implicit-self or `self.` call in a frame that hands `$_`'s slot to code the
      # analyzer does not trace ({.fallback?}) or that no body stamped. A call into a method defined in Ruby sets
      # that method's `$_`, so any other call keeps the narrowing.
      def call_rebinds?(call_node, scope)
        return true if call_may_set?(call_node) || block_may_set?(call_node, scope)

        frame = scope.match_frame
        implicit = call_node.receiver.nil? || call_node.receiver.is_a?(Prism::SelfNode)
        return implicit if frame.nil?
        return true if frame.last_line_closure?(scope)

        implicit && frame.last_line_fallback?(scope)
      end

      # True when `node`, a frame's body or parameters, makes a lambda, or a block a call keeps to run later, whose
      # body {.may_set?} ({MatchRebinding.makes_closure?}).
      def closure?(node, scope)
        MatchRebinding.makes_closure?(node, scope) { |body| may_set?(body, scope) }
      end

      # True when `node`, a frame's body or parameters, hands `$_`'s slot to code the analyzer does not trace: a block
      # or lambda whose body {.may_set?}, which the method it is handed to may keep and run from a later call,
      # `binding`, or a forward of the method's own block ({MatchRebinding.hands_out_slot?}).
      def fallback?(node, block_name, scope)
        MatchRebinding.hands_out_slot?(node, block_name, scope) { |body| may_set?(body, scope) }
      end

      # The scope a block or lambda body enters with, as {MatchRebinding.block_entry} gives the match globals': `$_`
      # forgotten when the body may set it, which a later iteration then reads, when the frame makes a closure that
      # may, or when the owning call may: its receiver chain and arguments run before the method yields, and
      # `IO.foreach` sets `$_` to each line it yields.
      def block_entry(scope, block_node, call_node = nil)
        return scope unless scope.last_line_bound?
        return scope unless scope.last_line_closure? || may_set?(block_node.body, scope) || call_sets?(call_node, scope)

        scope.forget_last_line
      end

      def call_sets?(call_node, scope)
        call_node.is_a?(Prism::CallNode) && (call_may_set?(call_node) || operands_may_set?(call_node, scope))
      end
      private_class_method :call_sets?

      # `scope` with `$_` forgotten when any of `bodies` may set it: a loop body that runs again after it ran, a
      # `begin` body a `rescue` clause reads after any prefix of it ran, or a `case` clause's tests.
      def forget_if_set(scope, *bodies)
        return scope unless scope.last_line_bound? && bodies.any? { |body| may_set?(body, scope) }

        scope.forget_last_line
      end

      def line_type(reader)
        string = Type::Combinator.nominal_of("String")
        reader == :readline ? string : Type::Combinator.union(string, Type::Combinator.constant_of(nil))
      end

      def sent_reader?(name_node)
        case name_node
        when nil then false
        when Prism::SymbolNode, Prism::StringNode then SETTER_NAMES.include?(name_node.unescaped)
        else true
        end
      end
      private_class_method :line_type, :sent_reader?

      # An implicit-self reader is `Kernel`'s only in the top-level script body, outside every block, whose `self` is
      # `main`, and only while the program mixes nothing into `main` or `Object` ({.mixes_into_main?}, and a
      # recorded `include` / `prepend` / `extend` of `Object`, `Kernel` or `BasicObject`): `include Readline` makes
      # `readline` Reline's Ruby method. A top-level method is a private method of `Object`, so its `self` may be any
      # object (a `CSV` subclass calling it reads `CSV#gets`), and a block's `self` may be rebound (`instance_exec`),
      # which the analyzer does not follow. Inside a class or module it answers only where RBS places the reader in
      # `IO` or its kin (a reopened `IO`): any other ancestry may hold a Ruby reader the analyzer does not see, since a
      # class written `class W < DelegateClass(File)` records no superclass at all, and RBS leaves out a Ruby reader
      # such as `CSV#gets` or `OpenSSL::Buffering#gets` often enough that its `Kernel` answer proves nothing.
      def self_reader?(name, scope)
        self_type = scope.self_type
        return reader_type?(self_type, name, scope) unless self_type.nil?

        frame = scope.match_frame
        !frame.nil? && frame.program? && !scope.opaque_block_self? && !frame.main_mixin? && !object_mixin?(scope)
      end

      # True when `program` may mix a module into `main` or `Object`: an `include`, `extend`, `prepend` or `using`
      # (or a `send` that may name one) on implicit `self` or `self.` outside a class or module body, or on `Object`,
      # `Kernel` or `BasicObject` anywhere. A module mixed in by another file of the program is not seen.
      def mixes_into_main?(node, in_class: false)
        return false unless node.is_a?(Prism::Node)
        return true if node.is_a?(Prism::CallNode) && main_mixin_call?(node, in_class)

        nested = in_class || CLASS_BODIES.include?(node.class)
        found = false
        node.rigor_each_child { |child| found ||= mixes_into_main?(child, in_class: nested) }
        found
      end

      def main_mixin_call?(call_node, in_class)
        name = call_node.name
        mixes = MAIN_MIXINS.include?(name) ||
                (SENDS.include?(name) && sent_mixin?(call_node.arguments&.arguments&.first))
        return false unless mixes

        receiver = call_node.receiver
        return !in_class if receiver.nil? || receiver.is_a?(Prism::SelfNode)

        constant = receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)
        constant && ROOT_CLASSES.include?(receiver.name.to_s)
      end

      def sent_mixin?(name_node)
        case name_node
        when nil then false
        when Prism::SymbolNode, Prism::StringNode then MAIN_MIXIN_NAMES.include?(name_node.unescaped)
        else true
        end
      end

      # A recorded `include`, `prepend` or `extend` of `Object`, `Kernel` or `BasicObject` (`class Object; include M`,
      # `Object.prepend(M)`), in any file of the program.
      def object_mixin?(scope)
        [scope.discovered_includes, scope.discovered_prepends, scope.discovered_extends].any? do |table|
          ROOT_CLASSES.any? { |name| table.key?(name) }
        end
      end

      def reader_receiver?(type, name, scope)
        return type.class_name == "Kernel" if type.is_a?(Type::Singleton)

        reader_type?(type, name, scope)
      end

      def reader_global?(global_name, name, scope)
        return false unless READER_GLOBALS.include?(global_name)

        bound = scope.global(global_name)
        bound.nil? || reader_type?(bound, name, scope)
      end

      def reader_type?(type, name, scope)
        type.is_a?(Type::Nominal) && reader_class?(type.class_name, name, scope)
      end

      # A class RBS does not know answers false: its ancestry is the program's or a gem's, and may hold a Ruby reader.
      def reader_class?(class_name, name, scope)
        return false if delegating_class?(class_name, scope)

        definition = Reflection.instance_method_definition(class_name, name, scope: scope)
        !definition.nil? && READER_OWNERS.include?(definition.defined_in.to_s)
      end

      def delegating_class?(class_name, scope)
        DELEGATING_CLASSES.any? do |delegating|
          DELEGATING_ORDERINGS.include?(scope.environment.class_ordering(class_name, delegating))
        end
      end

      private_class_method :self_reader?, :main_mixin_call?, :sent_mixin?, :object_mixin?, :reader_receiver?,
                           :reader_global?, :reader_type?, :reader_class?, :delegating_class?
    end
  end
end
