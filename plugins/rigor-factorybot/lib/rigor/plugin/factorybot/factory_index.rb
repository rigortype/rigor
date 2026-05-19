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
      # v0.2.0 (Pillar 2 Slice 3) adds `model_class` to each
      # entry — the inferred or explicit class the factory
      # builds. Resolved from:
      #
      #   1. An explicit `factory :user, class: User do`
      #      keyword option (ConstantReadNode / ConstantPathNode
      #      value).
      #   2. An explicit `factory :user, class: "User"` keyword
      #      option (String value, supports `"Admin::User"`).
      #   3. Fallback: inflected from the factory name —
      #      `:user` → `"User"`, `:admin_user` → `"AdminUser"`.
      #
      # The structure is intentionally flat: one entry per
      # factory name. Attribute lists deduplicate.
      class FactoryIndex
        Entry = Data.define(:name, :attribute_names, :model_class)

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
