# frozen_string_literal: true

module Rigor
  module Plugin
    module Macro
      # ADR-16 Tier A declaration: "the block passed to a
      # class-level DSL call of one of `verbs` runs as an instance
      # method on `receiver_constraint`'s subclass tree, with
      # `self` typed accordingly."
      #
      # Authored on a plugin manifest:
      #
      #   manifest(
      #     id: "sinatra",
      #     version: "0.1.0",
      #     block_as_methods: [
      #       Rigor::Plugin::Macro::BlockAsMethod.new(
      #         receiver_constraint: "Sinatra::Base",
      #         verbs: %i[get post put delete head options patch link unlink]
      #       )
      #     ]
      #   )
      #
      # Sinatra is the canonical worked target (`Sinatra::Base#generate_method`
      # at `lib/sinatra/base.rb:1788-1793` literally does
      # `define_method(name, &block); remove_method` — the block IS
      # the method body, byte-for-byte). The substrate adopts the
      # same contract: declare the receiver constraint + the
      # class-level methods whose block argument runs as if it were
      # an instance method of the receiver.
      #
      # Slice 1a (this file) is **the contract only**. The engine
      # hook that consults registered entries and narrows
      # `Scope#self_type` for a block whose enclosing call matches
      # arrives in slice 1b.
      #
      # ## Fields
      #
      # - `receiver_constraint` — fully-qualified class name (String)
      #   that the call's lexical receiver MUST be (or inherit from)
      #   for the entry to fire. For Sinatra modular-style this is
      #   `"Sinatra::Base"`; the substrate's class-context match
      #   accepts every subclass.
      # - `verbs` — Array of Symbol method names. A call shape
      #   `<receiver_subclass>.get('/path') { ... }` matches when
      #   `:get` is in this list.
      # - `self_type` — Symbol selecting the kind of `self`-binding
      #   the substrate applies inside the block. Slice 1a accepts
      #   only `:receiver_instance` (the block runs as an instance
      #   method of the receiver class). Other kinds (`:receiver_singleton`,
      #   `:dsl_recorder`) are reserved for later slices.
      #
      # ## Ractor-shareability
      #
      # All fields are frozen at construction (ADR-15 Phase 1).
      # `verbs` is dup-frozen so the caller's mutable array does
      # not leak into the value. `Ractor.shareable?` returns true
      # after `#initialize`.
      class BlockAsMethod
        SELF_TYPE_RECEIVER_INSTANCE = :receiver_instance
        VALID_SELF_TYPES = [SELF_TYPE_RECEIVER_INSTANCE].freeze

        attr_reader :receiver_constraint, :verbs, :self_type

        def initialize(receiver_constraint:, verbs:, self_type: SELF_TYPE_RECEIVER_INSTANCE)
          validate_receiver_constraint!(receiver_constraint)
          validate_verbs!(verbs)
          validate_self_type!(self_type)

          @receiver_constraint = receiver_constraint.dup.freeze
          @verbs = verbs.map(&:to_sym).freeze
          @self_type = self_type
          freeze
        end

        def to_h
          {
            "receiver_constraint" => receiver_constraint,
            "verbs" => verbs.map(&:to_s),
            "self_type" => self_type.to_s
          }
        end

        def ==(other)
          other.is_a?(BlockAsMethod) &&
            receiver_constraint == other.receiver_constraint &&
            verbs == other.verbs &&
            self_type == other.self_type
        end
        alias eql? ==

        def hash
          [receiver_constraint, verbs, self_type].hash
        end

        private

        def validate_receiver_constraint!(value)
          return if value.is_a?(String) && !value.empty?

          raise ArgumentError,
                "Plugin::Macro::BlockAsMethod#receiver_constraint must be a non-empty String, " \
                "got #{value.inspect}"
        end

        def validate_verbs!(verbs)
          unless verbs.is_a?(Array) && !verbs.empty?
            raise ArgumentError,
                  "Plugin::Macro::BlockAsMethod#verbs must be a non-empty Array, got #{verbs.inspect}"
          end

          verbs.each do |v|
            next if v.is_a?(Symbol) || (v.is_a?(String) && !v.empty?)

            raise ArgumentError,
                  "Plugin::Macro::BlockAsMethod#verbs entries must be Symbol/non-empty String, " \
                  "got #{v.inspect}"
          end
        end

        def validate_self_type!(self_type)
          return if VALID_SELF_TYPES.include?(self_type)

          raise ArgumentError,
                "Plugin::Macro::BlockAsMethod#self_type must be one of #{VALID_SELF_TYPES.inspect}, " \
                "got #{self_type.inspect}"
        end
      end
    end
  end
end
