# frozen_string_literal: true

require_relative "../type"

module Rigor
  module Builtins
    # Static return-type refinements for stdlib (or other built-in) methods whose upstream
    # RBS signature is broader than the method's documented behaviour and where adding a
    # `%a{rigor:v1:return: ...}` annotation upstream is impractical (the RBS lives in the
    # vendored `ruby/rbs` submodule).
    #
    # This tier sits in `MethodDispatcher.dispatch` between the HKT-builtin tier (which
    # handles parametric / shape-bearing returns like `JSON.parse`'s `json::value`) and the
    # RBS dispatch tier (the canonical lookup). It is consulted only when the method name and
    # arg shape match an entry in the table below, so the standard RBS path stays in charge
    # of every other call.
    #
    # Match policy:
    #
    # - Entries are keyed by `(owner_class_name, method_name, kind)`. `owner_class_name` is
    #   the class that *defines* the method (e.g., `"Kernel"`), not necessarily the
    #   receiver's static class — Kernel methods are mixed into every non-BasicObject class,
    #   so a `__dir__` call on any receiver routes here.
    # - `kind: :both` matches both the singleton-receiver shape (`Kernel.__dir__`,
    #   `Singleton[Kernel]` receiver) AND the instance-receiver shape (an implicit-self call
    #   like `__dir__` inside any class body, or `obj.__dir__` on an instance).
    # - `kind: :singleton` / `kind: :instance` restrict the match to one of the two shapes.
    # - The handler is called with `(arg_types, context)` so an entry can refine based on argument
    #   types (as the `IO.read` / `File.read` entries do, keying on whether a length is given).
    #   `context` is the dispatch's `MethodDispatcher::CallContext`, or nil when the caller has none;
    #   the zero-start slice entries read its receiver, call node and environment.
    #
    # The override fires ABOVE RBS dispatch — if RBS would have returned a wider type
    # (`String?` for `Kernel#__dir__`), the override returns the refined union
    # (`non-empty-string | nil`) instead. RBS erasure of the refined return goes back to the
    # original upstream shape, so downstream RBS-shaped observers see no difference.
    module StaticReturnRefinements
      # Pre-built carrier reused across calls so structural
      # equality matches across analyzer invocations.
      NON_EMPTY_STRING_OR_NIL = Type::Combinator.union(
        Type::Combinator.non_empty_string,
        Type::Combinator.constant_of(nil)
      ).freeze
      private_constant :NON_EMPTY_STRING_OR_NIL

      NON_EMPTY_STRING = Type::Combinator.non_empty_string.freeze
      private_constant :NON_EMPTY_STRING

      # `Kernel#__dir__` returns the canonical directory of the source file the call appears
      # in, or `nil` when the file is invalid / not available (typically `-e` and similar
      # one-liner contexts). When non-nil the value is always a filesystem-canonical path —
      # never the empty string — so `non-empty-string` is exact.
      KERNEL_DIR = ->(_arg_types, _context) { NON_EMPTY_STRING_OR_NIL }
      private_constant :KERNEL_DIR

      # `File.expand_path(path, ?dir_string)` always returns an absolute path string. Even
      # `File.expand_path("")` expands to the current working directory's absolute path. The
      # upstream RBS row is `(path file_name, ?path dir_string) -> String`; the refinement
      # tightens to `non-empty-string`.
      #
      # `File.dirname(path, ?level)` always returns at least `"."` (or `"/"` for absolute
      # roots), so the return is never the empty string. Upstream RBS returns `String`; the
      # refinement tightens to `non-empty-string`.
      #
      # `File.basename` is intentionally NOT refined: it returns `""` for
      # `File.basename("")`, so `non-empty-string` would be unsound.
      FILE_NON_EMPTY = ->(_arg_types, _context) { NON_EMPTY_STRING }
      private_constant :FILE_NON_EMPTY

      STRING_NOMINAL = Type::Combinator.nominal_of("String").freeze
      private_constant :STRING_NOMINAL

      # `IO.read(name)` / `File.read(name)` return nil ONLY when a `length` argument is given
      # and the stream is at EOF; the no-length form always returns a String (it raises on
      # error). Upstream RBS declares one row with an optional length — `-> String?` for every
      # call shape — so the whole-file idiom `File.read(path, mode: 'rb')` read as nilable and
      # fired `possible-nil-receiver` on working code (redmine's Import#read_file_head, three
      # sites). The refinement drops the nil exactly when no positional length is present; a
      # keyword-only trailing hash (`mode:`, `encoding:`) is not a length. Same family as the
      # staged upstream signature fixes (#159).
      IO_READ_NO_LENGTH = lambda do |arg_types, _context|
        positional = arg_types.grep_v(Type::HashShape)
        positional.size <= 1 ? STRING_NOMINAL : nil
      end
      private_constant :IO_READ_NO_LENGTH

      # Issue #3326 — `Array#[]` / `Array#slice` / `String#[]` / `String#slice` with a range declare
      # `-> Array[Elem]?` / `-> String?`, because a range whose start lies past the end answers nil
      # (`[1][5..]`). A start of `0` (or a beginless range, whose start is `0`) is never past the end,
      # so the read answers the receiver's own type: `[][0...-1]` is `[]`, `""[0..]` is `""`. The same
      # holds for the `(0, length)` form when the length is statically non-negative (`[][0, 2]` is `[]`,
      # but `[1][0, -1]` is nil). Any other start keeps the declared nilable answer.
      ZERO_START_SLICE = lambda do |arg_types, context|
        ZeroStartSlice.answer(arg_types, context)
      end
      private_constant :ZERO_START_SLICE

      # The predicate behind {ZERO_START_SLICE}. The start is read from the argument TYPE when it is a
      # `Constant` range (`0..`, a `R = (0..)` constant, `z..` with `z = 0`), and otherwise from the
      # call's own argument NODE, because a range with a non-constant end (`0..i`, `..n`) types as
      # `Range[Integer]` and has lost its start. The node is trusted only when it is the call's own
      # argument list (same selector, same arity); a `send(:[], …)` re-dispatch reads types only.
      module ZeroStartSlice
        module_function

        def answer(arg_types, context)
          receiver = context&.receiver
          class_name = receiver_class_name(receiver)
          return nil if class_name.nil?
          return nil unless zero_start?(arg_types, context.call_node, context.method_name)
          return nil if project_patched?(context.environment, class_name, context.method_name)

          non_nil_answer(receiver)
        end

        # Core `Array[E]`, `String` and a `Tuple` (which reaches this table only when `ShapeDispatch`
        # declined it, so for a range whose end is not a constant). A raw `Array` (no type argument) keeps
        # the RBS answer, whose rendering of the element differs.
        def receiver_class_name(receiver)
          case receiver
          when Type::Tuple then "Array"
          when Type::Nominal
            case receiver.class_name
            when "Array" then "Array" if receiver.type_args.size == 1
            when "String" then "String" if receiver.type_args.empty?
            end
          end
        end

        UNTYPED_ARRAY = Type::Combinator.nominal_of("Array", type_args: [Type::Combinator.untyped]).freeze

        # The declared answer without its `nil`, and nothing else changed: the receiver's own type for
        # `Array[E]` and `String`; for a tuple, the `Array[E]` RBS projects it to (`Array[1 | 2]` for
        # `[1, 2]`, `Array[untyped]` for the empty tuple, whose descriptor carries no element).
        def non_nil_answer(receiver)
          return receiver unless receiver.is_a?(Type::Tuple)
          return UNTYPED_ARRAY if receiver.elements.empty?

          Type::Combinator.nominal_of("Array", type_args: [Type::Combinator.union(*receiver.elements)])
        end

        def zero_start?(arg_types, call_node, method_name)
          case arg_types.size
          when 1
            zero_start_range_type?(arg_types.first) ||
              zero_start_range_node?(own_argument(call_node, method_name, 1))
          when 2
            zero_integer?(arg_types.first) && non_negative_integer?(arg_types.last)
          else false
          end
        end

        def zero_start_range_type?(type)
          return false unless type.is_a?(Type::Constant)

          value = type.value
          value.is_a?(Range) && zero_or_nil?(value.begin)
        end

        def zero_start_range_node?(node)
          return false unless node.is_a?(Prism::RangeNode)

          left = node.left
          left.nil? || (left.is_a?(Prism::IntegerNode) && left.value.zero?)
        end

        # The call node's only positional argument, when the dispatch is that node's own call: same
        # selector and the same argument count. Anything else (a `send` re-dispatch, a splat, a node
        # that is not a call) answers nil.
        def own_argument(call_node, method_name, arity)
          return nil unless call_node.is_a?(Prism::CallNode) && call_node.name == method_name

          arguments = call_node.arguments&.arguments
          return nil if arguments.nil? || arguments.size != arity

          arguments.first
        end

        def zero_or_nil?(value)
          value.nil? || (value.is_a?(Integer) && value.zero?)
        end

        def zero_integer?(type)
          type.is_a?(Type::Constant) && type.value.is_a?(Integer) && type.value.zero?
        end

        def non_negative_integer?(type)
          case type
          when Type::Constant then type.value.is_a?(Integer) && !type.value.negative?
          when Type::IntegerRange then type.min.is_a?(Integer) && !type.min.negative?
          else false
          end
        end

        # A `pre_eval:` reopening of `Array` / `String` that redefines the read means the method that
        # runs is not core's, so the core guarantee does not hold (ADR-17).
        def project_patched?(environment, class_name, method_name)
          patched = environment&.project_patched_methods
          return false if patched.nil? || patched.empty?

          !patched.lookup(class_name: class_name, method_name: method_name, kind: :instance).nil?
        end
      end
      private_constant :ZeroStartSlice

      # Frozen ((owner_class_name, method_name, kind) => handler) table. The kind tag is
      # `:both`, `:singleton`, or `:instance`. New entries SHOULD prefer `:both` unless the
      # singleton- and instance-side shapes genuinely differ.
      OVERRIDES = {
        ["Kernel", :__dir__, :both] => KERNEL_DIR,
        ["File", :expand_path, :singleton] => FILE_NON_EMPTY,
        ["File", :dirname, :singleton] => FILE_NON_EMPTY,
        ["IO", :read, :singleton] => IO_READ_NO_LENGTH,
        ["File", :read, :singleton] => IO_READ_NO_LENGTH,
        ["Array", :[], :instance] => ZERO_START_SLICE,
        ["Array", :slice, :instance] => ZERO_START_SLICE,
        ["String", :[], :instance] => ZERO_START_SLICE,
        ["String", :slice, :instance] => ZERO_START_SLICE
      }.freeze
      Ractor.make_shareable(OVERRIDES)
      private_constant :OVERRIDES

      # Looks up a refined return type for the given call.
      #
      # @param owner_class_name — the class on which the method is defined
      #   (e.g., `"Kernel"`). A `nil` owner (the caller has not resolved one) returns `nil`; the
      #   dispatcher resolves candidates through {owners_for} first.
      # @param kind — one of `:singleton`, `:instance`. The caller passes the shape of
      #   the actual call site; the table stores `:both` for entries that match either.
      # @param arg_types — positional argument types. Forwarded to the
      #   handler so an entry can discriminate on argument shape.
      # @param context — the dispatch's `CallContext`, forwarded to the handler; nil when absent.
      # @return the refined return type, or `nil` when no override
      #   matches.
      def self.lookup(owner_class_name:, method_name:, kind:, arg_types: [], context: nil)
        return nil if owner_class_name.nil?

        method_sym = method_name.to_sym
        handler = OVERRIDES[[owner_class_name, method_sym, :both]] ||
                  OVERRIDES[[owner_class_name, method_sym, kind]]
        handler&.call(arg_types, context)
      end

      # Indexed view by `(method_name, kind)` — used by the dispatcher when the receiver's
      # owner is not yet resolved but the method name alone uniquely identifies a stdlib
      # override (e.g. `__dir__` → Kernel). The table is small and the index rebuild cost
      # trivial, but precomputing keeps `dispatch`'s hot path free of an O(n) scan.
      OWNERS_BY_METHOD = OVERRIDES.each_with_object({}) do |((owner, mname, _kind), _h), acc|
        acc[mname] ||= []
        acc[mname] << owner unless acc[mname].include?(owner)
      end.freeze
      Ractor.make_shareable(OWNERS_BY_METHOD)
      private_constant :OWNERS_BY_METHOD

      # The miss result of {owners_for}: the miss case is overwhelmingly common, so share one
      # frozen empty array instead of allocating a fresh `[]` per non-refined method.
      NO_OWNERS = [].freeze
      private_constant :NO_OWNERS

      # @return the candidate owner class names for a bare method-name
      #   lookup. Empty when no override names this method. Consulted on every dispatch
      #   (`try_static_refinement`).
      def self.owners_for(method_name)
        OWNERS_BY_METHOD[method_name.to_sym] || NO_OWNERS
      end
    end
  end
end
