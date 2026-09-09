# frozen_string_literal: true

require_relative "plugin/bundled_catalog"
require_relative "environment/lockfile_resolver"

module Rigor
  # ADR-96 WD2 — the plugin-gap advisory: a gem in the project's `Gemfile.lock` that a bundled plugin
  # declares in `target_gems:`, with that plugin absent from `plugins:`.
  #
  # One home for a fact that ADR-96 found in four hand-maintained copies, none of which was the plugin.
  # `rigor doctor` and `rigor skill describe`'s project probe both route through here, so the two can no
  # longer disagree — they were byte-identical Rails tables by luck, not by construction.
  #
  # The advisory is deliberately advice, not activation: naming a plugin never loads it (ADR-96 Criterion 2),
  # and declining a plugin is a legitimate choice, which is why a gap is a warning and never a failure.
  module PluginGapAdvisory
    # One unenabled plugin and the locked gems that make it relevant.
    Gap = Data.define(:plugin_gem, :plugin_id, :locked_gems)

    class << self
      # @param project_root — the directory whose `Gemfile.lock` and `plugins:` list are read.
      # @param plugins — the configuration's raw `plugins:` entries (String or Hash form).
      # @return the gaps, sorted by plugin gem name; empty when the project has no lockfile.
      def gaps(project_root:, plugins:)
        locked = Environment::LockfileResolver.locked_gems(lockfile_path: nil, project_root: project_root)
        return [] if locked.empty?

        listed = listed_plugin_names(plugins)
        Plugin::BundledCatalog.entries.filter_map do |entry|
          next if listed?(entry, listed)

          matched = entry.target_gems.select { |gem| locked.key?(gem) }
          next if matched.empty?

          Gap.new(plugin_gem: entry.gem_name, plugin_id: entry.plugin_id, locked_gems: matched.freeze)
        end.sort_by(&:plugin_gem)
      end

      # Whether the project enables no bundled plugin at all for the gems it locks — ADR-96's preserved
      # `:fail` case, generalised off the Rails-only table it replaces. A project that enables *some* of the
      # matching plugins has made choices; one that enables none of them is unconfigured for its own stack.
      def unconfigured?(project_root:, plugins:)
        found = gaps(project_root: project_root, plugins: plugins)
        return false if found.empty?

        listed = listed_plugin_names(plugins)
        Plugin::BundledCatalog.entries.none? { |entry| listed?(entry, listed) }
      end

      private

      # Both spellings a `plugins:` entry may use for the same plugin — the gem name and the manifest id.
      # An `enabled: false` entry still counts as naming it: the user has demonstrably found the plugin, so
      # advising them to add what is already there would be worse than staying quiet.
      def listed_plugin_names(plugins)
        Array(plugins).flat_map do |raw|
          case raw
          when String then [raw]
          when Hash
            keyed = raw.to_h { |key, value| [key.to_s, value] }
            [keyed["gem"], keyed["id"]].compact.map(&:to_s)
          else []
          end
        end.to_set
      end

      def listed?(entry, listed)
        listed.include?(entry.gem_name) || listed.include?(entry.plugin_id)
      end
    end
  end
end
