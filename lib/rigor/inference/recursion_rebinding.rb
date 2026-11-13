# frozen_string_literal: true

require "prism"
require_relative "../source/node_walker"

module Rigor
  module Inference
    # Which of a def's parameters its own recursion rebinds (issue #3115). The bot-collapse retry of
    # `ExpressionTyper#fixpoint_user_method_return` types the body once for every call the recursion makes, and a
    # recursive call binds a parameter to whatever it passes: `tog(n: n - 1, f: !f)` gives `f` a value the
    # outer call never held. A parameter is KEPT only when every call to the def's own name inside the body
    # passes it the same parameter read unchanged (`cfg(n - 1, mode)` keeps `mode`), and the body never
    # assigns it; every other parameter is rebound, and the retry binds it `Dynamic[top]`.
    #
    # The test is syntactic and reads only the def. A call counts by its method name alone, whatever its
    # receiver (`child.depth(n + 1)` re-enters the same recursion guard), so a same-named method of another
    # class is read as a recursive call too, which only rebinds more. The caller supplies the def's other
    # names (`alias`), since the def does not carry them. A call to ANOTHER method that recurses back (mutual
    # recursion) is not followed: its parameters are judged by the def's own calls alone.
    #
    # Two shapes the test cannot read rebind more instead. A body that calls a method by a computed name
    # ({REFLECTIVE_CALLS}) may recurse with any arguments, so every parameter is rebound ({ALL}). A name a
    # block or lambda in the body declares (a parameter, a block-local, `it`) is rebound, because a read of
    # it inside that block is the block's variable, not the parameter.
    module RecursionRebinding
      module_function

      LOCAL_WRITE_NODES = Set[
        Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode,
        Prism::LocalVariableAndWriteNode, Prism::LocalVariableTargetNode
      ].freeze
      private_constant :LOCAL_WRITE_NODES

      # The calls that reach a method by a name the scan cannot read.
      REFLECTIVE_CALLS = Set[:send, :__send__, :public_send, :method, :instance_method, :define_method].freeze
      private_constant :REFLECTIVE_CALLS

      # {.rebound_parameters}'s answer when every parameter is rebound.
      ALL = :all

      # The names the body's recursive calls, its blocks or its own assignments rebind, as a Set, or {ALL}. The
      # Set may hold a name that is no parameter (any assigned local); the caller looks up parameters only.
      # `names` is every name the def answers to: its own and its aliases.
      def rebound_parameters(def_node, names = Set[def_node.name])
        params = def_node.parameters
        return Set.new unless params.is_a?(Prism::ParametersNode)

        rebound = Set.new
        catch(ALL) { collect(def_node.body, names, params, rebound) } == ALL ? ALL : rebound
      end

      # Every method name the body calls, for the caller to ask which of them are this def's aliases.
      def called_names(node, names = Set.new)
        return names if node.nil?

        names << node.name if node.is_a?(Prism::CallNode)
        node.rigor_each_child { |child| called_names(child, names) }
        names
      end

      def collect(node, names, params, rebound)
        return if node.nil?

        case node
        when *LOCAL_WRITE_NODES then rebound << node.name
        when Prism::BlockNode, Prism::LambdaNode then note_block(node, rebound)
        when Prism::CallNode
          throw ALL, ALL if REFLECTIVE_CALLS.include?(node.name)

          note_call(node, params, rebound) if names.include?(node.name)
        end
        node.rigor_each_child { |child| collect(child, names, params, rebound) }
      end

      # A block's `locals` are its parameters, its block-locals and the locals it first assigns; `it` is not
      # among them.
      def note_block(block, rebound)
        rebound.merge(block.locals)
        rebound << :it if block.parameters.is_a?(Prism::ItParametersNode)
      end

      def note_call(call, params, rebound)
        args = call.arguments&.arguments || []
        keywords = args.last if args.last.is_a?(Prism::KeywordHashNode)
        positional = keywords ? args[0...-1] : args
        forwarding = args.any?(Prism::ForwardingArgumentsNode)
        note_positionals(params, positional, rebound)
        note_keywords(params, keywords, forwarding, rebound)
      end

      # Positionals correspond by index up to the first `*splat` (or `...`), which may reach every slot from
      # its own on. The rest parameter is kept only by `*rest` in its own place as the last positional.
      def note_positionals(params, positional, rebound)
        slots = params.requireds + params.optionals
        cut = positional.index { |arg| arg.is_a?(Prism::SplatNode) || arg.is_a?(Prism::ForwardingArgumentsNode) }
        cut ||= positional.size
        slots.each_with_index do |param, index|
          next if param.is_a?(Prism::MultiTargetNode)

          rebound << param.name unless index < cut && reads?(positional[index], param.name)
        end
        note_rest(params.rest, positional[slots.size..] || [], cut >= slots.size, rebound)
      end

      def note_rest(rest, tail, aligned, rebound)
        return unless rest.is_a?(Prism::RestParameterNode) && rest.name

        splat = tail.first
        kept = aligned && tail.size == 1 && splat.is_a?(Prism::SplatNode) && reads?(splat.expression, rest.name)
        rebound << rest.name unless kept
      end

      # Keywords correspond by name. A keyword the call omits falls back to its default, so it is rebound. A
      # `**splat` other than the def's own `**rest`, a non-Symbol key or `...` may carry any keyword, so each of
      # them rebinds every keyword. `**rest` is kept by `**rest` alone, with no key beside it that it would collect.
      def note_keywords(params, keywords, forwarding, rebound)
        names = params.keywords.map { |param| param.name.to_s.delete_suffix(":").to_sym }
        rest_name = keyword_rest_name(params)
        passed, splats, opaque = keyword_entries(keywords)
        opaque ||= forwarding || splats.any? { |value| !reads?(value, rest_name) }
        return rebound.merge(names, [rest_name].compact) if opaque

        names.each { |name| rebound << name unless reads?(passed[name], name) }
        rebound << rest_name if rest_name && !(splats.size == 1 && (passed.keys - names).empty?)
      end

      def keyword_rest_name(params)
        rest = params.keyword_rest
        rest.name if rest.is_a?(Prism::KeywordRestParameterNode)
      end

      # The call's keyword hash as `[{ name => value node }, [**splat value nodes], opaque]`, `opaque` when
      # a key is not a plain Symbol.
      def keyword_entries(keywords)
        passed = {}
        splats = []
        opaque = false
        (keywords&.elements || []).each do |element|
          if element.is_a?(Prism::AssocSplatNode)
            splats << element.value
          elsif element.key.is_a?(Prism::SymbolNode) && element.key.unescaped
            passed[element.key.unescaped.to_sym] = element.value
          else
            opaque = true
          end
        end
        [passed, splats, opaque]
      end

      # Whether `node` is a bare read of the local `name` (`n`, or the `n:` shorthand's implicit read).
      def reads?(node, name)
        node = node.value if node.is_a?(Prism::ImplicitNode)
        !name.nil? && node.is_a?(Prism::LocalVariableReadNode) && node.name == name
      end
    end
  end
end
