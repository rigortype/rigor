# frozen_string_literal: true

require "rigor/plugin"

require_relative "minitest/assertion_analyzer"

module Rigor
  module Plugin
    # rigor-minitest — narrows locals through Minitest /
    # Test::Unit assertions.
    #
    # Recognises every supported `assert_*` / `refute_*` /
    # `assert_not_*` shape (Minitest core + Test::Unit aliases),
    # plus the Minitest/spec `_(x).must_*` / `.wont_*` matchers
    # (`expect(x)` / `value(x)` wrappers covered too). For each
    # recognised assertion the plugin emits a Rigor
    # `post_return_fact` whose `:local`-kind target narrows the
    # named local on the post-call edge so downstream calls in
    # the same `it` / `test_` / `def test_*` body resolve
    # against the narrowed type.
    #
    # ## Why a single plugin covers two frameworks
    #
    # Minitest and Test::Unit share the `assert_*` / `refute_*`
    # surface (Test::Unit's `assert_not_*` aliases are
    # recognised by the same rule table). The matchers_vaccine
    # gem layers RSpec-style matcher composition on top of
    # Minitest's `must` API and is covered by the spec-style
    # recogniser without additional wiring.
    #
    # ## Configuration
    #
    # No knobs in v0.1.0. Activate via `plugins: ["rigor-minitest"]`
    # in `.rigor.yml`.
    #
    # ## Limitations (v0.1.0)
    #
    # - **No `assert_raises(T) { ... }`** — that's a block-shape
    #   matcher and Rigor's narrowing model is for
    #   straight-line locals.
    # - **No `assert_predicate(x, :foo?)`** — needs a
    #   predicate-state carrier Rigor doesn't model today.
    # - **No `assert_respond_to(x, :m)`** — same shape gap
    #   (respond-to-set carrier).
    # - **No legacy bare `x.must_be_kind_of(T)`** — the
    #   receiver IS the value, so the analyzer has nothing to
    #   narrow against. Users should migrate to `_(x).must_*`.
    # - **No `assert_in_delta` / `assert_operator`** — float-
    #   range / generic operator narrowing is future work.
    # - **No `assert_throws(:tag) { ... }` / `assert_raises`** —
    #   block-form expectations need a separate slice.
    class Minitest < Rigor::Plugin::Base
      manifest(
        id: "minitest",
        version: "0.1.0",
        description: "Narrows locals through Minitest / Test::Unit `assert_*` / `refute_*` " \
                     "and Minitest/spec `_(x).must_*` / `.wont_*` matchers."
      )

      # Pillar 2 Slice 1 (rigor-minitest sibling) — emits
      # `post_return_facts` for every recognised assertion. The
      # engine routes `:local`-kind facts through
      # `StatementEvaluator#apply_local_post_return_fact` (added
      # in v0.1.8 for the rigor-rspec slice).
      def flow_contribution_for(call_node:, scope:)
        AssertionAnalyzer.contribution_for(call_node, environment: scope&.environment)
      end
    end

    Rigor::Plugin.register(Minitest)
  end
end
