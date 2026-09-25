# frozen_string_literal: true

require "prism"

require_relative "../type"
require_relative "block_call_timing"
require_relative "stored_block_call"

module Rigor
  module Inference
    # Issue #1360 — `$?`, the status of the last child process the thread waited for. Ruby keeps it per thread, not in
    # the method frame's special-variable slot: a subprocess that a called method runs sets its caller's `$?`, a fiber
    # shares its thread's, and a new thread starts without one. A subprocess that certainly ran ({.sets?}) sets it to
    # a `Process::Status`: a backtick or `%x` command, `Kernel#system` (also when the command cannot run, with exit
    # status 127), and `Process.wait`, `waitpid`, `wait2` or `waitpid2` without a flags argument, which blocks until a
    # child exits.
    #
    # Ruby 4.0.5 sets it back to `nil` in four ways. One of those four waits given the `WNOHANG` flag sets it so when
    # no child has exited, and `Process.waitall` when there is no child; either can run inside any method the thread
    # calls, or in a signal handler, so a file that holds one ({.clears?}) binds `$?` nowhere. A backtick, `%x` or
    # `system` sets it to nil before it runs the child, so an exception raised while it waits (`Timeout::Error`,
    # `Interrupt`, `Thread#raise`) leaves it nil: a rescue clause or modifier fallback reads it unbound
    # ({ErrorInfo.rescue_entry}), and so do the code past a rescue modifier and a body a `retry` re-enters. And
    # `IO#close` on an `IO.popen` stream whose child was already reaped sets it to nil, which the analysis does not
    # model. Otherwise a `$?` once set stays a `Process::Status`, so the binding survives later calls, blocks and loops
    # until a join with a path that did not set it drops it. The root block of a new thread or ractor
    # ({FreshFrameBlocks.entry}) and a closure's body ({FreshFrameBlocks.closure_entry}) start without it, and so does
    # a method body.
    module LastStatus
      LAST_STATUS = :$?
      # The `Process` functions that wait for a child and set `$?` to its status. Their optional flags argument may
      # hold `WNOHANG`, which sets `$?` to nil instead when no child has exited.
      WAITS = Set[:wait, :waitpid, :wait2, :waitpid2].freeze
      CLEARERS = (WAITS | Set[:waitall]).freeze
      # Compared as Strings: a literal with an invalid byte (`send("\xff")`) cannot become a Symbol.
      CLEARER_NAMES = CLEARERS.to_set(&:to_s).freeze
      SENDS = Set[:send, :__send__, :public_send].freeze
      private_constant :LAST_STATUS, :WAITS, :CLEARERS, :CLEARER_NAMES, :SENDS

      module_function

      # `after`, the scope past `node`, with `$?` bound to `Process::Status` when `node` certainly ran a subprocess
      # ({.certainly_sets?}) in a file that clears `$?` nowhere.
      def after(node, after, scope)
        return after if scope.discovery.clears_last_status || !certainly_sets?(node, scope)

        after.with_global(LAST_STATUS, Type::Combinator.nominal_of("Process::Status"))
      end

      # True when running `node` certainly runs a subprocess that sets `$?` ({.sets?}): `node` itself, or a call whose
      # receiver chain does, or whose positional arguments do unless a safe-navigation call may skip them
      # (`%x(git rev-parse HEAD).strip`, `puts(%x(date))`). A subprocess in a branch, a block or an `&&` operand may not
      # run, so it does not count.
      def certainly_sets?(node, scope)
        return true if sets?(node, scope)

        case node
        when Prism::CallNode
          return true if certainly_sets?(node.receiver, scope)
          return false if node.safe_navigation?

          node.arguments&.arguments&.any? { |argument| certainly_sets?(argument, scope) } || false
        when Prism::ParenthesesNode
          body = node.body
          body.is_a?(Prism::StatementsNode) && body.body.any? { |statement| certainly_sets?(statement, scope) }
        else false
        end
      end

      # True when `node` itself runs a subprocess and waits for it, which leaves `$?` a `Process::Status`: a backtick or
      # `%x` command, `system` on implicit `self`, `self.` or `Kernel`, or `wait`, `waitpid`, `wait2` or `waitpid2`
      # on the core `Process` module with at most one plain argument, the child's pid. A program that defines a
      # method of that name anywhere ({BlockCallTiming.project_defines_anywhere?}) may run Ruby code in its place, so
      # the name sets nothing there.
      def sets?(node, scope)
        case node
        when Prism::XStringNode, Prism::InterpolatedXStringNode
          !BlockCallTiming.project_defines_anywhere?(:`, scope)
        when Prism::CallNode then subprocess_call?(node, scope)
        else false
        end
      end

      # True when `node` is a call that may set `$?` to nil: `wait`, `waitpid`, `wait2` or `waitpid2` with a flags
      # argument, a splat, keywords or a forwarded `...`, on any receiver, `waitall`, or a `send`,
      # `__send__` or `public_send` whose literal name is one of these. `Inference::ScopeIndexer` records whether a
      # file holds one ({Scope::DiscoveryIndex#clears_last_status}).
      def clears?(node)
        return false unless node.is_a?(Prism::CallNode)

        name = node.name
        return !blocking_wait_arguments?(node) if WAITS.include?(name)
        return true if name == :waitall
        return false unless SENDS.include?(name)

        sent = node.arguments&.arguments&.first
        (sent.is_a?(Prism::SymbolNode) || sent.is_a?(Prism::StringNode)) && CLEARER_NAMES.include?(sent.unescaped)
      end

      # `after`, the scope an `ensure` clause leaves, with `$?` as `entry`, the scope the clause started from, binds it
      # unless the clause bound it itself by running a subprocess: the clause read `$?` unbound, since it may run after
      # a raise that came before the body's subprocess, but the code past it runs from the `begin` that finished.
      def restore_unless_set(after, entry)
        bound = entry.global(LAST_STATUS)
        bound ? after.with_global(LAST_STATUS, bound) : after
      end

      def subprocess_call?(call_node, scope)
        name = call_node.name
        certain =
          if name == :system
            StoredBlockCall.kernel_spelled?(call_node.receiver)
          elsif WAITS.include?(name)
            blocking_wait_arguments?(call_node) && process_module?(call_node.receiver, scope)
          else
            false
          end
        certain && !BlockCallTiming.project_defines_anywhere?(name, scope)
      end

      # True when a wait call passes no flags: at most one positional argument, the pid, and no splat, keywords or
      # forwarded `...` that may hold more.
      def blocking_wait_arguments?(call_node)
        arguments = call_node.arguments&.arguments
        arguments.nil? || (arguments.size == 1 && plain_argument?(arguments.first))
      end

      def plain_argument?(argument)
        !(argument.is_a?(Prism::SplatNode) || argument.is_a?(Prism::KeywordHashNode) ||
          argument.is_a?(Prism::ForwardingArgumentsNode))
      end

      def process_module?(receiver, scope)
        return false unless StoredBlockCall.root_constant_name(receiver) == :Process

        type = scope.type_of(receiver)
        type.is_a?(Type::Singleton) && type.class_name == "Process"
      rescue StandardError
        false
      end
      private_class_method :subprocess_call?, :blocking_wait_arguments?, :plain_argument?, :process_module?
    end
  end
end
