# frozen_string_literal: true

require "prism"

require_relative "../source/node_children"
require_relative "../type"
require_relative "stored_block_call"

module Rigor
  module Inference
    # Issue #1361 — the blocks whose body does not read the narrowing of the frame-local special variables (the regex
    # match globals, and `$_` since issue #1359) where it is written ({.fresh_entry?}, {.entry}):
    #
    # - a root block: the block of `Thread.new` / `Thread.start` / `Thread.fork`, `Fiber.new` or `Ractor.new` on the
    #   core class ({.root_call?}). It runs as the root of a new thread, fiber or ractor, and Ruby keeps that
    #   execution context's own special-variable slot (`ec->root_svar`) for every piece of code whose local frame is
    #   the block's, the block and each block nested in it included. So the block reads `$1` nil whatever the
    #   creator matched, and a match it runs never rebinds the creator's `$~`. A `&expr` block argument's
    #   expression still runs in the creator's frame, before the thread starts;
    # - a definer block: the block of `define_method` / `define_singleton_method`, on any receiver. It runs as a
    #   method body whenever the method is called, and reads the defining frame's slot as it is at that time, which
    #   each call's own matches write too, so the narrowing where the method is defined neither proves nor refutes
    #   what it reads. Unlike a root block it shares that slot, so a match in it still rebinds the definer's `$~`.
    #
    # `Enumerator.new` is neither: its block runs on an internal fiber whose root is not the block, so it reads and
    # rebinds the creator's slot like any other block.
    #
    # The receiver of a root call must be the literal constant, and must resolve to the core class where a scope is
    # at hand, so a project's own `Thread` (`module Pool; class Thread; …`) keeps the ordinary block rules.
    module FreshFrameBlocks
      ROOT_CONSTRUCTORS = {
        Thread: %i[new start fork].freeze, Fiber: %i[new].freeze, Ractor: %i[new].freeze
      }.freeze
      DEFINERS = Set[:define_method, :define_singleton_method].freeze
      private_constant :ROOT_CONSTRUCTORS, :DEFINERS

      module_function

      # True when `node` is a call whose block (a literal or a `&expr` argument) runs as the root of a new thread,
      # fiber or ractor. `scope` resolves the receiver; without one the literal constant is taken at its word.
      def root_call?(node, scope = nil)
        return false unless node.is_a?(Prism::CallNode) && !node.block.nil?

        constant = StoredBlockCall.root_constant_name(node.receiver)
        return false unless ROOT_CONSTRUCTORS[constant]&.include?(node.name)

        scope.nil? || core_class?(node.receiver, constant, scope)
      end

      # The block of `node` when {.root_call?} holds, else nil.
      def root_block(node, scope = nil)
        root_call?(node, scope) ? node.block : nil
      end

      # True when the block answers true for a child of `node` that runs in the frame `node` runs in: any child but
      # a root block ({.root_block}), which runs with a slot of its own. Every {MatchRebinding} reading of what
      # running code may match walks through here. A root `&expr` block argument's own children are asked in its
      # place, since Ruby evaluates `expr` in this frame before the thread starts
      # (`Thread.new(&HANDLERS.fetch(name.sub(re, "")))` rebinds the creator's `$~`). `into_root` asks a root block's
      # children too, for a reading of what the code makes rather than what it runs: a closure made in a root block
      # may be handed back to this frame's thread. Stops at the first true answer, without a `return` out of the
      # walk's block.
      def any_frame_child?(node, scope, into_root: false)
        root = root_block(node, scope)
        found = false
        node.rigor_each_child do |child|
          if !child.equal?(root)
            found ||= yield(child)
          elsif into_root || child.is_a?(Prism::BlockArgumentNode)
            child.rigor_each_child { |inner| found ||= yield(inner) }
          end
        end
        found
      end

      # True when the block of `call_node` does not read the narrowing where it is written: a root block, or a
      # definer block. {.entry} gives the scope it enters with.
      def fresh_entry?(call_node, scope = nil)
        return false unless call_node.is_a?(Prism::CallNode)

        DEFINERS.include?(call_node.name) || root_call?(call_node, scope)
      end

      # The scope the block of `call_node`, which {.fresh_entry?} names, enters with. A root block reads a slot of its
      # own, so the match globals are unbound there, and `k = $1; k.upcase` in an entered `Thread.new { … }` block is
      # a true positive. A definer body reads the definer's slot whenever the method is called, which the analyzer
      # does not follow, so a global narrowed where it is written reads `Dynamic[top]` there, neither narrowed nor
      # flagged: the dynamic-finder idiom defines `find_by_email` in a `method_missing` guard whose `$1` its body
      # reads. This is the one place the specials are reset at such an entry: the match globals, `$_` (#1359), and
      # `$!`, `$@` and `$?` (#1360).
      #
      # A root block runs in an execution context of its own, so it reads `$!` and `$@` as `nil` even where it is
      # written in a rescue clause ({ErrorInfo}). `$?` is the thread's, so a thread's or a ractor's root block starts
      # without one, while a fiber shares the thread's. A definer body reads all three as they are when the method is
      # called.
      def entry(scope, call_node)
        if DEFINERS.include?(call_node.name)
          scope.untyped_match_globals.untyped_last_line.untyped_error_info.untyped_last_status
        else
          fresh = scope.forget_match_globals.forget_last_line.forget_error_info
          StoredBlockCall.root_constant_name(call_node.receiver) == :Fiber ? fresh : fresh.forget_last_status
        end
      end

      # Issue #1360 — the scope a closure's body enters with: a lambda literal's (`block_node` a `Prism::LambdaNode`),
      # or the block of a call that keeps it to run later ({StoredBlockCall.stores_block?}: `lambda`, `proc`,
      # `Proc.new`, `Enumerator.new`, `Hash.new`). The body runs whenever the closure is called, which is usually after
      # the rescue clause it is written in has exited (`f = -> { $! }` in a clause reads `nil` once called past the
      # `begin`), and may be on another thread (`Thread.new(&f)`), so `$!`, `$@` and `$?` are unbound there. A root or
      # definer block enters as {.entry} gives; every other block reads them where it is written.
      def closure_entry(scope, block_node, call_node)
        return scope unless block_node.is_a?(Prism::LambdaNode) ||
                            (call_node.is_a?(Prism::CallNode) && StoredBlockCall.stores_block?(call_node))

        scope.forget_error_info.forget_last_status
      end

      def core_class?(receiver, constant, scope)
        type = scope.type_of(receiver)
        type.is_a?(Type::Singleton) && type.class_name == constant.name
      rescue StandardError
        false
      end
      private_class_method :core_class?
    end
  end
end
