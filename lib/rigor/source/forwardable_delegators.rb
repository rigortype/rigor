# frozen_string_literal: true

require "prism"
require_relative "literals"

module Rigor
  module Source
    # Issue #2793 — the methods a `Forwardable` / `SingleForwardable` delegator macro defines, read off its syntax
    # alone. Ruby 4.0's `forwardable.rb` is the oracle for each row:
    #
    # - `def_instance_delegator(acc, m, ali = m)` defines `ali` on the instance side;
    # - `def_instance_delegators(acc, *ms)` defines each `m` but `__send__` and `__id__`, instance side;
    # - `instance_delegate(ms => acc)` defines each key name (a name or an array of them), instance side;
    # - `def_single_delegator(s)` and `single_delegate` are the same on the singleton side;
    # - `def_delegator(s)` and `delegate` are the same on the side the `extend` decides.
    #
    # `def_delegator(s)` and `delegate` are `Forwardable`'s instance aliases and `SingleForwardable`'s singleton
    # ones, so their side is {AMBIGUOUS} and the caller settles it from the `extend` it has seen. `def_delegator :@x,
    # :last, :final` defines `final` and never `last`.
    #
    # A name the syntax does not spell (`def_delegators :@x, *NAMES`, `delegate names => :@x`) makes the delegation
    # {Delegation#open?}: the macro defines methods no reader can enumerate. `delegate` takes Forwardable's
    # single-hash form only, so ActiveSupport's `delegate :a, to: :b` (positional names before a `to:` key) is
    # not read here.
    module ForwardableDelegators
      AMBIGUOUS = :ambiguous

      # The names a delegator macro defines, on which side, and whether it also defines names its syntax hides.
      Delegation = Data.define(:side, :names, :open) do
        def open? = open
      end

      # `[side, shape]` per macro: `:alias` takes `(accessor, method, alias = method)`, `:list` takes `(accessor,
      # *methods)`, `:hash` takes `(methods => accessor, …)`.
      MACROS = Ractor.make_shareable(
        {
          def_instance_delegator: %i[instance alias], def_instance_delegators: %i[instance list],
          instance_delegate: %i[instance hash],
          def_single_delegator: %i[singleton alias], def_single_delegators: %i[singleton list],
          single_delegate: %i[singleton hash],
          def_delegator: [AMBIGUOUS, :alias], def_delegators: [AMBIGUOUS, :list], delegate: [AMBIGUOUS, :hash]
        }
      )

      # `def_instance_delegators` skips these two (`methods - [:__send__, :__id__]` in forwardable.rb).
      LIST_SKIPPED = %i[__send__ __id__].freeze
      private_constant :MACROS, :LIST_SKIPPED

      module_function

      # The {Delegation} of an implicit-self (or `self.`) delegator macro call, or nil for any other call, and for
      # one whose arguments are not a shape the macro accepts.
      def of(call_node)
        return nil unless call_node.is_a?(Prism::CallNode)
        return nil unless call_node.receiver.nil? || call_node.receiver.is_a?(Prism::SelfNode)

        side, shape = MACROS[call_node.name]
        return nil if side.nil?

        arguments = call_node.arguments&.arguments || []
        names, open = case shape
                      when :alias then alias_names(arguments)
                      when :list then list_names(arguments)
                      else hash_names(arguments)
                      end
        return nil if names.nil?

        Delegation.new(side: side, names: names.freeze, open: open)
      end

      def alias_names(arguments)
        return nil unless (2..3).cover?(arguments.size)

        name = Literals.symbol_or_string(arguments.last)
        name.nil? ? [[], true] : [[name], false]
      end

      def list_names(arguments)
        return nil if arguments.empty?

        rest = arguments.drop(1)
        names = rest.filter_map { |argument| Literals.symbol_or_string(argument) }
        [names - LIST_SKIPPED, names.size != rest.size]
      end

      def hash_names(arguments)
        return nil unless arguments.size == 1

        hash = arguments.first
        return nil unless hash.is_a?(Prism::KeywordHashNode) || hash.is_a?(Prism::HashNode)

        names = []
        open = false
        hash.elements.each do |element|
          return [[], true] unless element.is_a?(Prism::AssocNode)

          keys = key_names(element.key)
          keys.nil? ? (open = true) : names.concat(keys)
        end
        [names, open]
      end

      # The names a hash key spells — a literal name, or an array of them — or nil when any is computed.
      def key_names(key)
        elements = key.is_a?(Prism::ArrayNode) ? key.elements : [key]
        names = elements.map { |element| Literals.symbol_or_string(element) }
        names.include?(nil) ? nil : names
      end
    end
  end
end
