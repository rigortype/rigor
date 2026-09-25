# frozen_string_literal: true

require "prism"

module Rigor
  module Inference
    module MatchRebinding
      # Method names that may run a regex match, read by name alone: a Symbol or String literal naming one counts
      # ({SelfCalls.method_name_literal?}), since the method it is handed to may run it from C (`inject(:=~)`). A call
      # itself is read with its arguments ({Calls}, issue #1365).
      MATCH_CAPABLE_METHODS = %i[
        =~ match match? gsub gsub! sub sub! scan split slice slice!
        [] partition rpartition index rindex === grep grep_v
      ].freeze

      # The calls past that table that may rebind the frame they are made from, read by name alone (issue #1364), as
      # the broad reading of a frame's blocks counts them ({MatchRebinding.broad_may_match?}), and as the calls an
      # implicit-self call forgot on before issue #1365, which {Calls.base_named?} keeps forgetting on.
      module SelfCalls
        # Builtins that set their caller's `$~` and the table misses: `x !~ re`, `~re`, and `start_with?(re)`,
        # `byteindex(re)`, `byterindex(re)`, `s[re] = v` — the ones a `String` or `Regexp` subclass inherits too.
        SELF_MATCHING = Set[:!~, :~, :start_with?, :byteindex, :byterindex, :[]=].freeze
        # Predicates that run `pattern === element` from C when given an argument, even when the class's `each` is
        # written in Ruby.
        PATTERN_PREDICATES = Set[:any?, :all?, :none?, :one?].freeze
        # These run a String of code in the frame that calls them: `eval` always, the other three in their String
        # form only, since their block form is a block ({MatchRebinding.block_may_match?}).
        EVALS = Set[:eval].freeze
        STRING_EVALS = Set[:instance_eval, :class_eval, :module_eval].freeze
        # These run the method they name, which counts when it is one of {METHOD_NAMES} or not a literal.
        SENDS = Set[:send, :__send__, :public_send].freeze
        # Every name above and in the table, as Strings: a literal compares by its bytes, which an invalid one
        # (`send("\xff")`) cannot turn into a Symbol.
        METHOD_NAMES = (
          MATCH_CAPABLE_METHODS.to_set | SELF_MATCHING | PATTERN_PREDICATES | EVALS | STRING_EVALS | SENDS
        ).to_set(&:to_s).freeze
        private_constant :SELF_MATCHING, :PATTERN_PREDICATES, :EVALS, :STRING_EVALS, :SENDS, :METHOD_NAMES

        module_function

        # True when `call_node`, on any receiver, is a call past the table that may rebind the frame it is made
        # from: a {SELF_MATCHING} name; a {PATTERN_PREDICATES} name with an argument; an eval of a String
        # ({EVALS}, or {STRING_EVALS} with an argument); or a {SENDS} call whose name is not a literal, or names a
        # method that counts.
        def named_match?(call_node)
          name = call_node.name
          arguments = call_node.arguments&.arguments
          return true if SELF_MATCHING.include?(name) || EVALS.include?(name)
          return !arguments.nil? if PATTERN_PREDICATES.include?(name) || STRING_EVALS.include?(name)
          return sent_name_matches?(arguments&.first) if SENDS.include?(name)

          false
        end

        # True when a {SENDS} call's name argument is not a Symbol or String literal, or names a method that counts.
        def sent_name_matches?(name_node)
          return method_name_literal?(name_node) if literal_name?(name_node)

          true
        end

        # True when `node` is a Symbol or String literal naming the table's methods or the ones above:
        # `inject(:=~)` runs `=~` from C in the frame that calls it.
        def method_name_literal?(node)
          literal_name?(node) && METHOD_NAMES.include?(node.unescaped)
        end

        # True for `send(:binding)`, or a {SENDS} call whose name is not a literal and so may be `:binding`.
        def sends_binding?(call_node)
          return false unless SENDS.include?(call_node.name)

          name_node = call_node.arguments&.arguments&.first
          !literal_name?(name_node) || name_node.unescaped == "binding"
        end

        def literal_name?(node)
          node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
        end
        private_class_method :literal_name?
      end
    end
  end
end
