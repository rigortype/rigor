# frozen_string_literal: true

require "rbs"

require_relative "../type"

module Rigor
  module Inference
    # Translates `RBS::Types::*` instances into `Rigor::Type` values.
    #
    # Generic plumbing:
    # - `RBS::Types::ClassInstance` arguments are translated recursively so `Array[Integer]` becomes
    #   `Nominal["Array", [Nominal["Integer"]]]` (and `Hash[Symbol, Integer]` becomes
    #   `Nominal["Hash", [...]]`).
    # - `RBS::Types::Variable` consults a caller-supplied substitution map (`type_vars:`) keyed by the
    #   variable's RBS name. When the variable is bound, the bound `Rigor::Type` is returned unchanged;
    #   when it is not bound, the variable degrades to `Dynamic[Top]` so uninstantiated generics keep
    #   their fail-soft behavior.
    #
    # Shape carriers:
    # - `RBS::Types::Tuple` becomes `Rigor::Type::Tuple[...]` so the arity and per-position element
    #   types survive the boundary.
    # - `RBS::Types::Record` becomes an exact closed `Rigor::Type::HashShape{...}`, carrying required
    #   and optional fields intact.
    # Element and value types are translated recursively under the caller's `self_type` /
    # `instance_type` / `type_vars` context.
    #
    # Alias and intersection types (#529):
    # - `RBS::Types::Alias` resolves through the caller-supplied `alias_expander:` (an object answering
    #   `expand_type_alias`, in practice the environment's `RbsLoader`) and the expansion is translated
    #   in the same context. Without an expander — or past the expansion budget that bounds recursive
    #   aliases like `type json = ... | Array[json]` — the alias degrades to `Dynamic[Top]` as before.
    # - `RBS::Types::Intersection` translates to its first member that carries static evidence. Every
    #   value of `A & B` IS an `A`, so any single member is a sound superset read; taking the first
    #   informative one turns prism's `type node = Node & _Node` into `Nominal[Prism::Node]` instead of
    #   `untyped`. `Type::Intersection` stays out of this path: it is the same-base refinement composite
    #   carrier, and the dispatch tiers do not accept it as a receiver.
    #
    # Interface types still degrade to `Dynamic[Top]`; they are bound to acceptance and dispatch rules
    # not yet implemented.
    #
    # The optional `self_type:` and `instance_type:` arguments are the Rigor counterparts of RBS's
    # `self` and `instance` tokens:
    # - `self_type` substitutes for `Bases::Self`. Inside an instance method body it is `Nominal[C]`;
    #   inside a singleton method body it is `Singleton[C]`.
    # - `instance_type` substitutes for `Bases::Instance` and is always `Nominal[C]` regardless of which
    #   method body we are in.
    # When either argument is omitted, the corresponding token degrades to Dynamic[Top].
    module RbsTypeTranslator
      # Hash-based dispatch keeps `translate` linear and dodges the bookkeeping costs of a 20-arm `case`
      # (RuboCop AbcSize/CCN/Length all spike on that shape). Anonymous RBS-type subclasses are not
      # expected; the table only maps the concrete leaf classes shipped by the `rbs` gem.
      TRANSLATORS = {
        RBS::Types::Bases::Top => :translate_top,
        RBS::Types::Bases::Bottom => :translate_bot,
        RBS::Types::Bases::Any => :translate_untyped,
        RBS::Types::Bases::Nil => :translate_nil,
        RBS::Types::Bases::Bool => :translate_bool,
        RBS::Types::Bases::Self => :translate_self,
        RBS::Types::Bases::Instance => :translate_instance,
        RBS::Types::Bases::Class => :translate_untyped,
        # `void` is the top type, not `untyped`: RBS defines the two as the same type ("They are all
        # equivalent for the type system; they are all *top type*" — rbs `docs/syntax.md`), with `void`
        # carrying only a hint that the value should not be used. Mapping it to `untyped` made Rigor looser
        # than the toolchain it reads — `Dynamic[top]` is consistent with everything at a gradual boundary,
        # where `top` demands proof — so a caller could silently depend on a return whose author declared
        # "don't rely on this". See ADR-92 WD2; `special-types.md` § `void` (a distinct carrier + a value-use
        # diagnostic) remains unimplemented and marked.
        RBS::Types::Bases::Void => :translate_top,
        RBS::Types::Optional => :translate_optional,
        RBS::Types::Union => :translate_union,
        RBS::Types::Literal => :translate_literal,
        RBS::Types::ClassInstance => :translate_class_instance,
        RBS::Types::Tuple => :translate_tuple,
        RBS::Types::Record => :translate_record,
        RBS::Types::Proc => :translate_proc_nominal,
        RBS::Types::ClassSingleton => :translate_class_singleton,
        RBS::Types::Alias => :translate_alias,
        RBS::Types::Intersection => :translate_intersection,
        RBS::Types::Variable => :translate_variable,
        RBS::Types::Interface => :translate_untyped
      }.freeze
      private_constant :TRANSLATORS

      EMPTY_TYPE_VARS = {}.freeze
      private_constant :EMPTY_TYPE_VARS

      # The immutable translation context threaded through every handler. `alias_depth` counts alias
      # expansions performed on the current walk, so a recursive alias terminates instead of looping.
      Context = Struct.new(:self_type, :instance_type, :type_vars, :alias_expander, :alias_depth) do
        def deeper
          self.class.new(self_type, instance_type, type_vars, alias_expander, alias_depth + 1)
        end
      end
      private_constant :Context

      # Eight expansions cover any observed nesting (gem sigs rarely go past aliases-of-aliases) while
      # bounding the `type json = ... | Array[json]` family: the ninth nested expansion degrades to
      # `Dynamic[Top]`, which is exactly what every alias read before #529.
      ALIAS_EXPANSION_LIMIT = 8
      private_constant :ALIAS_EXPANSION_LIMIT

      class << self
        # @param rbs_type [RBS::Types::Bases::Base, RBS::Types::ClassInstance, ...]
        # @param self_type [Rigor::Type, nil] substitute for `Bases::Self`.
        # @param instance_type [Rigor::Type, nil] substitute for `Bases::Instance`. Defaults to `nil`,
        #   which degrades to Dynamic[Top].
        # @param type_vars [Hash{Symbol => Rigor::Type}] substitution map for `Bases::Variable`. Keys
        #   are the RBS variable names (e.g., `:Elem`); values are Rigor types that replace the
        #   variable. Variables that are not bound in the map degrade to Dynamic[Top].
        # @param alias_expander [#expand_type_alias, nil] resolves `RBS::Types::Alias` one level out —
        #   in practice the environment's `RbsLoader`. When nil, aliases degrade to Dynamic[Top].
        # @return [Rigor::Type]
        def translate(rbs_type, self_type: nil, instance_type: nil, type_vars: EMPTY_TYPE_VARS,
                      alias_expander: nil)
          translate_in(rbs_type, Context.new(self_type, instance_type, type_vars, alias_expander, 0))
        end

        private

        def translate_in(rbs_type, context)
          handler = TRANSLATORS[rbs_type.class]
          return send(handler, rbs_type, context) if handler

          Type::Combinator.untyped
        end

        def translate_top(_rbs_type, _context)
          Type::Combinator.top
        end

        def translate_bot(_rbs_type, _context)
          Type::Combinator.bot
        end

        def translate_untyped(_rbs_type, _context)
          Type::Combinator.untyped
        end

        def translate_nil(_rbs_type, _context)
          Type::Combinator.constant_of(nil)
        end

        # `bool` in RBS denotes `true | false`. We fold it to that union eagerly so downstream
        # comparisons (e.g., `result == Constant[true]`) remain structural. Memoized at the module
        # level because the union is value-equal across calls.
        def translate_bool(_rbs_type, _context)
          BOOL_UNION
        end

        BOOL_UNION = Type::Combinator.union(
          Type::Combinator.constant_of(true),
          Type::Combinator.constant_of(false)
        ).freeze
        private_constant :BOOL_UNION

        def translate_self(_rbs_type, context)
          context.self_type || Type::Combinator.untyped
        end

        def translate_instance(_rbs_type, context)
          context.instance_type || Type::Combinator.untyped
        end

        def translate_optional(rbs_type, context)
          inner = translate_in(rbs_type.type, context)
          Type::Combinator.union(inner, Type::Combinator.constant_of(nil))
        end

        def translate_union(rbs_type, context)
          members = rbs_type.types.map { |t| translate_in(t, context) }
          Type::Combinator.union(*members)
        end

        def translate_literal(rbs_type, _context)
          Type::Combinator.constant_of(rbs_type.literal)
        end

        # Translates the type arguments recursively so `Array[Integer]` round-trips into
        # `Nominal["Array", [Nominal["Integer"]]]`. Variables inside the args participate in
        # substitution through the same `type_vars:` map.
        def translate_class_instance(rbs_type, context)
          name = rbs_type.name.relative!.to_s
          translated_args = rbs_type.args.map { |arg| translate_in(arg, context) }
          Type::Combinator.nominal_of(name, type_args: translated_args)
        end

        # Preserves tuple precision through the boundary. Each positional element type is translated
        # recursively under the caller's substitution context, and the resulting list is wrapped in a
        # `Rigor::Type::Tuple`.
        def translate_tuple(rbs_type, context)
          elements = rbs_type.types.map { |t| translate_in(t, context) }
          Type::Combinator.tuple_of(*elements)
        end

        # Preserves hash-record precision through the boundary. RBS records use Symbol keys; the
        # translator keeps them as Symbol keys on the resulting exact closed HashShape so erasure can
        # round-trip back to `{ a: T, ?b: U }` syntax.
        def translate_record(rbs_type, context)
          pairs = rbs_type.fields.each_with_object({}) do |(key, value), acc|
            acc[key] = translate_in(value, context)
          end
          optional_pairs = rbs_type.optional_fields.each_with_object({}) do |(key, value), acc|
            acc[key] = translate_in(value, context)
          end
          Type::Combinator.hash_shape_of(
            pairs.merge(optional_pairs),
            required_keys: pairs.keys,
            optional_keys: optional_pairs.keys,
            extra_keys: :closed
          )
        end

        def translate_proc_nominal(_rbs_type, _context)
          Type::Combinator.nominal_of(Proc)
        end

        # `singleton(Foo)` is the type of the constant `Foo` itself (the class object). With the
        # dedicated Singleton type, we map directly to `Singleton[Foo]`.
        def translate_class_singleton(rbs_type, _context)
          name = rbs_type.name.relative!.to_s
          Type::Combinator.singleton_of(name)
        end

        # #529 — sees through a type alias instead of reading `untyped`. `expand_type_alias` resolves
        # one level (with the alias's own type params substituted, so generic aliases work); nested
        # aliases in the expansion recurse back through here with the depth budget decremented. Every
        # decline arm returns exactly what the alias translated to before this handler existed.
        def translate_alias(rbs_type, context)
          expander = context.alias_expander
          return Type::Combinator.untyped if expander.nil? || context.alias_depth >= ALIAS_EXPANSION_LIMIT

          expanded = expander.expand_type_alias(rbs_type)
          return Type::Combinator.untyped if expanded.nil?

          translate_in(expanded, context.deeper)
        end

        # #529 — `A & B` reads as its first member that carries static evidence. Every value of the
        # intersection IS a value of each member, so any single member is a sound superset read; the
        # skip list drops members that add nothing (an interface's `Dynamic[Top]`, `top` itself) so
        # `Node & _Node` lands on `Nominal[Prism::Node]`. No informative member — the pre-#529 read.
        def translate_intersection(rbs_type, context)
          members = rbs_type.types.map { |t| translate_in(t, context) }
          members.find { |m| !m.is_a?(Type::Dynamic) && !m.is_a?(Type::Top) } || Type::Combinator.untyped
        end

        # Looks up the variable's RBS name in the substitution map; bound variables are replaced
        # inline, free variables degrade to Dynamic[Top]. We use `fetch` with a default rather than
        # `[]` so a deliberate `nil` binding (a caller mistake) is never silently consumed.
        def translate_variable(rbs_type, context)
          context.type_vars.fetch(rbs_type.name) { Type::Combinator.untyped }
        end
      end
    end
  end
end
