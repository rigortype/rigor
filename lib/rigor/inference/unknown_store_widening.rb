# frozen_string_literal: true

require "prism"

require_relative "../type"
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
    # answer no longer depends on the order the sites are written in.
    #
    # A site whose widening declines leaves the binding as it is, exactly as the straight-line seam does: a
    # precise nominal (a declared or inferred `Array[String]` is a claim this seam may not grow), a receiver
    # that is no carrier, a name the mutator tables do not list for that carrier (`Hash#shift`), or an
    # empty-witness refinement under a mutator that keeps the witness and joins nothing (`non-empty-array[String]`
    # under `map!`). The caller MUST therefore not read an unchanged binding as describing later iterations.
    #
    # The per-element block fold is the consumer: it types every position from one entry scope, so the binding
    # it lays under each position has to hold whatever earlier iterations stored. Unknown evidence is the point,
    # not a shortcut — a stored value typed in that same entry scope (`h[k] = h[k] + 1`) is itself a
    # first-iteration answer.
    module UnknownStoreWidening
      # Mutators that only remove or reorder what the receiver already holds.
      VALUE_PRESERVING = %i[
        pop shift delete delete_at delete_if reject! select! filter! keep_if clear compact! uniq! slice!
        sort! sort_by! reverse! rotate! shuffle!
      ].to_set.freeze

      COLLECTION_CLASSES = %w[Array Hash].freeze

      NO_ARG_NODES = [].freeze
      private_constant :COLLECTION_CLASSES, :NO_ARG_NODES

      module_function

      # @param sites — in-place mutation nodes whose receiver can evaluate to the binding `type` describes.
      # @return `type` widened through every site; `type` itself when no site's widening applies.
      def widen(type, sites)
        sites.reduce(type) do |acc, site|
          method_name, arg_types = unknown_store(site)
          widened = MutationWidening.widen_for_mutator(acc, method_name, arg_types: arg_types)
          next acc if widened.nil?

          VALUE_PRESERVING.include?(method_name) && !literal_carrier?(acc) ? widened : gradual_content(widened)
        end
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
