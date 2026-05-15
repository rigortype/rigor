# frozen_string_literal: true

module Rigor
  module Plugin
    module Macro
      # ADR-16 Tier B declaration: "the class-level DSL call
      # `<receiver_constraint>.<method_name>(:trait_a, :trait_b, ...)`
      # effectively includes the modules named in
      # `modules_by_symbol[:trait_a]` + `[:trait_b]` (plus any
      # `always_included` modules) on the calling class."
      #
      # Worked target: Devise's model-side `devise :database_authenticatable,
      # :recoverable` DSL (per-library survey § Devise). The bundled
      # registry mirrors `lib/devise/modules.rb`'s symbol → module table;
      # `always_included` carries the modules Devise always mixes in
      # regardless of selection (e.g. `Devise::Models::Authenticatable`).
      #
      # ## Authoring shape
      #
      #     manifest(
      #       id: "devise",
      #       version: "0.1.0",
      #       trait_registries: [
      #         Rigor::Plugin::Macro::TraitRegistry.new(
      #           receiver_constraint: "ActiveRecord::Base",
      #           method_name: :devise,
      #           symbol_arg_position: :rest,
      #           modules_by_symbol: {
      #             database_authenticatable: "Devise::Models::DatabaseAuthenticatable",
      #             recoverable:              "Devise::Models::Recoverable",
      #             rememberable:             "Devise::Models::Rememberable"
      #           },
      #           always_included: ["Devise::Models::Authenticatable"]
      #         )
      #       ]
      #     )
      #
      # ## Fields
      #
      # - `receiver_constraint` — fully-qualified class name (String).
      #   Synthesis fires when the call's lexical receiver class
      #   equals or inherits from this constraint.
      # - `method_name` — Symbol naming the DSL method
      #   (e.g. `:devise`).
      # - `symbol_arg_position` — `:rest` (all positional Symbol args
      #   are traits, slice 3a's only supported form) or a
      #   non-negative Integer (the index of a single trait symbol —
      #   reserved for future shapes; not yet honoured by the
      #   scanner).
      # - `modules_by_symbol` — Hash<Symbol, String>. Maps each
      #   recognised trait symbol to a fully-qualified module name.
      #   Symbols not in the table fall through (silent skip; the
      #   scanner emits a `macro.tier_b.unknown-trait` `:info`
      #   provenance marker per WD9 / WD13).
      # - `always_included` — Array<String>. Fully-qualified module
      #   names that are added to every call site (even when no
      #   symbols match). Mirrors Devise's `always_include` modules.
      #
      # ## Floor / ceiling per ADR-16 WD13
      #
      # Slice 3 ships at the **floor**: the substrate per-method-
      # explodes each included module's RBS instance methods into
      # the existing `SyntheticMethodIndex` (slice 2b primitive).
      # The synthesised methods adopt the module's authored RBS
      # return types — Tier B is NOT subject to the Tier C
      # `Dynamic[T]` floor because the source-of-truth (the
      # module's authored RBS) is not a manifest-declared string.
      # Per ADR-5 robustness, the substrate does not fabricate
      # precision; it simply replays the modules's signatures.
      #
      # **Out of scope for slice 3** (deferred follow-ups):
      # - `class_methods_module:` per-trait (Devise's `ClassMethods`
      #   extend-pattern); slice 3 covers instance methods only.
      # - `sort_key:` for controlled include ordering across traits;
      #   slice 3 uses plugin-registration order then registry
      #   declaration order.
      # - `included_do_digest:` — the per-module `included do` block
      #   facts (attr_reader / after_save / etc.); slice 3 emits
      #   only the module's plain instance methods.
      #
      # ## Slice 3a scope
      #
      # This file ships the value class only. Slice 3b wires the
      # scanner that walks Tier B call sites + the per-method
      # explosion via `SyntheticMethodIndex`; slice 3c authors
      # `examples/rigor-devise/` model side as the worked consumer.
      class TraitRegistry
        REST_POSITION = :rest

        attr_reader :receiver_constraint, :method_name, :symbol_arg_position, :modules_by_symbol, :always_included

        def initialize(receiver_constraint:, method_name:, symbol_arg_position: REST_POSITION,
                       modules_by_symbol: {}, always_included: [])
          validate_receiver_constraint!(receiver_constraint)
          validate_method_name!(method_name)
          validate_symbol_arg_position!(symbol_arg_position)
          validate_modules_by_symbol!(modules_by_symbol)
          validate_always_included!(always_included)

          @receiver_constraint = receiver_constraint.dup.freeze
          @method_name = method_name.to_sym
          @symbol_arg_position = symbol_arg_position
          @modules_by_symbol = modules_by_symbol.to_h { |k, v| [k.to_sym, v.dup.freeze] }.freeze
          @always_included = always_included.map { |m| m.dup.freeze }.freeze
          freeze
        end

        def to_h
          {
            "receiver_constraint" => receiver_constraint,
            "method_name" => method_name.to_s,
            "symbol_arg_position" => symbol_arg_position.to_s,
            "modules_by_symbol" => modules_by_symbol.to_h { |k, v| [k.to_s, v] },
            "always_included" => always_included
          }
        end

        def ==(other)
          other.is_a?(TraitRegistry) && to_h == other.to_h
        end
        alias eql? ==

        def hash
          to_h.hash
        end

        # @return [String, nil] fully-qualified module name for the
        #   given trait symbol, or nil when the registry doesn't
        #   know the symbol (caller emits a tier_b.unknown-trait
        #   provenance marker and falls through).
        def module_for(symbol)
          modules_by_symbol[symbol.to_sym]
        end

        private

        def validate_receiver_constraint!(value)
          return if value.is_a?(String) && !value.empty?

          raise ArgumentError,
                "Plugin::Macro::TraitRegistry#receiver_constraint must be a non-empty String, " \
                "got #{value.inspect}"
        end

        def validate_method_name!(value)
          return if value.is_a?(Symbol) || (value.is_a?(String) && !value.empty?)

          raise ArgumentError,
                "Plugin::Macro::TraitRegistry#method_name must be Symbol or non-empty String, " \
                "got #{value.inspect}"
        end

        def validate_symbol_arg_position!(value)
          return if value == REST_POSITION || (value.is_a?(Integer) && value >= 0)

          raise ArgumentError,
                "Plugin::Macro::TraitRegistry#symbol_arg_position must be :rest or a non-negative Integer, " \
                "got #{value.inspect}"
        end

        def validate_modules_by_symbol!(value)
          unless value.is_a?(Hash)
            raise ArgumentError,
                  "Plugin::Macro::TraitRegistry#modules_by_symbol must be a Hash, got #{value.inspect}"
          end

          value.each do |k, v|
            unless k.is_a?(Symbol) || (k.is_a?(String) && !k.empty?)
              raise ArgumentError,
                    "Plugin::Macro::TraitRegistry#modules_by_symbol key must be Symbol/non-empty String, " \
                    "got #{k.inspect}"
            end
            next if v.is_a?(String) && !v.empty?

            raise ArgumentError,
                  "Plugin::Macro::TraitRegistry#modules_by_symbol value must be a non-empty String, " \
                  "got #{v.inspect}"
          end
        end

        def validate_always_included!(value)
          unless value.is_a?(Array)
            raise ArgumentError,
                  "Plugin::Macro::TraitRegistry#always_included must be an Array, got #{value.inspect}"
          end

          value.each do |m|
            next if m.is_a?(String) && !m.empty?

            raise ArgumentError,
                  "Plugin::Macro::TraitRegistry#always_included entry must be a non-empty String, " \
                  "got #{m.inspect}"
          end
        end
      end
    end
  end
end
