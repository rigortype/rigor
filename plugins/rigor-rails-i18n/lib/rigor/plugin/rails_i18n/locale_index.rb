# frozen_string_literal: true

module Rigor
  module Plugin
    class RailsI18n < Rigor::Plugin::Base
      # Frozen catalogue of every dotted key discovered across
      # all loaded locale files. Each entry tracks the locales
      # the key appears in and, for each locale, the set of
      # `%{var}` interpolation placeholders observed in the
      # leaf string.
      #
      # The catalogue is intentionally lossy: it only records
      # the *presence* of each key per locale and the
      # placeholder names. The actual translated values are
      # not retained — the analyzer doesn't need them and
      # keeping them would bloat the cache slice.
      class LocaleIndex
        # `placeholders` is a Hash: `locale_name => Set<String>`.
        # `array_value` is true when at least one locale's leaf
        # is an Array (used by `l(time, format:)` and similar).
        # `value_kinds` is a Hash: `locale_name => Symbol`
        # (`:string` / `:array` / `:hash`).
        Entry = Data.define(:dotted_key, :placeholders, :value_kinds) do
          def locales
            placeholders.keys
          end

          def in_locale?(locale)
            placeholders.key?(locale.to_s)
          end

          def required_placeholders_for(locale)
            placeholders.fetch(locale.to_s) { Set.new }
          end

          # Union of placeholder names across all known
          # locales — used by the analyzer when no specific
          # locale is in scope.
          def all_placeholders
            placeholders.values.reduce(Set.new) { |acc, set| acc | set }
          end
        end

        attr_reader :entries, :locales

        # @param entries [Array<Entry>]
        # @param locales [Array<String>] all locale names
        #   that contributed at least one key.
        def initialize(entries, locales:)
          @entries = entries.freeze
          @locales = locales.dup.freeze
          @by_key = entries.to_h { |e| [e.dotted_key, e] }.freeze
          freeze
        end

        # @return [Entry, nil]
        def find(dotted_key)
          @by_key[dotted_key.to_s]
        end

        def known?(dotted_key)
          @by_key.key?(dotted_key.to_s)
        end

        def empty?
          @entries.empty?
        end

        def size
          @entries.size
        end

        # All known dotted keys, sorted for stable did-you-mean
        # output.
        def keys
          @by_key.keys.sort
        end

        # Returns the locales (set of strings) in which a key
        # is *missing*, given the configured locale list.
        def missing_locales_for(dotted_key, configured_locales:)
          entry = find(dotted_key)
          return configured_locales.to_set if entry.nil?

          configured_locales.to_set - entry.locales.to_set
        end
      end
    end
  end
end
