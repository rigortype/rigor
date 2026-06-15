# frozen_string_literal: true

require "rigor/plugin"

module Rigor
  module Plugin
    # ADR-16 Tier C worked plugin: recognises dry-struct's class-
    # level `attribute :name, T` DSL and synthesises a reader on
    # the enclosing `Dry::Struct` subclass.
    #
    # dry-struct's `Dry::Struct::ClassInterface#attribute` (per the
    # per-library survey, `lib/dry/struct/class_interface.rb:86-88`
    # in the upstream gem) is the textbook Tier C target — a
    # class-level DSL call enumerates a literal Symbol argument, and
    # `class_interface.rb:452-464` `class_eval`s a heredoc
    # interpolating that Symbol into a getter:
    #
    #     class_eval(<<-RUBY, __FILE__, __LINE__ + 1)
    #       def #{key}                       # def city
    #         @attributes[#{key.inspect}]    #   @attributes[:city]
    #       end
    #     RUBY
    #
    # The substrate replays the same contract statically. For
    # source like:
    #
    #     class Address < Dry::Struct
    #       attribute :city, Types::String
    #       attribute :country, Types::String
    #     end
    #
    # the pre-pass scans the file, sees `attribute :city, ...`, and
    # synthesises `Address#city` as a SyntheticMethod the dispatcher
    # surfaces below RBS dispatch. Bare `address.city` calls in
    # other files then dispatch through the synthetic record rather
    # than falling through to `call.undefined-method`.
    #
    # ## Precision model (ADR-16 WD13 + ADR-18)
    #
    # The synthetic reader's return type is resolved via ADR-18's
    # `returns_from_arg:` fact lookup: the call-site's second argument
    # (`Types::String` etc.) is looked up through the `:dry_type_aliases`
    # fact published by `rigor-dry-types`, yielding `Nominal[String]`
    # for common cases. When the lookup misses (e.g. inline method-chain
    # argument whose chain-head isn't currently extracted), the row
    # falls back to `Dynamic[Top]` silently.
    #
    # ## Scope (slice 2c minimum)
    #
    # - Recognises `attribute :name, T` at class body top level.
    # - Recognises `attribute? :name, T` via a separate template
    #   entry (omittable attribute; same reader name, `?` stripped).
    # - Synthesises **only the reader** — the other survey-listed
    #   emit rows (`schema` key, `to_h` row, `[:key]` access, `.new`
    #   kwarg) are not yet wired by the substrate (they require
    #   either RBS-level shape synthesis or additional substrate
    #   primitives). Slice 2c stops at the reader.
    # - Nested-block form (`attribute :details do ... end` minting
    #   `Address::Details`) is out of scope for slice 2c; that
    #   pattern needs Tier A + Tier C composition + const_set
    #   emission. Deferred.
    class DryStruct < Rigor::Plugin::Base
      manifest(
        id: "dry-struct",
        version: "0.2.0",
        description: "Recognises dry-struct `attribute :name, T` DSL via ADR-16 Tier C; " \
                     "promotes the reader's return type through ADR-18's `returns_from_arg:` " \
                     "by consuming `rigor-dry-types`'s `:dry_type_aliases` fact.",
        # ADR-9 consumption — the precision-promotion path
        # below uses `:dry_type_aliases` published by
        # `rigor-dry-types`. The fact is optional: when the
        # `rigor-dry-types` plugin isn't loaded, the
        # `returns_from_arg:` lookup misses and the synthetic
        # readers fall back to `Dynamic[Top]` (the pre-ADR-18
        # floor).
        consumes: [{ plugin_id: "dry-types", name: :dry_type_aliases, optional: true }],
        heredoc_templates: [
          Rigor::Plugin::Macro::HeredocTemplate.new(
            receiver_constraint: "Dry::Struct",
            method_name: :attribute,
            symbol_arg_position: 0,
            # ADR-18 — the synthetic reader's return type comes
            # from the call site's second argument
            # (`Types::String` etc.), resolved through the
            # `:dry_type_aliases` fact. When the lookup misses
            # (e.g. inline `attribute :tag, Types::String.constrained(...)`,
            # whose receiver chain head isn't currently
            # extracted), the row falls back to Dynamic[Top].
            emit: [{
              name: "\#{name}",
              returns_from_arg: {
                position: 1,
                lookup_via: { plugin_id: "dry-types", fact: :dry_type_aliases }
              }
            }]
          ),
          Rigor::Plugin::Macro::HeredocTemplate.new(
            receiver_constraint: "Dry::Struct",
            method_name: :attribute?,
            symbol_arg_position: 0,
            emit: [{
              name: "\#{name}",
              returns_from_arg: {
                position: 1,
                lookup_via: { plugin_id: "dry-types", fact: :dry_type_aliases }
              }
            }]
          )
        ]
      )
    end

    Rigor::Plugin.register(DryStruct)
  end
end
