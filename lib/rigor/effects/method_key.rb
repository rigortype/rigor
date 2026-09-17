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
      # #393 — the prefix a template unit's key carries (`Plugin::TemplateUnit::KEY_PREFIX`, repeated here
      # rather than required so the effects layer keeps no dependency on the plugin layer; the two are
      # pinned equal by a spec).
      TEMPLATE_UNIT_PREFIX = "view:"

      module_function

      # @return `[owner, separator, selector]`, or nil when `key` is
      #   not a method key at all.
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

      # #393 — a template unit's key: `view:users/show.html`. Deliberately NOT a method key — a view has
      # no owner class and no selector — but {.split} cannot tell, because the format segment gives the
      # string a dot: `owner("view:users/show.html")` answers `"view:users/show"`, a class name no run
      # ever produced. Anything grouping keys by their envelope-bearing owner has to ask this first.
      def template_unit?(key)
        key.to_s.start_with?(TEMPLATE_UNIT_PREFIX)
      end

      # The name an `effects.envelopes:` entry selects a key by: the owner class for a method key, and the
      # unit key ITSELF for a template unit. A view is its own envelope subject — there is no class to
      # hang the bound on, and `Runner#effect_sources` already knows which file the key came from, which
      # is what a `match:` entry needs.
      def envelope_owner(key)
        template_unit?(key) ? key.to_s : owner(key)
      end
    end
  end
end
