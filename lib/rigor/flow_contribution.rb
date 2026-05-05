# frozen_string_literal: true

module Rigor
  # The public packaging of a flow contribution at a single call edge.
  # Plugins, `RBS::Extended` annotations, and built-in narrowing rules
  # all hand the analyzer this same bundle shape; the inference engine
  # merges contributions through the policy described in
  # [ADR-2 § "Plugin Contribution Merging"](../../docs/adr/2-extension-api.md)
  # rather than letting any one source override another silently.
  #
  # Eight content slots plus a {Provenance} block. A slot left as `nil`
  # (or, for collection-shaped slots, an empty collection) means the
  # contribution does not assert anything in that dimension; the merge
  # policy treats it as absent.
  #
  # The struct is the only shape plugin authors need to learn. Richer
  # or more permissive shapes are not part of the first public
  # contract — see ADR-2 § "Flow Contribution Bundle" for the binding
  # definition.
  #
  # The element-list flattening (`to_element_list`) ADR-2 mentions is
  # intentionally not implemented yet: it is the analyzer-internal
  # bookkeeping behind the merge policy and will land alongside the
  # plugin contribution merger in v0.1.0. Plugin authors should not
  # rely on it.
  class FlowContribution
    # Provenance carries the metadata every contribution needs for
    # diagnostic attribution and cache invalidation. `source_family`
    # mirrors {Rigor::Analysis::Diagnostic::DEFAULT_SOURCE_FAMILY};
    # `descriptor` is the {Rigor::Cache::Descriptor} this
    # contribution attaches to (or `nil` when the contribution does
    # not need its own cache slice).
    Provenance = Data.define(:source_family, :plugin_id, :node, :descriptor) do
      def self.builtin
        new(source_family: :builtin, plugin_id: nil, node: nil, descriptor: nil)
      end
    end

    SLOT_NAMES = %i[
      return_type
      truthy_facts
      falsey_facts
      post_return_facts
      mutations
      invalidations
      exceptional
      role_conformance
    ].freeze

    attr_reader(*SLOT_NAMES, :provenance)

    # @param return_type [Object, nil] normal-edge return type. Use
    #   `nil` when the contribution does not refine the return type
    #   selected from the RBS contract.
    # @param truthy_facts [Array, nil] facts that hold only on the
    #   truthy control-flow edge. Edge-local: a truthy-edge fact does
    #   NOT imply its falsey-edge complement (ADR-2 § "Plugin
    #   Contribution Merging").
    # @param falsey_facts [Array, nil] dual of `truthy_facts`.
    # @param post_return_facts [Array, nil] facts that hold after the
    #   call returns normally on every edge — the carrier for
    #   assertion-style contributions.
    # @param mutations [Array, nil] receiver and argument mutation
    #   effects.
    # @param invalidations [Array, nil] targeted fact invalidations
    #   beyond what mutation effects already imply.
    # @param exceptional [Object, nil] non-returning, raising, or
    #   unreachable effect.
    # @param role_conformance [Array, nil] capability-role conformance
    #   facts the contribution provides.
    # @param provenance [Provenance] source-family, plugin-id, node,
    #   and cache-descriptor metadata. Defaults to `Provenance.builtin`.
    # rubocop:disable Metrics/ParameterLists
    def initialize(return_type: nil, truthy_facts: nil, falsey_facts: nil,
                   post_return_facts: nil, mutations: nil, invalidations: nil,
                   exceptional: nil, role_conformance: nil,
                   provenance: Provenance.builtin)
      # rubocop:enable Metrics/ParameterLists
      @return_type = return_type
      @truthy_facts = freeze_collection(truthy_facts)
      @falsey_facts = freeze_collection(falsey_facts)
      @post_return_facts = freeze_collection(post_return_facts)
      @mutations = freeze_collection(mutations)
      @invalidations = freeze_collection(invalidations)
      @exceptional = exceptional
      @role_conformance = freeze_collection(role_conformance)
      @provenance = provenance
      freeze
    end

    # @return [Boolean] true when every content slot is unset (nil or
    #   an empty collection). Provenance does not count toward
    #   emptiness — an empty bundle still carries source attribution.
    def empty?
      SLOT_NAMES.all? { |slot| slot_empty?(public_send(slot)) }
    end

    def to_h
      SLOT_NAMES.each_with_object(provenance: provenance.to_h) do |slot, acc|
        acc[slot] = public_send(slot)
      end
    end

    def ==(other)
      other.is_a?(FlowContribution) && to_h == other.to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end

    private

    def freeze_collection(value)
      return nil if value.nil?

      value.dup.freeze
    end

    def slot_empty?(value)
      return true if value.nil?
      return value.empty? if value.respond_to?(:empty?)

      false
    end
  end
end
