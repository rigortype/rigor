# frozen_string_literal: true

require "prism"
require_relative "../type"

module Rigor
  module SigGen
    # Issue #3029 — decides which emittable `-> bot` proposals are skipped instead.
    #
    # A `bot` return is right when it is the method's final behaviour: a `throw`, or a deliberate error nothing
    # overrides. It is wrong when the raising body is a base the program replaces. Every override returns a value,
    # so a `bot` declaration breaks Liskov compatibility with each of them, and a collection author reading the
    # proposal cannot see an override outside the analysed code. Three readings skip a `bot` proposal, checked in
    # this order:
    #
    # - `:overridden_bot` — the method is overridden somewhere in the analysed code: by a subclass, signed or not,
    #   by a class that includes the method's module, or by a module that comes earlier in some class's ancestors.
    # - `:abstract_method` — the body ends in an abstract-style raise: `NotImplementedError`, an error class named
    #   `Abstract…` / `NotImplemented…`, or a message that asks for an implementation or an override.
    # - `:template_method` — the body does not end in a direct `raise` / `fail` / `throw` / `exit` / `abort`, and it
    #   calls a method that is overridden or abstract in the analysed code, directly or through a chain of
    #   self-dispatched calls. Its `bot` may come from the base body of that call.
    #
    # The reading is over the project's discovery tables, by name. The ancestor names are not resolved precisely: a
    # `superclass` or `include` token stands for every class its lexical nesting could mean, and a call matches any
    # method of its name whatever the receiver. Both over-approximations only skip more `bot` proposals, which is
    # the safe direction for a proposal (ADR-5).
    class BotProposalGuard
      TERMINATORS = %i[raise fail throw exit exit! abort].freeze
      RAISERS = %i[raise fail].freeze
      ABSTRACT_ERROR = /NotImplemented|\AAbstract/
      ABSTRACT_MESSAGE = /implement|abstract|overrid|subclass/i
      private_constant :TERMINATORS, :RAISERS, :ABSTRACT_ERROR, :ABSTRACT_MESSAGE

      # @param tables — the project's discovery tables ({Inference::ProjectSeedTables}).
      def initialize(tables)
        @instance_defs = tables[:discovered_def_nodes] || {}
        @singleton_defs = tables[:discovered_singleton_def_nodes] || {}
        @superclasses = tables[:discovered_superclasses] || {}
        @includes = tables[:discovered_includes] || {}
      end

      # The skip reason for `candidate`, or nil when its proposal stands. Only an emittable `bot` return is read.
      def reason_for(candidate)
        return nil unless candidate.inferred_return.is_a?(Type::Bot)
        return nil if candidate.class_name.nil?

        kind = candidate.kind == :singleton ? :singleton : :instance
        return :overridden_bot if overridden.include?([candidate.class_name, candidate.method_name, kind])

        node = defs_for(kind).dig(candidate.class_name, candidate.method_name)
        return nil unless node.is_a?(Prism::DefNode)
        return :abstract_method if abstract_body?(node)
        return :template_method if !ends_in_terminator?(node) && calls_dispatch_open?(node)

        nil
      end

      private

      def defs_for(kind) = kind == :singleton ? @singleton_defs : @instance_defs

      # `[owner, method name, kind]` for every definition another one shadows in some class's ancestors.
      def overridden
        @overridden ||= Set.new.tap do |acc|
          collect_overridden(@instance_defs, :instance, acc) { |name| instance_ancestors(name) }
          collect_overridden(@singleton_defs, :singleton, acc) { |name| singleton_ancestors(name) }
        end
      end

      def collect_overridden(defs, kind, acc)
        class_names.each do |class_name|
          seen = Set.new
          yield(class_name).each do |owner|
            (defs[owner] || {}).each_key do |method_name|
              acc << [owner, method_name, kind] unless seen.add?(method_name)
            end
          end
        end
      end

      def class_names
        @class_names ||= (@instance_defs.keys + @singleton_defs.keys + @superclasses.keys + @includes.keys).uniq
      end

      # The class's ancestors, nearest first: itself, its included modules (the last `include` first), then its
      # superclass's.
      def instance_ancestors(class_name, visiting = Set.new)
        @instance_ancestors ||= {}
        return @instance_ancestors[class_name] if @instance_ancestors.key?(class_name)
        return [] unless visiting.add?(class_name)

        mixins = Array(@includes[class_name]).reverse.flat_map { |token| resolutions(token, class_name) }
        parents = mixins + superclass_resolutions(class_name)
        @instance_ancestors[class_name] =
          ([class_name] + parents.flat_map { |parent| instance_ancestors(parent, visiting) }).uniq
      end

      def singleton_ancestors(class_name, visiting = Set.new)
        @singleton_ancestors ||= {}
        return @singleton_ancestors[class_name] if @singleton_ancestors.key?(class_name)
        return [] unless visiting.add?(class_name)

        @singleton_ancestors[class_name] =
          ([class_name] + superclass_resolutions(class_name).flat_map { |p| singleton_ancestors(p, visiting) }).uniq
      end

      def superclass_resolutions(class_name)
        token = @superclasses[class_name]
        token ? resolutions(token, class_name) : []
      end

      # Every class a constant token written in `class_name`'s body or header could name: the token under each of
      # the class's enclosing namespaces, innermost first, and at the top level. The class itself is left out.
      def resolutions(token, class_name)
        bare = token.to_s.sub(/\[.*\z/m, "")
        return [bare.delete_prefix("::")] if bare.start_with?("::")

        segments = class_name.split("::")
        names = segments.size.downto(0).map { |n| (segments.first(n) + [bare]).join("::") }
        names.uniq - [class_name]
      end

      # Method names whose base body a call may not run: an overridden or abstract method, and every method that
      # reaches one through self-dispatched calls.
      def dispatch_open_names
        @dispatch_open_names ||= begin
          open = Set.new(overridden.map { |_, method_name, _| method_name })
          each_def { |method_name, node| open << method_name if abstract_body?(node) }
          close_over_self_calls(open)
        end
      end

      def close_over_self_calls(open)
        callers = Hash.new { |h, k| h[k] = Set.new }
        each_def { |method_name, node| self_called_names(node).each { |callee| callers[callee] << method_name } }
        queue = open.to_a
        callers.fetch(queue.shift, []).each { |caller| queue << caller if open.add?(caller) } until queue.empty?
        open
      end

      def each_def(&)
        [@instance_defs, @singleton_defs].each do |defs|
          defs.each_value do |by_name|
            by_name.each { |method_name, node| yield(method_name, node) if node.is_a?(Prism::DefNode) }
          end
        end
      end

      def statements(node)
        body = node.body
        case body
        when nil then []
        when Prism::StatementsNode then body.body
        else [body]
        end
      end

      def ends_in_terminator?(node)
        last = statements(node).last
        last.is_a?(Prism::CallNode) && last.receiver.nil? && TERMINATORS.include?(last.name)
      end

      def abstract_body?(node)
        last = statements(node).last
        return false unless last.is_a?(Prism::CallNode) && last.receiver.nil? && RAISERS.include?(last.name)

        args = last.arguments&.arguments || []
        abstract_raise_arguments?(args)
      end

      # `raise NotImplementedError`, `raise Error, "please implement"`, `raise Error.new("subclasses override")`,
      # `raise "abstract"`.
      def abstract_raise_arguments?(args)
        first = args.first
        if first.is_a?(Prism::CallNode) && first.name == :new
          error = first.receiver
          message = first.arguments&.arguments&.first
        else
          error = first
          message = args[1]
        end
        return abstract_message?(error) unless constant?(error)

        ABSTRACT_ERROR.match?(constant_name(error)) || abstract_message?(message)
      end

      def constant?(node) = node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

      # The last segment: `Foo::NotImplemented` reads as `NotImplemented`.
      def constant_name(node) = node.name.to_s

      def abstract_message?(node)
        text =
          case node
          when Prism::StringNode then node.unescaped
          when Prism::InterpolatedStringNode
            node.parts.grep(Prism::StringNode).map(&:unescaped).join
          end
        !text.nil? && ABSTRACT_MESSAGE.match?(text)
      end

      def calls_dispatch_open?(node) = calls(node).any? { |call| dispatch_open_names.include?(call.name) }

      def self_called_names(node)
        calls(node).select { |call| call.receiver.nil? || call.receiver.is_a?(Prism::SelfNode) }.map(&:name)
      end

      # The calls in the def's body, not those of a nested `def`, whose body belongs to another method.
      def calls(node)
        @calls ||= {}.compare_by_identity
        @calls[node] ||= begin
          out = []
          stack = node.body ? [node.body] : []
          until stack.empty?
            current = stack.pop
            next if current.is_a?(Prism::DefNode)

            out << current if current.is_a?(Prism::CallNode)
            stack.concat(current.compact_child_nodes)
          end
          out
        end
      end
    end
  end
end
