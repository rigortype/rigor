# frozen_string_literal: true

module Rigor
  module Plugin
    # One entry of a plugin's `effect_edges:` — a call graph edge the *syntax* does not contain but the
    # framework does (ADR-103 WD10; design note § 11.2 "Framework edges").
    #
    # `save` runs the class body's `before_save :normalize` and its validators; `Job.perform_now` runs
    # `Job#perform`; `UserMailer.welcome(u)` runs `UserMailer#welcome`. None of those is a call the
    # analyzer can see, and all three are ordinary synchronous in-process control flow — so a plugin that
    # models the framework contributes **edges**, not only labels.
    #
    # What a plugin must NOT contribute is the deferred half: `perform_later` never edges to `perform`,
    # because the body runs in another process on another stack and the caller's code does not contain it
    # (ADR-103 WD4, "attribution follows the code, not the clock"). The enum below has no spelling for it,
    # which is the enforcement.
    #
    # ## Why a fixed enum rather than a callback
    #
    # A plugin supplies **parameters**; the engine owns the strategy. A block would have to run inside the
    # per-file effect scan — the one place ADR-103 WD13 forbids anything that resolves, walks or types —
    # and would not survive the fork-pool / Ractor boundary the collection window crosses. The enum keeps
    # the plugin's contribution declarative, Marshal-clean and reviewable, and keeps every walk on the
    # engine's side of the contract.
    #
    # ## The strategies
    #
    # - `:activerecord_callbacks` — `receiver:` is the ActiveRecord base class. On every project class
    #   whose ancestry reaches it, the engine reads the class body's callback and validation macros
    #   (`before_save :sym`, `validate :sym`, `after_commit :sym`, …) and synthesises the persistence
    #   selectors (`save`, `create!`, `destroy`, `valid?`, …) as effect units edged to those methods.
    #   `validates … uniqueness: true` additionally contributes an `io.db.read` origin, because the
    #   uniqueness check IS a query.
    # - `:perform_now` — `receiver:` is the job base class. `Job.perform_now(…)` on a project subclass
    #   reaches `Job#perform`.
    # - `:mailer_body` — `receiver:` is the mailer base class. `UserMailer.welcome(u)` on a project
    #   subclass reaches `UserMailer#welcome`, the class-method-to-instance mapping ActionMailer performs
    #   at run time.
    #
    # `method:` and `singleton:` are carried for a future strategy that keys on one selector; the three
    # above read only `receiver:`.
    class EffectEdge
      # Every strategy the engine implements. A `target:` outside this set is a manifest error, so a
      # plugin cannot silently declare an edge nothing honours.
      TARGETS = %i[activerecord_callbacks perform_now mailer_body].freeze

      attr_reader :receiver, :method, :singleton, :target, :why

      def initialize(receiver:, target:, why:, method: nil, singleton: false)
        @receiver = validate_receiver!(receiver)
        @target = validate_target!(target)
        @method = method&.to_sym
        @singleton = singleton ? true : false
        @why = validate_why!(why)
        freeze
      end

      def to_h
        {
          "receiver" => @receiver, "method" => @method&.to_s, "singleton" => @singleton,
          "target" => @target.to_s
        }
      end

      def ==(other)
        other.is_a?(EffectEdge) && to_h == other.to_h
      end
      alias eql? ==

      def hash
        to_h.hash
      end

      private

      def validate_receiver!(receiver)
        value = receiver.to_s
        unless EffectAttribution::CLASS_NAME.match?(value)
          raise ArgumentError, "effect edge receiver must be a class name, got #{receiver.inspect}"
        end

        value.dup.freeze
      end

      def validate_target!(target)
        value = target.to_sym
        return value if TARGETS.include?(value)

        raise ArgumentError,
              "effect edge target must be one of #{TARGETS.inspect}, got #{target.inspect}"
      end

      def validate_why!(why)
        value = why.to_s
        raise ArgumentError, "effect edge #{@receiver} -> #{@target} needs a `why:` justification" if value.empty?

        value.dup.freeze
      end
    end
  end
end
