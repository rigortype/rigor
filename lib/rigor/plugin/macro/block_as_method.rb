# frozen_string_literal: true

module Rigor
  module Plugin
    module Macro
      # ADR-16 Tier A declaration: "the block passed to a class-level DSL call of one of `method_names` runs as
      # an instance method on `receiver_constraint`'s subclass tree, with `self` typed accordingly."
      #
      # Authored on a plugin manifest:
      #
      #   manifest(
      #     id: "sinatra",
      #     version: "0.1.0",
      #     block_as_methods: [
      #       Rigor::Plugin::Macro::BlockAsMethod.new(
      #         receiver_constraint: "Sinatra::Base",
      #         method_names: %i[get post put delete head options patch link unlink]
      #       )
      #     ]
      #   )
      #
      # Sinatra is the canonical worked target (`Sinatra::Base#generate_method` at
      # `lib/sinatra/base.rb:1788-1793` literally does `define_method(name, &block); remove_method` — the
      # block IS the method body, byte-for-byte). The substrate adopts the same contract: declare the receiver
      # constraint + the class-level methods whose block argument runs as if it were an instance method of the
      # receiver.
      #
      # Engine wiring: `Inference::MacroBlockSelfType.narrow_self_type_for` (called from expression_typer.rb)
      # consults registered entries and narrows `Scope#self_type` for matching block call sites.
      #
      # ## Fields
      #
      # - `receiver_constraint` — fully-qualified class name (String) that the call's lexical receiver MUST be
      #   (or inherit from) for the entry to fire. For Sinatra modular-style this is `"Sinatra::Base"`; the
      #   substrate's class-context match accepts every subclass.
      # - `method_names` — Array of Symbol method names. A call shape `<receiver_subclass>.get('/path') { ... }`
      #   matches when `:get` is in this list. (Named `verbs:` before ADR-60 WD2 normalised the macro
      #   value-object vocabulary.)
      # - `self_type` — the `self`-binding the substrate applies inside the block. `:receiver_instance`
      #   (the default) types `self` as an instance of the receiver class — the Sinatra contract. A String
      #   binds `self` to a *named* class instead of the receiver: `"Grape::Endpoint"` binds
      #   `Nominal[Grape::Endpoint]` (the block is `instance_eval`'d on an instance of that class, e.g. a
      #   route body on `Grape::Endpoint`), and `"singleton(Grape::API::Instance)"` binds
      #   `Singleton[Grape::API::Instance]` (the block is `instance_eval`'d on that *class object*, e.g.
      #   a `namespace` body on `Grape::API::Instance`). `:lexical` (issue #1667) leaves `self` as the caller's:
      #   the method runs the block where it was written (`block.refined(M).call`), so the entry only declares
      #   `refinements:`. Reserved Symbol names (`:receiver_singleton`, `:dsl_recorder`) remain unaccepted.
      # - `refinements` — Array of fully-qualified module-name Strings (default `[]`, issue #1667, ADR-121 WD5).
      #   The method runs the block under `Proc#refined` with these modules (`instance_exec(&block.refined(M))`),
      #   so they are appended to the block body's in-effect refinements after its lexical list, in the declared
      #   order (the last one wins). Nested blocks inherit them. A module that refines nothing the project or a
      #   gem's source inference makes visible contributes nothing.
      #
      # ## Matching
      #
      # A `:receiver_instance` or `singleton(...)` entry matches `Singleton[X]` receivers only (a class-level DSL
      # call). A named instance binding (`"Foo::Bar"`) and a `:lexical` entry also match `Nominal[X]` receivers:
      # a `:lexical` method is as often an instance method (`ActiveRecord::Relation#where`) as a class-level one.
      #
      # ## Ractor-shareability
      #
      # All fields are frozen at construction (ADR-15 Phase 1). `method_names` is dup-frozen so the caller's
      # mutable array does not leak into the value. `Ractor.shareable?` returns true after `#initialize`.
      class BlockAsMethod
        SELF_TYPE_RECEIVER_INSTANCE = :receiver_instance
        SELF_TYPE_LEXICAL = :lexical
        VALID_SELF_TYPES = [SELF_TYPE_RECEIVER_INSTANCE, SELF_TYPE_LEXICAL].freeze

        CLASS_NAME_PATTERN = /[A-Z]\w*(?:::[A-Z]\w*)*/
        # `self_type: "Foo::Bar"` — the block is `instance_eval`'d on an instance of `Foo::Bar`.
        NAMED_SELF_TYPE_PATTERN = /\A#{CLASS_NAME_PATTERN}\z/
        # `self_type: "singleton(Foo::Bar)"` — the block is `instance_eval`'d on the `Foo::Bar` class
        # object itself (Grape's `namespace`/`route_param` bodies run on `Grape::API::Instance`).
        SINGLETON_SELF_TYPE_PATTERN = /\Asingleton\((#{CLASS_NAME_PATTERN})\)\z/

        attr_reader :receiver_constraint, :method_names, :self_type, :refinements

        def initialize(receiver_constraint:, method_names:, self_type: SELF_TYPE_RECEIVER_INSTANCE, refinements: [])
          validate_receiver_constraint!(receiver_constraint)
          validate_method_names!(method_names)
          validate_self_type!(self_type)
          validate_refinements!(refinements)

          @receiver_constraint = receiver_constraint.dup.freeze
          @method_names = method_names.map(&:to_sym).freeze
          @self_type = self_type.is_a?(String) ? self_type.dup.freeze : self_type
          @refinements = refinements.map { |name| name.dup.freeze }.freeze
          freeze
        end

        def to_h
          {
            "receiver_constraint" => receiver_constraint,
            "method_names" => method_names.map(&:to_s),
            "self_type" => self_type.to_s,
            "refinements" => refinements
          }
        end

        def ==(other)
          other.is_a?(BlockAsMethod) &&
            receiver_constraint == other.receiver_constraint &&
            method_names == other.method_names &&
            self_type == other.self_type &&
            refinements == other.refinements
        end
        alias eql? ==

        def hash
          [receiver_constraint, method_names, self_type, refinements].hash
        end

        # Whether the block keeps the caller's `self` (`self_type: :lexical`).
        def lexical_self?
          self_type == SELF_TYPE_LEXICAL
        end

        # The class name a String `self_type` binds `self` to — `"Foo::Bar"` for both the plain and the
        # `singleton(Foo::Bar)` form — or `nil` for `:receiver_instance`.
        def self_type_name
          return nil unless self_type.is_a?(String)

          self_type[SINGLETON_SELF_TYPE_PATTERN, 1] || self_type
        end

        # Whether a String `self_type` binds the *class object* (`"singleton(Foo::Bar)"`) rather than an
        # instance (`"Foo::Bar"`). Nominal-receiver call sites only match instance-binding entries —
        # a `singleton(...)` binding exists solely for `instance_eval`-on-class contracts, which always
        # surface as `Singleton[X]` receivers.
        def singleton_binding?
          self_type.is_a?(String) && self_type.match?(SINGLETON_SELF_TYPE_PATTERN)
        end

        # Whether `self_type` names a class whose *instance* the block is `instance_eval`'d on
        # (`"Foo::Bar"`). These entries are the only ones that also match `Nominal[Y]` receivers: inside
        # an already-narrowed `instance_eval` body (`self : Nominal[ParamsScope]`), a nested call on
        # `self` re-enters the same context. `:receiver_instance` keeps its original Singleton-only
        # contract — a nominal receiver calling a class-level verb is a different (unmodelled) shape.
        def named_instance_binding?
          self_type.is_a?(String) && !singleton_binding?
        end

        # Whether `Nominal[X]` receivers match, beside `Singleton[X]` ones: a named instance binding, or a
        # `:lexical` entry.
        def matches_instance_receivers?
          named_instance_binding? || lexical_self?
        end

        private

        def validate_receiver_constraint!(value)
          return if value.is_a?(String) && !value.empty?

          raise ArgumentError,
                "Plugin::Macro::BlockAsMethod#receiver_constraint must be a non-empty String, " \
                "got #{value.inspect}"
        end

        def validate_method_names!(method_names)
          unless method_names.is_a?(Array) && !method_names.empty?
            raise ArgumentError,
                  "Plugin::Macro::BlockAsMethod#method_names must be a non-empty Array, got #{method_names.inspect}"
          end

          method_names.each do |v|
            next if v.is_a?(Symbol) || (v.is_a?(String) && !v.empty?)

            raise ArgumentError,
                  "Plugin::Macro::BlockAsMethod#method_names entries must be Symbol/non-empty String, " \
                  "got #{v.inspect}"
          end
        end

        def validate_refinements!(refinements)
          unless refinements.is_a?(Array)
            raise ArgumentError,
                  "Plugin::Macro::BlockAsMethod#refinements must be an Array, got #{refinements.inspect}"
          end

          refinements.each do |name|
            next if name.is_a?(String) && name.match?(NAMED_SELF_TYPE_PATTERN)

            raise ArgumentError,
                  "Plugin::Macro::BlockAsMethod#refinements entries must be module-name Strings ('Foo::Bar'), " \
                  "got #{name.inspect}"
          end
        end

        def validate_self_type!(self_type)
          return if VALID_SELF_TYPES.include?(self_type)
          return if self_type.is_a?(String) &&
                    (self_type.match?(NAMED_SELF_TYPE_PATTERN) || self_type.match?(SINGLETON_SELF_TYPE_PATTERN))

          raise ArgumentError,
                "Plugin::Macro::BlockAsMethod#self_type must be one of #{VALID_SELF_TYPES.inspect} " \
                "or a class-name String ('Foo::Bar' / 'singleton(Foo::Bar)'), got #{self_type.inspect}"
        end
      end
    end
  end
end
