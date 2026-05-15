# frozen_string_literal: true

module Rigor
  module Plugin
    module Macro
      # ADR-16 Tier C declaration: "the class-level DSL call
      # `<receiver_constraint>.<method_name>(name_arg, ...)` emits
      # synthetic methods on the calling class, with names
      # interpolating the source-visible literal argument at
      # `symbol_arg_position`."
      #
      # Textbook target — dry-struct's `attribute :name, T` and
      # ActiveStorage's `has_one_attached :avatar` both have this
      # shape: a class-level call enumerates a literal Symbol
      # argument; the framework `class_eval`s a heredoc
      # interpolating that Symbol; the emit table is fixed.
      #
      # ## Authoring shape
      #
      #     manifest(
      #       id: "activestorage",
      #       version: "0.1.0",
      #       heredoc_templates: [
      #         Rigor::Plugin::Macro::HeredocTemplate.new(
      #           receiver_constraint: "ActiveRecord::Base",
      #           method_name: :has_one_attached,
      #           symbol_arg_position: 0,
      #           emit: [
      #             { name: "#{name}",            returns: "ActiveStorage::Attached::One" },
      #             { name: "#{name}_attachment", returns: "ActiveStorage::Attachment" },
      #             { name: "#{name}_blob",       returns: "ActiveStorage::Blob" }
      #           ],
      #           class_level_emit: [
      #             { name: "with_attached_#{name}", returns: "ActiveRecord::Relation" }
      #           ]
      #         )
      #       ]
      #     )
      #
      # ## Fields
      #
      # - `receiver_constraint` — fully-qualified class name (String).
      #   Synthesis fires when the call's lexical receiver class
      #   equals or inherits from this constraint.
      # - `method_name` — Symbol naming the DSL method (e.g.
      #   `:has_one_attached`, `:attribute`).
      # - `symbol_arg_position` — Integer (default 0) — the
      #   argument index whose literal Symbol value becomes the
      #   `name` interpolated into each emit row's `name:`
      #   template. Slice 2a accepts non-negative integers only.
      # - `emit` — Array of `Emit` (or coerced Hash) — instance
      #   methods to synthesise on the calling class.
      # - `class_level_emit` — same shape, but the synthesised
      #   methods are singleton (class-level) methods.
      #
      # ## Floor / ceiling per ADR-16 WD13
      #
      # Slice 2 ships at the **floor**: each emit row's `name:`
      # is the source of truth for the synthetic method's name
      # (a single `"\#{name}"` placeholder gets interpolated with
      # the literal symbol argument at `symbol_arg_position`).
      # The `returns:` strings are **recorded in the manifest but
      # not resolved**; the engine emits synthetic methods with
      # `Dynamic[T]` returns plus a
      # `macro.tier_c.unresolved-return` provenance marker.
      # Precise return-type resolution via ADR-13's
      # `Plugin::TypeNodeResolver` is the **ceiling**, deferred
      # to a later slice — the `returns:` declarations cost
      # nothing to write today and unlock precision then.
      #
      # ## Slice 2a scope
      #
      # This file ships the value class only. Slice 2b wires the
      # pre-pass that scans Tier C call sites + the
      # `SyntheticMethodIndex` the dispatcher consults; slice 2c
      # authors `examples/rigor-dry-struct/` and
      # `examples/rigor-dry-types/` as the worked consumers.
      class HeredocTemplate
        NAME_PLACEHOLDER = "\#{name}"

        attr_reader :receiver_constraint, :method_name, :symbol_arg_position, :emit, :class_level_emit

        def initialize(receiver_constraint:, method_name:, symbol_arg_position: 0, emit: [], class_level_emit: [])
          validate_receiver_constraint!(receiver_constraint)
          validate_method_name!(method_name)
          validate_symbol_arg_position!(symbol_arg_position)

          @receiver_constraint = receiver_constraint.dup.freeze
          @method_name = method_name.to_sym
          @symbol_arg_position = symbol_arg_position
          @emit = coerce_emit_list!(emit, "emit")
          @class_level_emit = coerce_emit_list!(class_level_emit, "class_level_emit")
          freeze
        end

        def to_h
          {
            "receiver_constraint" => receiver_constraint,
            "method_name" => method_name.to_s,
            "symbol_arg_position" => symbol_arg_position,
            "emit" => emit.map(&:to_h),
            "class_level_emit" => class_level_emit.map(&:to_h)
          }
        end

        def ==(other)
          other.is_a?(HeredocTemplate) && to_h == other.to_h
        end
        alias eql? ==

        def hash
          to_h.hash
        end

        # One row of an emit table: the synthetic method's
        # name-template (the analyzer interpolates `\#{name}` with
        # the call-site literal symbol) and its declared return
        # type (recorded as a string in slice 2a, resolved by the
        # ceiling slice via ADR-13).
        class Emit
          attr_reader :name, :returns

          def initialize(name:, returns:)
            unless name.is_a?(String) && !name.empty?
              raise ArgumentError,
                    "Macro::HeredocTemplate::Emit#name must be a non-empty String, got #{name.inspect}"
            end
            unless returns.is_a?(String) && !returns.empty?
              raise ArgumentError,
                    "Macro::HeredocTemplate::Emit#returns must be a non-empty String, got #{returns.inspect}"
            end

            @name = name.dup.freeze
            @returns = returns.dup.freeze
            freeze
          end

          def to_h
            { "name" => name, "returns" => returns }
          end

          def ==(other)
            other.is_a?(Emit) && name == other.name && returns == other.returns
          end
          alias eql? ==

          def hash
            [name, returns].hash
          end
        end

        private

        def validate_receiver_constraint!(value)
          return if value.is_a?(String) && !value.empty?

          raise ArgumentError,
                "Plugin::Macro::HeredocTemplate#receiver_constraint must be a non-empty String, " \
                "got #{value.inspect}"
        end

        def validate_method_name!(value)
          return if value.is_a?(Symbol) || (value.is_a?(String) && !value.empty?)

          raise ArgumentError,
                "Plugin::Macro::HeredocTemplate#method_name must be Symbol or non-empty String, " \
                "got #{value.inspect}"
        end

        def validate_symbol_arg_position!(value)
          return if value.is_a?(Integer) && value >= 0

          raise ArgumentError,
                "Plugin::Macro::HeredocTemplate#symbol_arg_position must be a non-negative Integer, " \
                "got #{value.inspect}"
        end

        def coerce_emit_list!(entries, label)
          unless entries.is_a?(Array)
            raise ArgumentError,
                  "Plugin::Macro::HeredocTemplate##{label} must be an Array, got #{entries.inspect}"
          end

          entries.map { |entry| coerce_emit_entry!(entry, label) }.freeze
        end

        def coerce_emit_entry!(entry, label)
          case entry
          when Emit then entry
          when Hash
            Emit.new(name: entry[:name] || entry["name"], returns: entry[:returns] || entry["returns"])
          else
            raise ArgumentError,
                  "Plugin::Macro::HeredocTemplate##{label} entry must be an Emit or Hash, " \
                  "got #{entry.inspect}"
          end
        end
      end
    end
  end
end
