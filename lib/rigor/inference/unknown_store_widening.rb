# frozen_string_literal: true

require "prism"

require_relative "../type"
require_relative "element_read_widening"
require_relative "mutation_widening"

module Rigor
  module Inference
    # What a binding can hold after each of a set of in-place mutation sites — the nodes
    # {CapturedLocals.content_mutations} collects — has run any number of times, storing values nothing typed.
    #
    # Each site takes its own straight-line widening ({MutationWidening.widen_for_mutator}), fed one
    # `Dynamic[top]` per argument, and every site that can STORE a value then gives each type argument of the
    # widened `Array` / `Hash` a `Dynamic[top]` arm: `{ a: 0 }` under `h[k] += 1` reads
    # `Hash[Dynamic[top] | Symbol, Dynamic[top] | Integer]`. The second step is not redundant. The widening
    # joins argument evidence only for the plain adders (`<<`, `push`, `[]=`, `store`, …); a site whose stored
    # values its arguments do not describe — `map!`, a block-form `fill`, `transform_values!`, `merge!`,
    # `flatten!` — comes back with the seed's element types alone, which is a wrong precise answer once the
    # block has run: `a = [1]` under `a.map!(&:to_s)` would read `Array[Integer]`. Only a site that removes or
    # reorders ({VALUE_PRESERVING}) keeps its content as the widening left it, since it cannot put a value
    # there that was not there before — unless it is the site that CLOSES a literal carrier. A `Tuple` or
    # `HashShape` knows which slots and keys exist, and the nominal it widens to cannot say that any may be
    # missing, so it takes the gradual arm too: `{ a: 0 }` under a lone `h.delete(:a)` read `Hash[Symbol, 0]`,
    # whose `h[:b]` answered `0` where Ruby answers `nil`, and `s = [0]` under `p = s.pop; s.push(x)` closed to
    # `Array[0]`, a precise nominal the `push` after it then declined, so `p` stayed `0?`. With the arm the
    # answer for a `Tuple` / `HashShape` seed (alone or in a `Union`) no longer depends on the order the sites are
    # written in; a refinement seed (`non-empty-array[0]`) still can, since its remover does not close a literal.
    #
    # A site whose widening declines leaves the binding as it is, exactly as the straight-line seam does: a
    # precise nominal (a declared or inferred `Array[String]` is a claim this seam may not grow), a receiver
    # that is no carrier, or a name the mutator tables do not list for that carrier (`store` on a `Tuple`, a method
    # its class does not define). The caller MUST therefore not read an unchanged binding as describing later
    # iterations. An empty-witness refinement under a storing mutator that keeps the witness is not such a decline:
    # the straight-line widening grows it (issue #936), and gives a site whose arguments describe nothing it stores
    # (`non-empty-array[String]` under `map!`) the gradual arm itself ({RewriteMutation}),
    # so the site widens like any other storing site.
    #
    # The per-element block fold is the consumer: it types every position from one entry scope, so the binding
    # it lays under each position has to hold whatever earlier iterations stored. Unknown evidence is the point,
    # not a shortcut — a stored value typed in that same entry scope (`h[k] = h[k] + 1`) is itself a
    # first-iteration answer.
    #
    # Two more kinds of site change a binding's contents without naming it as the receiver, and each is widened
    # the way straight-line code widens it:
    #
    # - A mutator on an ELEMENT of the binding (`a[0] << e`, `a.first.push(e)`): the site's receiver is an element
    #   read rooted at the variable ({ElementReadWidening.element_read_path}), and the same widening runs on the
    #   element the path selects, rebuilding the carrier around it. The other slots keep their types, and a path
    #   {ElementReadWidening} cannot follow (a `HashShape` slot) declines, as it does on straight-line code.
    # - A self-call whose callee content-mutates the parameter the binding is passed to (`add_to(a, e)`, a
    #   {CalleeStore}): nothing at the call says what the callee stores or removes, so each collection the binding
    #   can hold is floored to its bare carrier ({.content_floor}), as ADR-57's callee floor does after the call.
    module UnknownStoreWidening
      # Mutators that only remove or reorder what the receiver already holds.
      VALUE_PRESERVING = %i[
        pop shift delete delete_at delete_if reject! select! filter! keep_if clear compact! uniq! slice!
        sort! sort_by! reverse! rotate! shuffle!
      ].to_set.freeze

      # A site that mutates a binding through a callee: `call` passes the variable, read by one of `arguments`, to
      # a parameter the callee content-mutates.
      CalleeStore = Data.define(:call, :arguments)

      COLLECTION_CLASSES = %w[Array Hash].freeze
      FLOORED_CLASSES = %w[Array Hash String].freeze

      NO_ARG_NODES = [].freeze
      private_constant :COLLECTION_CLASSES, :FLOORED_CLASSES, :NO_ARG_NODES

      module_function

      # @param sites — in-place mutation nodes whose receiver, or an element read their receiver starts from, can
      #   evaluate to the binding `type` describes, and {CalleeStore}s whose call passes that binding.
      # @return `type` widened through every site; `type` itself when no site's widening applies.
      def widen(type, sites)
        sites.reduce(type) { |acc, site| widen_site(acc, site) || acc }
      end

      # `type` widened through one site, or `nil` when its widening declines.
      def widen_site(type, site)
        return content_floor(type) if site.is_a?(CalleeStore)

        method_name, arg_types = unknown_store(site)
        path = ElementReadWidening.element_read_path(site.receiver)
        return widen_store(type, method_name, arg_types) if path.nil?

        ElementReadWidening.widen_through_path(type, path.last, method_name, arg_types) do |element|
          widen_store(element, method_name, arg_types)
        end
      end

      # The straight-line widening of `type` under `method_name`, with the gradual arm on every site that can store.
      def widen_store(type, method_name, arg_types)
        widened = MutationWidening.widen_for_mutator(type, method_name, arg_types: arg_types)
        return nil if widened.nil?

        VALUE_PRESERVING.include?(method_name) && !literal_carrier?(type) ? widened : gradual_content(widened)
      end

      # Every `Array` / `Hash` / `String` carrier `type` can be as its bare carrier: `Array[Dynamic[top]]`,
      # `Hash[Dynamic[top], Dynamic[top]]`, `String`. A literal, a nominal (a precise one included) and a refinement
      # over one ({.carrier_class}) all floor; so `non-empty-string`, which a callee can empty, reads `String`.
      # Unlike the escaping floor (`StatementEvaluator#content_floor_for`), which answers one carrier for a whole
      # `Union`, this floors a `Union` member by member, so a member no callee can fill (`nil`) stays: the binding
      # stands where the entry binding stood, and dropping a member would narrow it. Anything else is returned
      # untouched.
      def content_floor(type)
        return Type::Combinator.union(*type.members.map { |member| content_floor(member) }) if type.is_a?(Type::Union)

        carrier = carrier_class(type)
        carrier ? carrier_floor(carrier) : type
      end

      # {.content_floor} for the literal carriers alone: a `Tuple` or `HashShape` (alone or as a `Union` member) reads
      # as its bare carrier, and anything else — a nominal, a String — is returned untouched. A literal records slots
      # the next value need not have; a nominal is a claim about every value, which this does not loosen.
      def literal_floor(type)
        case type
        when Type::Union then Type::Combinator.union(*type.members.map { |member| literal_floor(member) })
        when Type::Tuple then carrier_floor("Array")
        when Type::HashShape then carrier_floor("Hash")
        else type
        end
      end

      # `"Array"`, `"Hash"` or `"String"` when `type` is a form of that carrier — a literal, a nominal, or a
      # difference, refinement or intersection over one (`non-empty-array[Integer]`, `decimal-int-string`,
      # `non-empty-uppercase-string`) — else nil.
      def carrier_class(type)
        case type
        when Type::Tuple then "Array"
        when Type::HashShape then "Hash"
        when Type::Constant then "String" if type.value.is_a?(String)
        when Type::Nominal then type.class_name if FLOORED_CLASSES.include?(type.class_name)
        when Type::Difference, Type::Refined then carrier_class(type.base)
        when Type::Intersection then intersection_carrier_class(type)
        end
      end

      def intersection_carrier_class(type)
        type.members.each do |member|
          carrier = carrier_class(member)
          return carrier if carrier
        end
        nil
      end

      def carrier_floor(class_name)
        return Type::Combinator.nominal_of("String") if class_name == "String"

        arity = class_name == "Hash" ? 2 : 1
        Type::Combinator.nominal_of(class_name, type_args: Array.new(arity) { Type::Combinator.untyped })
      end

      # A carrier that still records its slots or keys: a `Tuple` / `HashShape`, alone or as a `Union` member.
      def literal_carrier?(type)
        case type
        when Type::Tuple, Type::HashShape then true
        when Type::Union then type.members.any? { |member| literal_carrier?(member) }
        else false
        end
      end

      # `[mutator, arg_types]` for one site: a call stores through its own name and arguments, an index write
      # through `[]=` with its index arguments ahead of the value. A splat stays the `nil` arity marker the
      # `[]=` splice classifier reads.
      def unknown_store(site)
        arguments = site.arguments&.arguments || NO_ARG_NODES
        unknown = arguments.map { |arg| arg.is_a?(Prism::SplatNode) ? nil : Type::Combinator.untyped }
        return [site.name, unknown] if site.is_a?(Prism::CallNode)

        [:[]=, unknown + [Type::Combinator.untyped]]
      end

      # An `Array` / `Hash` nominal (alone, as a `Union` member, or as a refinement's base) with a value-pinned type
      # argument. `Type::Combinator.widen_value_pinned` does not look inside type arguments, so each one is asked on
      # its own. A `bool` or a literal union a signature declared (`Array[:a | :b]`) counts as pinned too; the arm it
      # takes can only quiet a report, which is the accepted cost of reading every such binding past one iteration.
      # A class-level argument (`Array[Integer]`) is not pinned: a store of the same class leaves it true, which is
      # the claim this seam may not grow.
      def value_pinned_collection?(type)
        case type
        when Type::Union then type.members.any? { |member| value_pinned_collection?(member) }
        when Type::Difference then value_pinned_collection?(type.base)
        when Type::Nominal
          COLLECTION_CLASSES.include?(type.class_name) &&
            type.type_args.any? { |arg| Type::Combinator.widen_value_pinned(arg) != arg }
        else false
        end
      end

      # Every type argument of an `Array` / `Hash` carrier joined with `Dynamic[top]`, member-wise through a
      # `Union` and through a `Difference`'s base. Anything else is returned untouched.
      def gradual_content(type)
        case type
        when Type::Union then Type::Combinator.union(*type.members.map { |member| gradual_content(member) })
        when Type::Difference then Type::Combinator.difference(gradual_content(type.base), type.removed)
        when Type::Nominal
          return type unless COLLECTION_CLASSES.include?(type.class_name) && !type.type_args.empty?

          Type::Combinator.nominal_of(
            type.class_name,
            type_args: type.type_args.map { |arg| Type::Combinator.union(arg, Type::Combinator.untyped) }
          )
        else type
        end
      end
    end
  end
end
