# frozen_string_literal: true

require "prism"

module Rigor
  module Inference
    module MatchRebinding
      # Whether a call a statement runs rebinds the `$~` of the frame it is made in by what it calls, on any receiver
      # (issue #1365). Outside a block the flow scope types the call's operands, so a lookup is read by its
      # arguments' types ({Operands.typed_regexp?}) rather than by its name: `row[:name]`, `csv.split(",")` and
      # `list.index(3)` leave `$~` alone in Ruby, and forgetting on them reported correct code. The block scan reads
      # the same names on narrower, syntactic terms ({MatchRebinding.may_match?}).
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
        EMPTY = [].freeze
        private_constant :ALWAYS_MATCHING, :LOOKUPS, :BLOCK_FORM_LOOKUPS, :RECEIVER_PATTERNS, :EVALS, :SENDS,
                         :NAMES_BY_STRING, :EMPTY

        module_function

        # True when `node`, a call, rebinds the `$~` of the frame it is made in by the method it calls: an
        # {ALWAYS_MATCHING} name; a {LOOKUPS} name with an argument that may be a Regexp, and `grep` / `grep_v` on
        # the same terms in their block form; `[]=` with an index that may be one (`s[re] = v`); `===` or unary `~`
        # on a receiver that may be one; an eval of a String ({EVALS} with an argument); or a {SENDS} call whose
        # name is not a literal, or names one of these with the arguments it is sent. `match?` never counts. An
        # operand of type `Dynamic[top]` may be a Regexp, so `row[key]` with an unannotated `key` still counts, and
        # so does `===` on an unresolved constant. `node` may also be an index `||=` / `&&=` / `op=` write, which
        # runs `[]` and perhaps `[]=` with its index (`s[re] ||= v`). `scope` types the operands.
        def rebinds?(node, scope)
          arguments = node.arguments&.arguments || EMPTY
          return regexp_argument?(arguments, scope) unless node.is_a?(Prism::CallNode)

          named?(node.name, node.receiver, arguments, !node.block.nil?, scope)
        end

        def named?(name, receiver, arguments, block, scope)
          return true if ALWAYS_MATCHING.include?(name)
          return receiver_pattern?(receiver, scope) if RECEIVER_PATTERNS.include?(name)
          return false if arguments.empty?
          return true if EVALS.include?(name)
          return sent?(receiver, arguments, block, scope) if SENDS.include?(name)
          return regexp_argument?(arguments[0...-1], scope) if name == :[]=
          return block && regexp_argument?(arguments, scope) if BLOCK_FORM_LOOKUPS.include?(name)

          LOOKUPS.include?(name) && regexp_argument?(arguments, scope)
        end
        private_class_method :named?

        # A computed name may be any of them. `send()` with no name raises before it runs anything.
        def sent?(receiver, arguments, block, scope)
          name_node, *rest = arguments
          return true unless name_node.is_a?(Prism::SymbolNode) || name_node.is_a?(Prism::StringNode)

          name = NAMES_BY_STRING[name_node.unescaped]
          !name.nil? && named?(name, receiver, rest, block, scope)
        end
        private_class_method :sent?

        # An implicit receiver (`===(s)` in a Regexp subclass) counts, as in the block scan; `self` is typed.
        def receiver_pattern?(receiver, scope)
          return true if receiver.nil?

          Operands.typed_regexp?(receiver, scope)
        end
        private_class_method :receiver_pattern?

        def regexp_argument?(arguments, scope)
          arguments.any? { |argument| Operands.typed_regexp?(argument, scope) }
        end
        private_class_method :regexp_argument?
      end
    end
  end
end
