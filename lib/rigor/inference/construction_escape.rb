# frozen_string_literal: true

require "prism"
require_relative "../source/node_walker"
require_relative "../source/node_children"

module Rigor
  module Inference
    # Issue #2555 L3 — which locals of a body may have ESCAPED, so a write to them never carries the `:synthesised`
    # construction fact ({Scope#construction_fact?}).
    #
    # The fact lets the mutation seams re-grow a carrier without the `Dynamic[top]` floor, and the floor existed
    # because a store the seam does not see leaves the carrier stale. A store reaches a local's object unseen only
    # through another holder of the object: an alias (`b = a`, `a = b = Array.new(n)`), a container (`[a]`,
    # `{ k: a }`), an instance variable, a block or lambda that captures it, a call that yields or returns it
    # (`a.tap { |x| … }`, `a << :x << "s"`), reflection (`a.send(:<<, x)`, `a.method(:<<)`), or code that reaches the
    # frame itself (`binding`, `eval`). So the test is one allowlist of the positions where a read cannot hand the
    # object on, and every other reference counts as an escape:
    #
    # - the receiver of a call, other than {ESCAPING_RECEIVER_CALLS}, whose value is discarded or is a value
    #   that cannot be the receiver ({NON_SELF_READERS}, or a `?` predicate);
    # - the receiver of an index or attribute compound write (`a[0] += 1`);
    # - an argument of a call that does not store it ({STORING_CALLS}); a user method that mutates its argument is
    #   floored by the callee content floor (issue #2104) as before;
    # - the body's value position (its last statement, or `return a`), after which nothing in the body runs;
    # - a bare read whose value is discarded.
    #
    # Any reference inside a nested block or lambda is an escape, since the closure may run where the seam does not
    # see it. A write whose value is used (`a = b = …`, `foo(a = [])`) escapes the written name. The scan is flow
    # insensitive and runs once per body ({.escaped?} keeps it), so an escape anywhere in the body drops the fact
    # for the whole body: the conservative direction, since without the fact the seams answer as before.
    # A nested `def` or class body is scanned too, though its locals are its own: a same-named local there can only
    # over-report an escape, the same conservative direction.
    module ConstructionEscape
      # Calls on the receiver that hand it to code the seam does not trace, whatever happens to their value.
      ESCAPING_RECEIVER_CALLS = %i[
        send public_send __send__ method public_method singleton_method define_singleton_method
        tap then yield_self itself instance_exec instance_eval
        instance_variable_set instance_variable_get to_enum enum_for
      ].to_set.freeze

      # Calls whose value, used, is never the receiver itself. A used value of any other call (`a << x`, `a.push`,
      # `a.sort!`, `a.each`, `a.to_a`, `a.freeze`) may be the receiver, a second holder of the object.
      NON_SELF_READERS = %i[
        [] dig fetch fetch_values values_at first last sample size length count sum min max minmax min_by max_by
        sort sort_by reverse uniq compact flatten map collect flat_map collect_concat filter_map select filter
        reject find detect find_index index rindex take drop take_while drop_while group_by partition chunk_while
        slice_when each_with_object inject reduce zip join keys values key tally to_s inspect hash dup clone
        slice + - * & | <=> == != === =~ merge transform_values transform_keys invert pop shift delete delete_at
        slice! object_id class frozen? bytesize
      ].to_set.freeze

      # Conversions that answer the receiver itself on one carrier class and a new object on the others: `Array#to_a`,
      # `Hash#to_h`, `Set#to_set`. A used one escapes only a local of that class.
      SELF_CONVERSIONS = { to_a: "Array", to_h: "Hash", to_set: "Set" }.freeze

      # Calls that keep a reference to an argument: storing it in their receiver, or in a variable or a method.
      STORING_CALLS = %i[
        << push append unshift prepend insert []= store add add? fill default= instance_variable_set
        class_variable_set const_set define_method send public_send __send__
      ].to_set.freeze

      # Calls that read or rebind the frame's locals by name: one anywhere in a body escapes every local in it.
      FRAME_CALLS = %i[binding eval local_variable_set instance_variable_set].to_set.freeze
      STRING_EVAL_CALLS = %i[instance_eval class_eval module_eval].to_set.freeze

      CLOSURES = [Prism::BlockNode, Prism::LambdaNode].freeze
      LOCAL_REFERENCES = [
        Prism::LocalVariableReadNode, Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode,
        Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode, Prism::LocalVariableTargetNode
      ].freeze
      LOCAL_WRITES = [
        Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode,
        Prism::LocalVariableAndWriteNode
      ].freeze
      RECEIVER_WRITES = [
        Prism::IndexOperatorWriteNode, Prism::IndexOrWriteNode, Prism::IndexAndWriteNode,
        Prism::CallOperatorWriteNode, Prism::CallOrWriteNode, Prism::CallAndWriteNode
      ].freeze
      ALL = :all
      CACHE_KEY = :__rigor_construction_escape
      private_constant :CLOSURES, :LOCAL_REFERENCES, :LOCAL_WRITES, :RECEIVER_WRITES, :ALL,
                       :CACHE_KEY, :STRING_EVAL_CALLS

      module_function

      # True when the local `name`, bound to a carrier of `class_name`, may escape somewhere in `body`, or when
      # `body` is unknown.
      def escaped?(body, name, class_name)
        return true if body.nil?

        table = (Thread.current[CACHE_KEY] ||= ObjectSpace::WeakKeyMap.new)
        escaped = table[body] ||= scan(body)
        return true if escaped.equal?(ALL)

        reason = escaped[name]
        !reason.nil? && (reason.equal?(ALL) || reason.include?(class_name))
      end

      # `{ name => ALL | Set[class name] }`: a name escapes outright, or only when bound to one of the classes whose
      # {SELF_CONVERSIONS} it calls with the value used.
      def scan(body)
        escaped = {}
        Source::NodeWalker.each_with_ancestors(body) do |node, ancestors|
          return ALL if frame_call?(node)
          next unless LOCAL_REFERENCES.any? { |k| node.is_a?(k) }

          record(escaped, node.name, escape_reason(node, ancestors))
        end
        escaped.freeze
      end

      def record(escaped, name, reason)
        return if reason.nil? || escaped[name].equal?(ALL)

        escaped[name] = reason.equal?(ALL) ? ALL : (escaped[name] || Set.new) << reason
      end

      # ALL when the reference escapes, the class name when it escapes only a local of that class, nil otherwise.
      def escape_reason(node, ancestors)
        return ALL if escapes?(node, ancestors)
        return nil unless node.is_a?(Prism::LocalVariableReadNode)

        call = ancestors.last
        return nil unless call.is_a?(Prism::CallNode) && call.receiver.equal?(node)

        SELF_CONVERSIONS[call.name] if value_used?(ancestors, ancestors.size - 2, call)
      end

      def frame_call?(node)
        return false unless node.is_a?(Prism::CallNode)

        FRAME_CALLS.include?(node.name) || (STRING_EVAL_CALLS.include?(node.name) && !node.arguments.nil?)
      end

      def escapes?(node, ancestors)
        return true if ancestors.any? { |a| CLOSURES.any? { |k| a.is_a?(k) } }
        return value_used?(ancestors, ancestors.size - 1, node) if LOCAL_WRITES.any? { |k| node.is_a?(k) }
        return false unless node.is_a?(Prism::LocalVariableReadNode)

        !allowed_read?(node, ancestors)
      end

      def allowed_read?(read, ancestors)
        parent = ancestors.last
        case parent
        when Prism::CallNode then receiver_read_allowed?(read, parent, ancestors)
        when Prism::ArgumentsNode then argument_allowed?(ancestors[-2])
        when Prism::StatementsNode then !value_used?(ancestors, ancestors.size - 1, read)
        else RECEIVER_WRITES.any? { |k| parent.is_a?(k) } && parent.receiver.equal?(read)
        end
      end

      def receiver_read_allowed?(read, call, ancestors)
        return false unless call.receiver.equal?(read)
        return false if ESCAPING_RECEIVER_CALLS.include?(call.name)
        return true unless value_used?(ancestors, ancestors.size - 2, call)

        NON_SELF_READERS.include?(call.name) || SELF_CONVERSIONS.key?(call.name) || call.name.end_with?("?")
      end

      def argument_allowed?(owner)
        case owner
        when Prism::ReturnNode then true
        when Prism::CallNode then !STORING_CALLS.include?(owner.name)
        else false
        end
      end

      # Whether the value of `node`, whose parent is `ancestors[index]`, reaches anything. The body's own value (its
      # last statement) is the return position, after which nothing in the body runs, so it reads as unused.
      def value_used?(ancestors, index, node)
        while index >= 0
          parent = ancestors[index]
          case parent
          when Prism::StatementsNode
            return false unless parent.body.last.equal?(node)
          when Prism::IfNode, Prism::UnlessNode, Prism::CaseNode, Prism::CaseMatchNode
            return true if parent.predicate.equal?(node)
          when Prism::WhenNode, Prism::InNode
            return true unless parent.statements.equal?(node)
          when Prism::WhileNode, Prism::UntilNode, Prism::EnsureNode
            return !parent.statements.equal?(node)
          when Prism::ElseNode, Prism::BeginNode, Prism::ParenthesesNode, Prism::ProgramNode, Prism::RescueNode
            nil
          else
            return true
          end
          node = parent
          index -= 1
        end
        false
      end
    end
  end
end
