# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class DryValidation < Rigor::Plugin::Base
      # Issue #137 slices 2/3 — recognises the `<Const>.new.call(...).to_h` call chain and builds the
      # per-contract `HashShape` from the entry {ContractScanner.scan_schema_blocks} collected.
      module ParamsShape
        module_function

        # The Contract constant `to_h_node`'s receiver chain, or nil when the chain isn't the recognised
        # `<Const>.new.call(...).to_h` form.
        #
        # Mirrors rigor-dry-schema's `ResultShape.schema_name` with one extra hop: a schema's `.call` is a
        # bare class method on the schema constant itself, but a Contract's `.call` is an INSTANCE method
        # (`NewUserContract.new.call(input)`), so the chain has to walk through `.new` first. Floor,
        # matching dry-schema's own posture: the contract must be named by a constant as written at the
        # call site. Reached through a local (`c = NewUserContract.new; c.call(x).to_h`) or a relative
        # constant path, the chain contributes nothing and `to_h` types per the RBS overlay's generic
        # `Hash[Symbol, untyped]` as it did before.
        def contract_name(to_h_node)
          return nil unless to_h_node.is_a?(Prism::CallNode) && to_h_node.name == :to_h
          return nil unless to_h_node.arguments.nil? && to_h_node.block.nil?

          call_node = to_h_node.receiver
          return nil unless call_node.is_a?(Prism::CallNode) && call_node.name == :call

          new_node = call_node.receiver
          return nil unless new_node.is_a?(Prism::CallNode) && new_node.name == :new
          return nil unless new_node.arguments.nil? && new_node.block.nil?

          constant_name(new_node.receiver)
        end

        # Delegates the entry -> HashShape build to rigor-dry-schema's own
        # {DrySchema::ResultShape.build} — the identical algorithm the entry was collected with (via
        # {ContractScanner.scan_schema_blocks}, which itself delegates to
        # {DrySchema::SchemaScanner.collect_schema_shape}). Only ever called once the caller has already
        # confirmed rigor-dry-schema is loaded.
        def build(entry)
          DrySchema::ResultShape.build(entry)
        end

        # Renders `Foo` / `Foo::Bar` / `::Foo::Bar` as the `::`-joined String {ContractScanner}'s table is
        # keyed by. Duplicated from rigor-dry-schema's identical helper rather than shared — five lines,
        # no dependency on anything ELSE in that plugin, and reusing it would need a `registered_for`
        # guard here too even though this leaf never touches dry-schema's own type/alias machinery.
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
