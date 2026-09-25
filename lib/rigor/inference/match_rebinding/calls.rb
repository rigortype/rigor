# frozen_string_literal: true

require "prism"

module Rigor
  module Inference
    module MatchRebinding
      # Whether a call a statement runs rebinds the `$~` of the frame it is made in by the method it calls, on any
      # receiver (issue #1365). Two readings, split by what the analyzer did before, so that no position newly keeps
      # a narrowing Ruby rebinds and none newly forgets one it keeps on a guess:
      #
      # - a call the statement-level name table forgot on ({MATCH_CAPABLE_METHODS}, and for an implicit-self call
      #   {SelfCalls.named_match?}) still forgets unless its syntax proves it cannot match ({.forgets_by_name?}):
      #   `row[:name]`, `csv.split(",")` and `list.index(3)` keep the narrowing, `row[key]` does not. A flow type
      #   is not proof, because it can be stale while the value is a Regexp (#1380);
      # - a call in a position that never forgot — an operand, an explicit-receiver builtin outside the table, an
      #   index write, a `send` or an `eval` — forgets only on evidence that it matches ({.rebinds?}).
      module Calls
        # These rebind `$~` whatever their argument: `sub` / `gsub` / `scan` with a String pattern still set it,
        # `match` compiles one, and `!~` runs `=~`.
        ALWAYS_MATCHING = Set[:=~, :!~, :match, :sub, :sub!, :gsub, :gsub!, :scan].freeze
        # These rebind it only when an argument is a Regexp: `"a,b".split(",")`, `"abc"["z"]`, `list.index(3)`,
        # `{name: 1}[:name]` and `%w[a].any?(String)` leave it alone.
        LOOKUPS = Set[
          :[], :slice, :slice!, :index, :rindex, :byteindex, :byterindex, :partition, :rpartition, :split,
          :start_with?, :any?, :all?, :none?, :one?
        ].freeze
        # `grep` / `grep_v` rebind the caller's `$~` only in their block form.
        BLOCK_FORM_LOOKUPS = Set[:grep, :grep_v].freeze
        # `a === b` is `a`'s method, and `~re` matches `$_`, so these read the receiver: `String === s` and `~1`
        # run no match.
        RECEIVER_PATTERNS = Set[:===, :~].freeze
        # These run a String of code in the frame that calls them: `eval` (`Kernel.eval`, `binding.eval`), and the
        # other three in their String form, since their block form is a block.
        EVALS = Set[:eval, :instance_eval, :class_eval, :module_eval].freeze
        # These run the method they name.
        SENDS = Set[:send, :__send__, :public_send].freeze
        # A literal name a `send` compares by its bytes, which an invalid one (`send("\xff")`) cannot turn into a
        # Symbol.
        NAMES_BY_STRING = (
          ALWAYS_MATCHING | LOOKUPS | BLOCK_FORM_LOOKUPS | RECEIVER_PATTERNS | EVALS | SENDS | Set[:[]=]
        ).to_h { |name| [name.to_s, name] }.freeze
        # An interpolated String of code is parsed with each interpolation standing for this identifier; when that
        # does not parse, the code counts if its literal text names a match ({MATCH_TOKENS}).
        PLACEHOLDER = "__rigor_interpolation__"
        MATCH_TOKENS = %w[=~ !~ match sub scan $~ ===].freeze
        # Operators a computed `send` name may end in that are not attribute writers.
        OPERATOR_SUFFIXES = %w[== != <= >=].freeze
        EMPTY = [].freeze
        private_constant :ALWAYS_MATCHING, :LOOKUPS, :BLOCK_FORM_LOOKUPS, :RECEIVER_PATTERNS, :EVALS, :SENDS,
                         :NAMES_BY_STRING, :PLACEHOLDER, :MATCH_TOKENS, :OPERATOR_SUFFIXES, :EMPTY

        module_function

        # True when the statement-level name table forgot on `call_node` before issue #1365: one of its names on any
        # receiver, or, for an implicit-self call and a call in its arguments, a name {SelfCalls.named_match?} reads.
        def base_named?(call_node, implicit:)
          MATCH_CAPABLE_METHODS.include?(call_node.name) || (implicit && SelfCalls.named_match?(call_node))
        end

        # True when a call {.base_named?} names may still rebind `$~`: every such call does unless its syntax proves
        # it cannot. `match?` never matches; `grep` / `grep_v` without a block do not rebind the caller's `$~`; a
        # lookup, `start_with?`, `byteindex`, `byterindex` or pattern predicate whose arguments are all non-Regexp
        # literals ({Operands.keep_literal?}), and `[]=` whose index is, run no match; nor does `===` on such a
        # literal or on a constant naming a class or module. Any other argument counts as it did, whatever its flow
        # type (#1380), and so do `=~`, `!~`, `match`, `sub`, `gsub`, `scan`, `~`, an eval and a `send`.
        def forgets_by_name?(call_node, scope)
          name = call_node.name
          arguments = call_node.arguments&.arguments || EMPTY
          return true if ALWAYS_MATCHING.include?(name) || name == :~
          return false if name == :match?
          return !keep_receiver?(call_node.receiver, scope) if name == :===
          return !call_node.block.nil? && !keep_arguments?(arguments) if BLOCK_FORM_LOOKUPS.include?(name)
          return !keep_arguments?(arguments[0...-1]) if name == :[]=
          return !keep_arguments?(arguments) if LOOKUPS.include?(name)

          true
        end

        # True when `call_node`, a statement's own call, may rebind the match globals of the frame it is made in once
        # its operands have run. A call {.base_named?} names still forgets unless its syntax proves it cannot
        # ({.forgets_by_name?}); any other forgets when it is known to match ({.rebinds?}). An implicit-self or
        # `self.` call also forgets where it may reach the frame's slot although it does not match itself: where the
        # frame hands its slot to code the analyzer does not trace ({Frame#self_call_fallback?}), where no body
        # stamped a frame, or where its arguments hold something {MatchRebinding.operand_may_match?} counts. Any
        # other call runs a method in a frame of its own (issue #1364) or a C method that does not match.
        def statement_rebinds?(call_node, scope)
          receiver = call_node.receiver
          implicit = receiver.nil? || receiver.is_a?(Prism::SelfNode)
          if base_named?(call_node, implicit: implicit)
            return true if forgets_by_name?(call_node, scope)
          elsif rebinds?(call_node, scope)
            return true
          end
          return false unless implicit

          frame = scope&.match_frame
          frame.nil? || frame.self_call_fallback?(scope) ||
            MatchRebinding.operand_may_match?(call_node.arguments, scope)
        end

        # True when `node`, a call, is known to rebind the `$~` of the frame it is made in by the method it calls:
        # an {ALWAYS_MATCHING} name; a {LOOKUPS} name with an argument known to be a Regexp
        # ({Operands.known_regexp_operand?}), and `grep` / `grep_v` on the same terms in their block form; `[]=` with
        # such an index (`s[re] = v`); `===` or unary `~` on such a receiver; an eval of a String whose code may match
        # ({.code_may_match?}); or a {SENDS} call that names one of these with the arguments it is sent, or whose
        # computed name is sent a known Regexp (not an interpolated attribute writer, `"#{name}="`). `match?` never
        # counts, and `Dynamic[top]` is not a known Regexp. `node` may also be an index `||=` / `&&=` / `op=` write,
        # read by its index (`s[re] ||= v`). `scope` types the operands.
        def rebinds?(node, scope)
          arguments = node.arguments&.arguments || EMPTY
          return known_arguments?(arguments, scope) unless node.is_a?(Prism::CallNode)

          named?(node.name, node.receiver, arguments, !node.block.nil?, scope)
        end

        def named?(name, receiver, arguments, block, scope)
          return true if ALWAYS_MATCHING.include?(name)
          return !receiver.nil? && Operands.known_regexp_operand?(receiver, scope) if RECEIVER_PATTERNS.include?(name)
          return false if arguments.empty?
          return code_may_match?(arguments.first, scope) if EVALS.include?(name)
          return sent?(receiver, arguments, block, scope) if SENDS.include?(name)
          return known_arguments?(arguments[0...-1], scope) if name == :[]=
          return block && known_arguments?(arguments, scope) if BLOCK_FORM_LOOKUPS.include?(name)

          LOOKUPS.include?(name) && known_arguments?(arguments, scope)
        end
        private_class_method :named?

        def sent?(receiver, arguments, block, scope)
          name_node, *rest = arguments
          if name_node.is_a?(Prism::SymbolNode) || name_node.is_a?(Prism::StringNode)
            name = NAMES_BY_STRING[name_node.unescaped]
            return !name.nil? && named?(name, receiver, rest, block, scope)
          end
          return false if attribute_writer_name?(name_node)

          known_arguments?(rest, scope)
        end
        private_class_method :sent?

        # `"#{name}="` or `:"#{name}="` names a writer, which runs in a frame of its own.
        def attribute_writer_name?(node)
          return false unless node.is_a?(Prism::InterpolatedStringNode) || node.is_a?(Prism::InterpolatedSymbolNode)

          tail = node.parts.last
          text = tail.is_a?(Prism::StringNode) ? tail.unescaped : ""
          text.end_with?("=") && OPERATOR_SUFFIXES.none? { |suffix| text.end_with?(suffix) }
        end
        private_class_method :attribute_writer_name?

        # True when a String of code an eval runs may match: a literal that parses and whose program
        # {MatchRebinding.program_may_match?} accepts, or an interpolated one read the same way with each
        # interpolation replaced by an identifier, falling back to whether its literal text names a match
        # ({MATCH_TOKENS}) when that does not parse. Code the analyzer cannot read (a variable) does not count,
        # and neither does a literal that does not parse, which raises before it runs.
        def code_may_match?(node, scope)
          case node
          when Prism::StringNode then parsed_answer(node.unescaped, scope) || false
          when Prism::InterpolatedStringNode
            text = node.parts.map { |part| part.is_a?(Prism::StringNode) ? part.unescaped : PLACEHOLDER }.join
            answer = parsed_answer(text, scope)
            answer.nil? ? MATCH_TOKENS.any? { |token| text.include?(token) } : answer
          else false
          end
        end
        private_class_method :code_may_match?

        # Whether `code` may match, or nil when it does not parse.
        def parsed_answer(code, scope)
          result = Prism.parse(code)
          return nil unless result.errors.empty?

          MatchRebinding.program_may_match?(result.value, scope)
        rescue StandardError
          nil
        end
        private_class_method :parsed_answer

        def keep_arguments?(arguments)
          arguments.all? { |argument| Operands.keep_literal?(argument) }
        end
        private_class_method :keep_arguments?

        def keep_receiver?(receiver, scope)
          !receiver.nil? && (Operands.keep_literal?(receiver) || Operands.class_constant?(receiver, scope))
        end
        private_class_method :keep_receiver?

        def known_arguments?(arguments, scope)
          arguments.any? { |argument| Operands.known_regexp_operand?(argument, scope) }
        end
        private_class_method :known_arguments?
      end
    end
  end
end
