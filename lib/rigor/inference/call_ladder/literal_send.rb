# frozen_string_literal: true

require "prism"

require_relative "../genuine_send"
require_relative "../method_dispatcher"
require_relative "project_singleton"
require_relative "user_method"

module Rigor
  module Inference
    module CallLadder
      # The `literal_send` rung of the call ladder (ADR-116 WD12): `recv.send(:name, …)` with a literal name, typed as
      # `recv.name(…)` would be. `ExpressionTyper` asks it in a call's ladder, behind the refined rung. Its own
      # sequence is the `send_target` entry of `CallLadder::ENTRIES`: the target is a site of its own (the inner name
      # and arguments, no block), asked of the dispatcher and then of the user-method and project-singleton rungs, and
      # a receiver with a `send` of its own is answered ahead of them from that `send`'s body. {ExpressionTyper} is not
      # required here: it requires this file, and `Scope` is loaded before either.
      #
      # {.try_call} is the rung, asked with the call's site and the walking typer, and the module's one entry. Every
      # other function is private to the module.
      #
      # The module holds no state. It reads the scope as `typer.scope` and calls back one method of the typer,
      # `type_of`, for the target's arguments. That is the typer's own entry, public for every caller, and
      # `CallLadder::PORT` lists it as a public callback (`CallLadder::PUBLIC_CALLBACKS`), not a re-entry point. The
      # module hands the typer on only to the two rungs it asks, and to `CallLadder::UserMethod.infer` for an own
      # `send`.
      module LiteralSend
        module_function

        # Issue #533 — `x.send(:selector, args)` with a LITERAL symbol is statically `x.selector(args)`:
        # the private-boundary idiom (protobuf's `send(:get_file_descriptor)` at 84 sites) resolves through
        # the same dispatch + project-inference tiers as the direct call would. `send` legitimately crosses
        # visibility, so no public-only gate applies (`public_send` is treated identically — typing the
        # success path of a call that would raise on a private method is ADR-5 optimism). Declines: a
        # non-literal selector, a splat / forwarded tail (positional correspondence unknown), or a block at
        # the call site (block forwarding is out of this slice). The sequence is `send_target` in {CallLadder::RUNGS}.
        #
        # Issue #3080 — `send` reads as its target only where the receiver's `send` is `Kernel#send`
        # ({GenuineSend.type?}). A class with its own `send` (`def send(message, flags)`, `UDPSocket#send`, a project
        # RBS `def send:`) is called like any other method. `__send__` and `public_send` are other methods and keep
        # the reading.
        LITERAL_SEND_SELECTORS = %i[send __send__ public_send].freeze
        private_constant :LITERAL_SEND_SELECTORS

        # The rung, asked with the call's site: its call node and receiver are the `send`'s.
        def try_call(site, typer)
          node = site.call_node
          receiver = site.receiver
          args = literal_send_arguments(node)
          return nil if args.nil?
          if node.name == :send && !GenuineSend.type?(receiver, typer.scope)
            return own_send_type(node, receiver, args, typer)
          end

          rest = args[1..]
          inner_name = args.first.unescaped.to_sym
          inner_args = rest.map { |a| typer.type_of(a) }
          target = MethodDispatcher::CallContext.build(
            receiver: receiver, method_name: inner_name, args: inner_args,
            block_type: nil, environment: typer.scope.environment, call_node: node, scope: typer.scope
          )
          MethodDispatcher.dispatch_site(target) || CallLadder::UserMethod.try_call(target, typer) ||
            CallLadder::ProjectSingleton.try_call(target, typer)
        end

        # The arguments of a literal-selector `send` / `__send__` / `public_send` call with no block and no splat or
        # forwarded tail, or nil.
        def literal_send_arguments(node)
          return nil unless LITERAL_SEND_SELECTORS.include?(node.name)
          return nil unless node.block.nil?

          args = node.arguments&.arguments
          return nil unless args && args.first.is_a?(Prism::SymbolNode)
          return nil if args.any? { |a| a.is_a?(Prism::SplatNode) || a.is_a?(Prism::ForwardingArgumentsNode) }

          args
        end

        # Issue #3080 — the receiver's own `send`. A project `def send` comes before `Kernel#send` in every chain that
        # reaches it, so where the only declaration Ruby reaches is `Kernel#send` (or there is none) the body answers
        # the call, ahead of the `Kernel#send` declaration the ordinary dispatch would read off `Object`. Where an RBS
        # `def send:` reaches the receiver from the class itself or from an ancestor (an overload included), that
        # declaration is the contract (its `void`, its return type), so nil hands the call to the ordinary dispatch,
        # as for any other declared method. Nil too
        # where no body can be read: a union or class-object receiver.
        def own_send_type(node, receiver, args, typer)
          return nil unless CallLadder::UserMethod.user_inference_receiver?(receiver)
          return nil unless GenuineSend.rbs_genuine?(receiver.class_name, :instance, typer.scope)

          CallLadder::UserMethod.infer(receiver, node, args.map { |a| typer.type_of(a) }, node.name, nil, typer)
        end

        private_class_method :literal_send_arguments, :own_send_type
      end
    end
  end
end
