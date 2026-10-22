# frozen_string_literal: true

module Rigor
  module Analysis
    class Runner
      # Issue #476 — the read-only, lazily built view of the project's RBS universe that the ADR-16 Tier B
      # (trait registry) half of {Inference::SyntheticMethodScanner} reads.
      #
      # The scanner needs exactly two answers from an environment: `#rbs_loader` (to explode a trait module such
      # as `Devise::Models::Recoverable` into its instance-method names) and `#class_ordering` (to decide
      # whether a project class descends from an RBS-known `receiver_constraint` such as
      # `ActiveRecord::Base`). Neither reads the synthetic-method index — `Environment.for_project` only stores
      # that index, the RBS loader never consults it — so the chicken-and-egg the issue describes (the env
      # consumes the scan's output) does not reach the loader: the view builds an environment WITHOUT the
      # index, the scan runs against it, and the run's real environment is built afterwards WITH the index.
      #
      # The build is deferred to the first question. A scan whose trait registries never match a call site
      # (no `devise` call in any class body) never asks, so it never pays the environment build. The build is
      # fail-soft: a raise leaves the view answering "unknown", which is what the nil environment answered
      # before — Tier B emits nothing rather than aborting the pre-pass.
      class ScanEnvironment
        # @param builder — called at most once, returns the {Rigor::Environment} (without a synthetic index).
        def initialize(&builder)
          @builder = builder
          @built = false
          @environment = nil
        end

        def rbs_loader
          environment&.rbs_loader
        end

        def class_ordering(lhs, rhs)
          env = environment
          env.nil? ? :unknown : env.class_ordering(lhs, rhs)
        end

        private

        def environment
          return @environment if @built

          @built = true
          @environment = @builder.call
        rescue StandardError
          @environment = nil
        end
      end
    end
  end
end
