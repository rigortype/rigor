# frozen_string_literal: true

require_relative "../type"

module Rigor
  module Builtins
    # Static return-type refinements for stdlib (or other built-in)
    # methods whose upstream RBS signature is broader than the
    # method's documented behaviour and where adding a
    # `%a{rigor:v1:return: ...}` annotation upstream is impractical
    # (the RBS lives in the vendored `ruby/rbs` submodule).
    #
    # This tier sits in `MethodDispatcher.dispatch` between the
    # HKT-builtin tier (which handles parametric / shape-bearing
    # returns like `JSON.parse`'s `json::value`) and the RBS
    # dispatch tier (the canonical lookup). It is consulted only
    # when the method name and arg shape match an entry in the
    # table below, so the standard RBS path stays in charge of
    # every other call.
    #
    # Match policy:
    #
    # - Entries are keyed by `(owner_class_name, method_name,
    #   kind)`. `owner_class_name` is the class that *defines*
    #   the method (e.g., `"Kernel"`), not necessarily the
    #   receiver's static class — Kernel methods are mixed into
    #   every non-BasicObject class, so a `__dir__` call on any
    #   receiver routes here.
    # - `kind: :both` matches both the singleton-receiver
    #   shape (`Kernel.__dir__`, `Singleton[Kernel]` receiver)
    #   AND the instance-receiver shape (an implicit-self call
    #   like `__dir__` inside any class body, or `obj.__dir__`
    #   on an instance).
    # - `kind: :singleton` / `kind: :instance` restrict the
    #   match to one of the two shapes.
    # - The handler is called with `(arg_types)` so future
    #   entries can refine based on argument types (e.g. a
    #   `File.expand_path(string)` entry that returns
    #   `non-empty-string` regardless of the upstream return).
    #
    # The override fires ABOVE RBS dispatch — if RBS would have
    # returned a wider type (`String?` for `Kernel#__dir__`), the
    # override returns the refined union (`non-empty-string | nil`)
    # instead. RBS erasure of the refined return goes back to the
    # original upstream shape, so downstream RBS-shaped observers
    # see no difference.
    module StaticReturnRefinements
      # Pre-built carrier reused across calls so structural
      # equality matches across analyzer invocations.
      NON_EMPTY_STRING_OR_NIL = Type::Combinator.union(
        Type::Combinator.non_empty_string,
        Type::Combinator.constant_of(nil)
      ).freeze
      private_constant :NON_EMPTY_STRING_OR_NIL

      # `Kernel#__dir__` returns the canonical directory of the
      # source file the call appears in, or `nil` when the file
      # is invalid / not available (typically `-e` and similar
      # one-liner contexts). When non-nil the value is always a
      # filesystem-canonical path — never the empty string — so
      # `non-empty-string` is exact.
      KERNEL_DIR = ->(_arg_types) { NON_EMPTY_STRING_OR_NIL }
      private_constant :KERNEL_DIR

      # Frozen ((owner_class_name, method_name, kind) => handler)
      # table. The kind tag is `:both`, `:singleton`, or
      # `:instance`. New entries SHOULD prefer `:both` unless the
      # singleton- and instance-side shapes genuinely differ.
      OVERRIDES = {
        ["Kernel", :__dir__, :both] => KERNEL_DIR
      }.freeze
      private_constant :OVERRIDES

      # Looks up a refined return type for the given call.
      #
      # @param owner_class_name [String, nil] the class on which
      #   the method is defined (e.g., `"Kernel"`). Pass `nil`
      #   when the caller hasn't resolved a defining owner yet —
      #   the lookup will then fall back to matching by
      #   `(method_name, kind)` against entries whose owner is
      #   currently in the table.
      # @param method_name [Symbol]
      # @param kind [Symbol] one of `:singleton`, `:instance`. The
      #   caller passes the shape of the actual call site; the
      #   table stores `:both` for entries that match either.
      # @param arg_types [Array<Rigor::Type>] positional argument
      #   types. Forwarded to the handler so future entries can
      #   discriminate on argument shape.
      # @return [Rigor::Type, nil] the refined return type, or
      #   `nil` when no override matches.
      def self.lookup(owner_class_name:, method_name:, kind:, arg_types: [])
        return nil if owner_class_name.nil?

        method_sym = method_name.to_sym
        handler = OVERRIDES[[owner_class_name, method_sym, :both]] ||
                  OVERRIDES[[owner_class_name, method_sym, kind]]
        handler&.call(arg_types)
      end

      # Indexed view by `(method_name, kind)` — used by the
      # dispatcher when the receiver's owner is not yet resolved
      # but the method name alone uniquely identifies a stdlib
      # override (today: `__dir__` → Kernel). The table is small
      # and the index rebuild cost trivial, but precomputing keeps
      # `dispatch`'s hot path free of an O(n) scan.
      OWNERS_BY_METHOD = OVERRIDES.each_with_object({}) do |((owner, mname, _kind), _h), acc|
        acc[mname] ||= []
        acc[mname] << owner unless acc[mname].include?(owner)
      end.freeze
      private_constant :OWNERS_BY_METHOD

      # @return [Array<String>] the candidate owner class names
      #   for a bare method-name lookup. Empty when no override
      #   names this method.
      def self.owners_for(method_name)
        OWNERS_BY_METHOD[method_name.to_sym] || []
      end
    end
  end
end
