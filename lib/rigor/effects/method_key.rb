# frozen_string_literal: true

module Rigor
  module Effects
    # The spelling of an effect unit's key, in one place (ADR-103 WD14).
    #
    # `Owner#instance_method`, `Owner.singleton_method`, `<toplevel>#bare_def`. The separator is the FIRST
    # `#` or `.` in the string, which is what makes `Net::HTTP.get` split at the dot rather than inside the
    # namespace — a namespace carries `::`, never a bare dot, and a selector carries neither.
    #
    # This module exists because the split is now written on both sides of a contract: the scanner spells a
    # key, and `effects.attribution:` in `.rigor.yml` names one. A key the loader accepts and the scanner
    # would never produce is a table that silently matches nothing.
    module MethodKey
      module_function

      # @rbs return: [String, String, String]? --
      #   `[owner, separator, selector]`, or nil when `key` is not a method key at all.
      def split(key)
        text = key.to_s
        index = text.index("#") || text.index(".")
        return nil if index.nil? || index.zero? || index == text.length - 1

        [text[0, index], text[index], text[(index + 1)..]]
      end

      def valid?(key)
        parts = split(key)
        return false if parts.nil?

        parts.none? { |part| part.match?(/\s/) }
      end

      # The owner half, or nil. What `keys_by_class`-shaped groupings ask for.
      def owner(key)
        split(key)&.first
      end
    end
  end
end
