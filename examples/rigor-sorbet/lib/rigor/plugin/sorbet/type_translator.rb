# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class Sorbet < Rigor::Plugin::Base
      # Maps Sorbet's type expressions (the AST inside a `sig`
      # block's `params(...)` and `returns(...)` clauses) into
      # Rigor's internal type carriers.
      #
      # Slice 1 covered the minimum vocabulary that lets a
      # typical `sig { params(x: Integer).returns(String) }`
      # round-trip; slice 3 widens it to cover the dense middle
      # of Sorbet's surface — generic class applications
      # (`T::Array[E]`, `T::Hash[K, V]`, etc.), class-object
      # types (`T.class_of(C)`, `T::Class[T]`), tuples, and
      # shapes:
      #
      # | Sorbet form              | Rigor carrier                            |
      # | ------------------------ | ---------------------------------------- |
      # | `Integer` etc.           | `Nominal["Integer"]`                     |
      # | `::Foo::Bar`             | `Nominal["Foo::Bar"]`                    |
      # | `T.untyped`              | `Dynamic[top]`                           |
      # | `T.anything`             | `top`                                    |
      # | `T.noreturn`             | `bot`                                    |
      # | `T.nilable(X)`           | `Union[X, Constant[nil]]`                |
      # | `T.any(A, B, ...)`       | `Union[A, B, ...]`                       |
      # | `T.all(A, B, ...)`       | `Intersection[A, B, ...]`                |
      # | `T::Boolean`             | `Union[Constant[true], Constant[false]]` |
      # | `T::Array[E]`            | `Nominal["Array", [E]]`                  |
      # | `T::Hash[K, V]`          | `Nominal["Hash", [K, V]]`                |
      # | `T::Set[E]`              | `Nominal["Set", [E]]`                    |
      # | `T::Range[E]`            | `Nominal["Range", [E]]`                  |
      # | `T::Enumerable[E]`       | `Nominal["Enumerable", [E]]`             |
      # | `T::Enumerator[E]`       | `Nominal["Enumerator", [E]]`             |
      # | `T::Class[T]`            | `Singleton[T-class-name]` (lossy)        |
      # | `T.class_of(C)`          | `Singleton[C]`                           |
      # | `[A, B]` (tuple in sig)  | `Tuple[A, B]`                            |
      # | `{a: A, b: B}` (shape)   | `HashShape{a: A, b: B}` (closed)         |
      #
      # Anything else (`T.proc`, `T.attached_class`,
      # `T.self_type`, `T.type_parameter`, `T::Struct` / `T::Enum`
      # subclasses, …) degrades to `Dynamic[top]`. The degraded
      # path stays silent for now per ADR-11's slice plan; a
      # later slice surfaces the gap as a `dynamic.sorbet.unsupported`
      # diagnostic.
      module TypeTranslator
        BOOLEAN_NAME = "Boolean"

        # `T::*` constants whose `[]` application maps directly
        # onto a Rigor `Nominal` with the matching standard-
        # library class name. Ordering matches the table above
        # for ease of reading.
        T_GENERIC_CLASSES = {
          "Array" => "Array",
          "Hash" => "Hash",
          "Set" => "Set",
          "Range" => "Range",
          "Enumerable" => "Enumerable",
          "Enumerator" => "Enumerator",
          "Enumerator::Lazy" => "Enumerator::Lazy",
          "Enumerator::Chain" => "Enumerator::Chain"
        }.freeze

        module_function

        # @param node [Prism::Node, nil]
        # @return [Rigor::Type] never `nil`; unrecognised forms
        #   degrade to `Type::Combinator.untyped`.
        def translate(node)
          return Rigor::Type::Combinator.untyped if node.nil?

          case node
          when Prism::ConstantReadNode then translate_constant_read(node)
          when Prism::ConstantPathNode then translate_constant_path(node)
          when Prism::CallNode then translate_call(node)
          when Prism::ArrayNode then translate_tuple(node)
          when Prism::HashNode then translate_shape(node)
          else degraded
          end
        end

        # @param node [Prism::ConstantReadNode]
        def translate_constant_read(node)
          name = node.name.to_s
          return Rigor::Type::Combinator.untyped if name.empty?

          Rigor::Type::Combinator.nominal_of(name)
        end

        # @param node [Prism::ConstantPathNode]
        def translate_constant_path(node)
          name = constant_path_name(node)
          return degraded if name.nil?

          # Sorbet's `T::Boolean` is a special alias rather than a
          # nominal class, expressed as the Boolean type alias.
          return boolean_type if name == "T::Boolean"

          Rigor::Type::Combinator.nominal_of(name)
        end

        # `Prism::CallNode` covers two distinct surfaces:
        #
        # 1. `T.something(...)` — `untyped` / `anything` /
        #    `noreturn` / `nilable` / `any` / `all` / `class_of`.
        # 2. `T::SomeClass[...]` — the `[]` method on a generic
        #    `T::*` constant (slice 3 widening). Maps to
        #    `Nominal[name, type_args]`.
        def translate_call(node)
          return translate_t_method(node) if sorbet_t_namespaced?(node.receiver)
          return translate_t_subscript(node) if sorbet_subscript?(node)

          degraded
        end

        # Handles the `T.foo(...)` family.
        def translate_t_method(node)
          case node.name
          when :untyped then Rigor::Type::Combinator.untyped
          when :anything then Rigor::Type::Combinator.top
          when :noreturn then Rigor::Type::Combinator.bot
          when :nilable then translate_nilable(node)
          when :any then translate_any(node)
          when :all then translate_all(node)
          when :class_of then translate_class_of(node)
          else degraded
          end
        end

        def translate_nilable(node)
          inner = first_argument(node)
          return degraded if inner.nil?

          Rigor::Type::Combinator.union(
            translate(inner), Rigor::Type::Combinator.constant_of(nil)
          )
        end

        def translate_any(node)
          args = call_arguments(node)
          return degraded if args.empty?

          Rigor::Type::Combinator.union(*args.map { |arg| translate(arg) })
        end

        def translate_all(node)
          args = call_arguments(node)
          return degraded if args.empty?

          Rigor::Type::Combinator.intersection(*args.map { |arg| translate(arg) })
        end

        # `T.class_of(C)` — singleton-class type for a single
        # constant. Sorbet docs note `T.class_of(MyInterface)`
        # rarely means what users expect (it's the singleton
        # class of `MyInterface`, not "any class implementing
        # the interface"); we honour the literal meaning here
        # and translate to `Singleton[C]`.
        def translate_class_of(node)
          target = first_argument(node)
          name = constant_path_name(target)
          return degraded if name.nil?

          Rigor::Type::Combinator.singleton_of(name)
        end

        # Handles `T::Array[E]`, `T::Hash[K, V]`, etc. The Prism
        # AST for `T::Array[Integer]` is a `CallNode` whose
        # receiver is the `T::Array` `ConstantPathNode` and
        # whose `name` is `:[]`. `T::Class[T]` lands here too;
        # we collapse it to `Singleton[name]` (a deliberate
        # narrowing — `T::Class` is structurally generic in
        # Sorbet, but Rigor's `Singleton` carries class identity
        # only).
        def translate_t_subscript(node)
          base_name = sorbet_subscript_base(node.receiver)
          args = call_arguments(node).map { |arg| translate(arg) }
          mapped = T_GENERIC_CLASSES[base_name]

          if mapped
            Rigor::Type::Combinator.nominal_of(mapped, type_args: args)
          elsif base_name == "Class"
            translate_t_class_subscript(args)
          else
            degraded
          end
        end

        # `T::Class[T]` — Sorbet's "any class object whose
        # instances are at least `T`". Rigor has no exact
        # analogue (Singleton names a specific class); the
        # closest faithful translation is `Singleton[name]`
        # when `T` is a constant, or `Singleton[Object]` for
        # broader applications. Lossy translation; emitted as
        # `dynamic.sorbet.degraded` once slice 3's diagnostic
        # surface lands.
        def translate_t_class_subscript(args)
          inner = args.first
          return Rigor::Type::Combinator.singleton_of("Class") if inner.nil?

          case inner
          when Rigor::Type::Nominal then Rigor::Type::Combinator.singleton_of(inner.class_name)
          else Rigor::Type::Combinator.singleton_of("Class")
          end
        end

        # Tuple types in `sig` position appear as bare array
        # literals: `sig { returns([String, Integer]) }`. Each
        # element is itself a type expression we translate
        # recursively.
        def translate_tuple(node)
          elements = node.elements.map { |element| translate(element) }
          Rigor::Type::Combinator.tuple_of(*elements)
        end

        # Shape types in `sig` position appear as bare hash
        # literals with symbol keys:
        # `sig { returns({a: Integer, b: String}) }`. Each
        # value is a type expression; the resulting `HashShape`
        # is closed (no extra keys allowed).
        def translate_shape(node)
          pairs = []
          node.elements.each do |element|
            next unless element.is_a?(Prism::AssocNode)
            next unless element.key.is_a?(Prism::SymbolNode)

            pairs << [element.key.unescaped.to_sym, translate(element.value)]
          end
          Rigor::Type::Combinator.hash_shape_of(pairs)
        end

        # Renders a constant-path node (`Foo::Bar`, `::Foo::Bar`)
        # as a `::`-joined String. Mirrors the helper used by
        # rigor-activerecord's ModelDiscoverer for parity.
        def constant_path_name(node)
          return nil if node.nil?

          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode then constant_path_name_for_path(node)
          end
        end

        def constant_path_name_for_path(node)
          parts = []
          current = node
          while current.is_a?(Prism::ConstantPathNode)
            parts.unshift(current.name.to_s)
            current = current.parent
          end
          case current
          when nil
            "::#{parts.join('::')}"
          when Prism::ConstantReadNode
            "#{current.name}::#{parts.join('::')}"
          end
        end

        def sorbet_t_namespaced?(receiver)
          receiver.is_a?(Prism::ConstantReadNode) && receiver.name == :T
        end

        # `T::Array[Integer]` parses as `CallNode(receiver: T::Array, name: :[])`.
        # The receiver is a `ConstantPathNode` rooted at the
        # `T` constant.
        def sorbet_subscript?(node)
          node.name == :[] && sorbet_t_qualified?(node.receiver)
        end

        def sorbet_t_qualified?(node)
          return false unless node.is_a?(Prism::ConstantPathNode)

          # Walk to the root; require that it terminates at a
          # `T` ConstantReadNode (not an absolute `::T`).
          current = node
          current = current.parent while current.is_a?(Prism::ConstantPathNode)
          current.is_a?(Prism::ConstantReadNode) && current.name == :T
        end

        # Strips the leading `T::` from a `T::Foo::Bar`
        # constant-path node, returning `"Foo::Bar"`. Returns
        # nil for shapes that aren't `T`-rooted.
        def sorbet_subscript_base(node)
          return nil unless sorbet_t_qualified?(node)

          parts = []
          current = node
          while current.is_a?(Prism::ConstantPathNode)
            parts.unshift(current.name.to_s)
            current = current.parent
          end
          parts.join("::")
        end

        def first_argument(node)
          node.arguments&.arguments&.first
        end

        def call_arguments(node)
          node.arguments&.arguments || []
        end

        def degraded
          Rigor::Type::Combinator.untyped
        end

        # `T::Boolean` corresponds to the union of the singleton
        # `true` / `false` values, matching how RBS's `bool`
        # would translate. Built from `Constant[true]` /
        # `Constant[false]` so the analyzer's flow-sensitive
        # narrowing recognises the discriminating shape.
        def boolean_type
          Rigor::Type::Combinator.union(
            Rigor::Type::Combinator.constant_of(true),
            Rigor::Type::Combinator.constant_of(false)
          )
        end
      end
    end
  end
end
