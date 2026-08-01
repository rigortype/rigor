# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class DrySchema < Rigor::Plugin::Base
      # Translates one `:dry_schema_table` entry into the `Rigor::Type::HashShape` that
      # `SomeSchema.call(input).to_h` returns, and recognises the call chain that earns it.
      #
      # The table entry is the shape {SchemaScanner} publishes:
      #
      #     { required: { email: { type: "String", list: false } },
      #       optional: { nickname: { type: "String", list: true } } }
      #
      # ## Why the shape mirrors the declaration's own vocabulary
      #
      # `Dry::Schema::Result#to_h` returns the *coerced input*, so on a failed validation a
      # `required(:email)` key can be absent. Modelling that worst case — every key optional — would be
      # the sound reading and the wrong one: the idiomatic consumer checks `success?` first, and typing
      # `result.to_h[:age]` as `Integer?` inside that branch draws a nil diagnostic on correct code.
      # Rigor weighs a false positive above a worst-case static reading (AGENTS.md § Implementation
      # Guidelines), and already took the same call for RBS's `%a{implicitly-returns-nil}`.
      #
      # So `required` rows become required keys and `optional` rows become optional keys — the schema's
      # own words. A reader who wrote `optional(:nickname)` is not surprised that the key reads as
      # possibly-absent, and one who wrote `required(:email)` is not surprised that it does not.
      #
      # The shape is **open**: dry-schema's key map only emits declared keys, but a closed shape would
      # turn any read of an undeclared key into a diagnostic, and being wrong there costs more than the
      # extra precision buys.
      module ResultShape
        # `:bool` rows land in the published fact as "TrueClass" — the fact's vocabulary names one
        # underlying class per row and has no union slot. A hash value typed `TrueClass` would false-fire
        # on every `false`, so the shape widens it back to the two-class union here rather than in the
        # fact, whose consumers (rigor-dry-struct, rigor-dry-validation) read it for a class name.
        BOOL_CLASSES = %w[TrueClass FalseClass].freeze

        module_function

        # The schema constant `to_h_node`'s receiver chain names, or nil when the chain isn't the
        # recognised `<Const>.call(...).to_h` form.
        #
        # Floor: the schema must be named by a constant *as written* at the call site, because the FQN is
        # matched against the table's keys verbatim. A schema referenced through a local
        # (`schema = NewUserSchema; schema.call(x).to_h`) or by a relative constant path from inside the
        # declaring module resolves to no entry and contributes nothing — the pre-slice behaviour.
        def schema_name(to_h_node)
          return nil unless to_h_node.is_a?(Prism::CallNode) && to_h_node.name == :to_h
          return nil unless to_h_node.arguments.nil? && to_h_node.block.nil?

          inner = to_h_node.receiver
          return nil unless inner.is_a?(Prism::CallNode) && inner.name == :call

          constant_name(inner.receiver)
        end

        # The HashShape for one table entry, or nil when the schema declares no key at all. An empty open
        # shape would be a carrier that says nothing the bare `untyped` did not already say, so declining
        # keeps the hash's type honest about how little is known.
        def build(entry)
          unmodelled = entry[:unmodelled] || {}
          required = pairs_for(entry[:required]).merge(untyped_pairs(unmodelled[:required]))
          optional = pairs_for(entry[:optional]).merge(untyped_pairs(unmodelled[:optional]))
          return nil if required.empty? && optional.empty?

          Rigor::Type::Combinator.hash_shape_of(
            required.merge(optional),
            required_keys: required.keys,
            optional_keys: optional.keys,
            extra_keys: :open
          )
        end

        # A key the schema declares but the scanner could not type still belongs in the shape, as
        # `untyped`.
        #
        # This costs nothing at a read and buys nothing at one either — measured: with and without these
        # entries, `payload[:address]`, `payload.fetch(:address)` and every other read infer identically,
        # because #249 made an undeclared key on an OPEN shape read as `untyped` rather than `nil`. What
        # it buys is the rendered shape, which is what hover and `dump_type` show: `{ email: String,
        # address: Dynamic[top], ... }` says the schema declares `address` and Rigor cannot type it, while
        # `{ email: String, ... }` is indistinguishable from a schema that never mentioned it — the
        # trailing `...` only ever means "keys beyond these are permitted".
        #
        # It was originally load-bearing for a different reason: before #249 a key outside the shape read
        # as `nil`, so dropping `required(:address).schema { … }` put a `call.undefined-method` on the next
        # line of correct code. That hazard is gone; the entries stay for the honesty of the rendering.
        def untyped_pairs(keys)
          (keys || []).to_h { |key| [key, Rigor::Type::Combinator.untyped] }
        end

        def pairs_for(rows)
          (rows || {}).each_with_object({}) do |(key, row), pairs|
            type = row_type(row)
            pairs[key] = type unless type.nil?
          end
        end

        def row_type(row)
          element = class_type(row[:type])
          return nil if element.nil?

          row[:list] ? Rigor::Type::Combinator.nominal_of("Array", type_args: [element]) : element
        end

        def class_type(class_name)
          return nil if class_name.nil? || class_name.empty?
          return Rigor::Type::Combinator.union(*BOOL_CLASSES.map { |c| Rigor::Type::Combinator.nominal_of(c) }) \
            if class_name == "TrueClass"

          Rigor::Type::Combinator.nominal_of(class_name)
        end

        # Renders `Foo` / `Foo::Bar` / `::Foo::Bar` as the `::`-joined String the table is keyed by.
        # Mirrors the helper rigor-sorbet's TypeTranslator and rigor-activerecord's ModelDiscoverer use.
        def constant_name(node)
          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode then constant_path_name(node)
          end
        end

        def constant_path_name(node)
          parent = node.parent
          name = node.name&.to_s
          return nil if name.nil?
          return name if parent.nil? # `::Foo` — the table keys are unrooted, so drop the leading `::`

          prefix = constant_name(parent)
          prefix.nil? ? nil : "#{prefix}::#{name}"
        end
      end
    end
  end
end
