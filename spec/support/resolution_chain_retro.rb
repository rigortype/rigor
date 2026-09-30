# frozen_string_literal: true

# Builds the RETRO world of a `Scope::ResolutionChain` — the same class with every insertion the skip rule
# skipped made anyway — for specs that compare it with Ruby's own answer. The chain keeps its retro world
# private (`ResolutionChain#settle` is the one decision that reads it, and only for a chain with exactly one
# skip), so a spec that wants the world unconditionally asks the builder for it.
module ResolutionChainRetro
  module_function

  def build(scope, class_name, side = :instance, flavor = :methods)
    chain_class = Rigor::Scope::ResolutionChain
    bucket = chain_class.send(:flavor_bucket, scope.discovery, flavor)
    builder = chain_class.const_get(:Builder, false).new(scope, flavor, bucket, retro: true)
    catch(:rigor_retro_over_budget) { builder.chain(class_name, side) }
  end
end
