# frozen_string_literal: true

module Rigor
  module Plugin
    class Actionpack < Rigor::Plugin::Base
      # Per-run frozen index of discovered controllers and the
      # methods each one defines. Phase 2 (filter-chain
      # validation) consults the index at every call site to
      # check that `before_action :name` references a method
      # that actually exists on the controller (or its parent,
      # following one level of inheritance — typically
      # `ApplicationController`).
      #
      # The structure is intentionally flat:
      #
      # - `entries` — `Hash{class_name => Entry}`. Each Entry
      #   carries the discovered method set + the parent class
      #   name (or `nil` for a controller that doesn't subclass
      #   another in the index, in which case Phase 2 only
      #   checks the controller's own methods).
      class ControllerIndex
        # `defined_methods` carries the discovered method names
        # (Symbols). Avoid `:methods` as a Data member because
        # it would shadow `Data#methods` and confuse
        # introspection.
        Entry = Data.define(:class_name, :defined_methods, :parent_class_name)

        attr_reader :entries

        def initialize(entries)
          @entries = entries.freeze
          freeze
        end

        # @return [Entry, nil]
        def find(class_name)
          @entries[class_name]
        end

        # Resolves the **effective** method set for a controller,
        # including methods inherited from its parent class
        # (one level only — Phase 2's deliberate simplification
        # per the roadmap). Methods defined on the controller
        # itself shadow parent-class entries.
        def effective_methods_for(class_name)
          entry = @entries[class_name]
          return [].freeze if entry.nil?

          parent_methods = if entry.parent_class_name
                             @entries[entry.parent_class_name]&.defined_methods || []
                           else
                             []
                           end
          (parent_methods + entry.defined_methods).uniq.freeze
        end

        def empty?
          @entries.empty?
        end

        def known?(class_name)
          @entries.key?(class_name)
        end

        def class_names
          @entries.keys
        end
      end
    end
  end
end
