# frozen_string_literal: true

module Rigor
  module Inference
    module ScopeIndexer
      # The accumulator the mixin walks ({ScopeIndexer#mixin_tables}, {ScopeIndexer#extend_tables}) fill: the
      # per-class module lists as before, plus which recorded edges have no position the tables can vouch for
      # (`Scope::DiscoveryIndex#unpositioned_mixins`).
      #
      # The mixin tables store each class's modules in the order the statements that wrote them run, and that
      # order is a fact only for a DIRECT statement of the class's own body (or of its `class << self` body):
      # `include M` there runs where it is written. An `include` inside a method, a block (`class_eval`,
      # `Class.new`, `included do`), a conditional or any other expression runs when that code runs, if it
      # runs at all, and the receiver form (`Base.prepend(M)`) runs wherever it is called from — so the order
      # the tables give such an edge is a guess. So is the position of every module an argument list shares
      # with one the walk cannot name (`include A, helper_module`). The walks record those edges as they
      # always did and name them here, so a reader that depends on ORDER can decline where the order is not
      # known. An edge written both ways is unpositioned: one guessed copy is enough to move the answer.
      #
      # A Hash (owner => lists), so every walk helper that indexes the accumulator keeps working unchanged.
      class MixinAccumulator < Hash
        def initialize
          super
          @direct = Set.new.compare_by_identity
          @unpositioned = {}
        end

        # Marks the statements of a declaration's own body — the only calls whose position is a fact.
        def direct_body(body)
          return unless body.is_a?(Prism::StatementsNode)

          body.body.each { |statement| @direct << statement if statement.is_a?(Prism::CallNode) }
        end

        # Notes the edges `node` recorded for `owner`. `complete` is false when an argument named nothing the
        # walk could record, which leaves the recorded names' neighbours unknown.
        def note(node, owner, targets, complete:)
          return if complete && node.receiver.nil? && @direct.include?(node)

          (@unpositioned[owner] ||= []).concat(targets)
        end

        # `{owner => [module names, as written]}`, frozen, each list de-duplicated.
        def unpositioned
          @unpositioned.transform_values { |names| names.uniq.freeze }.freeze
        end
      end
    end
  end
end
