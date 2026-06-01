# frozen_string_literal: true

require "rigor/plugin"

require_relative "shoulda_matchers/analyzer"

module Rigor
  module Plugin
    # rigor-shoulda-matchers — validates shoulda-matchers
    # matchers against the `:model_index` cross-plugin fact
    # (ADR-9) published by `rigor-activerecord`.
    #
    # The plugin walks every `RSpec.describe <ModelConst> do
    # ... end` block and validates the matchers inside
    # against the model's known columns / associations.
    #
    # ## Recognised matchers (v0.1.0)
    #
    # **Column matchers** (validate the named column exists on
    # the model):
    #
    #   validate_presence_of(:col), validate_uniqueness_of(:col),
    #   validate_length_of(:col), validate_numericality_of(:col),
    #   validate_acceptance_of(:col), validate_inclusion_of(:col),
    #   validate_exclusion_of(:col), validate_absence_of(:col),
    #   validate_format_of(:col), validate_confirmation_of(:col),
    #   have_db_column(:col), have_db_index(:col)
    #
    # **Association matchers** (validate the association exists
    # AND its kind matches):
    #
    #   belong_to(:assoc), have_one(:assoc)            ← :singular
    #   have_many(:assoc), have_and_belong_to_many(:assoc) ← :collection
    #
    # ## Cross-plugin dependency
    #
    # The plugin consumes `:model_index` from `rigor-activerecord`.
    # When `rigor-activerecord` is NOT loaded (or hasn't
    # published an index for the analysed model), the plugin
    # falls silent — the cross-check is opt-in. Adding
    # `rigor-activerecord` to `.rigor.yml` unlocks the
    # diagnostics.
    #
    # ## Limitations (v0.1.0)
    #
    # - **No chained-matcher arg validation.** The chain
    #   options on `validate_length_of(:col).is_at_most(50)`,
    #   `validate_inclusion_of(:col).in_array([...])`,
    #   `allow_value("foo").for(:col)`, etc. are NOT validated
    #   (the `.is_at_most` etc. terminals are runtime-only).
    # - **No polymorphic / through validation.** `belong_to(:user).polymorphic`,
    #   `have_many(:posts, through: :memberships)` only check
    #   the named association; the chain modifiers are
    #   ignored.
    # - **No nested-attribute matchers.** `accept_nested_attributes_for(:posts)`
    #   not yet covered.
    # - **No callback matchers.** `callback(:before_save).before(:save)`
    #   would need a separate slice (overlaps with the
    #   model_index's `callbacks` column already exposed but
    #   no rspec-side recogniser yet).
    class ShouldaMatchers < Rigor::Plugin::Base
      manifest(
        id: "shoulda-matchers",
        version: "0.1.0",
        description: "Validates shoulda-matchers matchers (validate_presence_of / belong_to / " \
                     "have_many / have_db_column / ...) against :model_index from " \
                     "rigor-activerecord.",
        consumes: [
          { plugin_id: "activerecord", name: :model_index, optional: true }
        ]
      )

      def init(services)
        @services = services
        @model_index = nil
        @model_index_resolved = false
      end

      # ADR-37 — per-matcher validation over the engine-owned walk. The
      # model anchor (the enclosing `describe <Model>` const) comes from
      # the node-rule NodeContext ancestors; the diagnostic points at the
      # matcher name (message_loc). The :model_index fact (from
      # rigor-activerecord) is read lazily; without it the rule is silent.
      node_rule Prism::CallNode do |node, _scope, path, _fc, context|
        index = model_index_or_nil
        next [] if index.nil?

        Analyzer.violations_for(matcher_call: node, ancestors: context.ancestors, model_index: index).map do |violation|
          diagnostic(node, path: path, location: node.message_loc,
                           message: violation.message, severity: :warning, rule: violation.rule)
        end
      end

      private

      # Lazily resolves `:model_index` from
      # `rigor-activerecord`. Returns nil when the plugin
      # isn't loaded or no index has been published; the
      # analyzer treats nil as "no cross-check available" and
      # falls silent.
      def model_index_or_nil
        return @model_index if @model_index_resolved

        @model_index = @services.fact_store.read(plugin_id: "activerecord", name: :model_index)
        @model_index_resolved = true
        @model_index
      end
    end

    Rigor::Plugin.register(ShouldaMatchers)
  end
end
