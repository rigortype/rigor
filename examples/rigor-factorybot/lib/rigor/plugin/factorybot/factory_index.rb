# frozen_string_literal: true

module Rigor
  module Plugin
    class Factorybot < Rigor::Plugin::Base
      # Per-run frozen index of discovered FactoryBot factories
      # and the attribute keys each declares. Phase 1 (a) keys
      # only the **literal symbol/string** factory name + the
      # **literal symbol** attribute names; sequences,
      # parent/child relationships, traits, and dynamically-
      # named factories ship behind later slices.
      #
      # The structure is intentionally flat: one entry per
      # factory name. Attribute lists deduplicate.
      class FactoryIndex
        Entry = Data.define(:name, :attribute_names)

        attr_reader :entries

        def initialize(entries)
          @entries = entries.freeze
          freeze
        end

        # @return [Entry, nil]
        def find(factory_name)
          @entries[factory_name.to_s]
        end

        def known?(factory_name)
          @entries.key?(factory_name.to_s)
        end

        def names
          @entries.keys
        end

        def empty?
          @entries.empty?
        end
      end
    end
  end
end
