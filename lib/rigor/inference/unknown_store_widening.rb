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
    # `Dynamic[top]` per argument, so every content arm a site can add carries the one-store gradual floor and
    # the value pinning a slot-rewriting site falsifies is erased: `{ a: 0 }` under `h[k] += 1` reads
    # `Hash[Dynamic[top] | Symbol, Dynamic[top] | Integer]`. A site whose widening declines the binding (a
    # precise declared nominal, a receiver that is no carrier) leaves it as it is, exactly as the
    # straight-line seam leaves it.
    #
    # The per-element block fold is the consumer: it types every position from one entry scope, so the binding
    # it lays under each position has to hold whatever earlier iterations stored. Unknown evidence is the point,
    # not a shortcut — a stored value typed in that same entry scope (`h[k] = h[k] + 1`) is itself a
    # first-iteration answer.
    module UnknownStoreWidening
      NO_ARG_NODES = [].freeze
      private_constant :NO_ARG_NODES

      module_function

      # @param sites — in-place mutation nodes whose receiver can evaluate to the binding `type` describes.
      # @return `type` widened through every site; `type` itself when no site's widening applies.
      def widen(type, sites)
        sites.reduce(type) do |acc, site|
          method_name, arg_types = unknown_store(site)
          MutationWidening.widen_for_mutator(acc, method_name, arg_types: arg_types) || acc
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
    end
  end
end
