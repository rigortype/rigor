# frozen_string_literal: true

require_relative "plugin/bundled_catalog"
require_relative "environment/lockfile_resolver"

module Rigor
  # ADR-96 WD2 — the plugin-gap advisory: a gem the project itself depends on that a bundled plugin declares
  # in `target_gems:`, with that plugin absent from `plugins:`.
  #
  # One home for a fact that ADR-96 found in four hand-maintained copies, none of which was the plugin.
  # `rigor doctor` and `rigor skill describe`'s project probe both route through here, so the two can no
  # longer disagree — they were byte-identical Rails tables by luck, not by construction.
  #
  # The advisory is deliberately advice, not activation: naming a plugin never loads it (ADR-96 Criterion 2),
  # and declining a plugin is a legitimate choice, which is why a gap is a warning and never a failure.
  module PluginGapAdvisory
    # One unenabled plugin and the depended-on gems that make it relevant.
    Gap = Data.define(:plugin_gem, :plugin_id, :locked_gems)

    # A gem whose whole point is to pull its constituents in. A Rails application's `Gemfile` says `rails`
    # and never `activerecord`, so a direct-dependency match alone would silence the entire Rails family for
    # the projects the advisory exists for. The table is explicit rather than derived: expanding whatever a
    # gem happens to resolve to is the transitive read this advisory is here to avoid, and the set of gems
    # that are genuinely umbrellas is small and known.
    UMBRELLA_GEMS = {
      "rails" => %w[
        actioncable actionmailer actionpack actiontext actionview activejob activemodel
        activerecord activestorage activesupport railties
      ].freeze
    }.freeze

    class << self
      # @param project_root — the directory whose `Gemfile.lock` and `plugins:` list are read.
      # @param plugins — the configuration's raw `plugins:` entries (String or Hash form).
      # @return the gaps, sorted by plugin gem name; empty when the project declares no dependency.
      def gaps(project_root:, plugins:)
        depended = depended_gems(project_root)
        return [] if depended.empty?

        listed = listed_plugin_names(plugins)
        Plugin::BundledCatalog.entries.filter_map do |entry|
          next if listed?(entry, listed)

          matched = entry.target_gems.select { |gem| depended.include?(gem) }
          next if matched.empty?

          Gap.new(plugin_gem: entry.gem_name, plugin_id: entry.plugin_id, locked_gems: matched.freeze)
        end.sort_by(&:plugin_gem)
      end

      # Whether the project enables no bundled plugin at all for the gems it depends on — ADR-96's preserved
      # `:fail` case, generalised off the Rails-only table it replaces. A project that enables *some* of the
      # matching plugins has made choices; one that enables none of them is unconfigured for its own stack.
      def unconfigured?(project_root:, plugins:)
        found = gaps(project_root: project_root, plugins: plugins)
        return false if found.empty?

        listed = listed_plugin_names(plugins)
        Plugin::BundledCatalog.entries.none? { |entry| listed?(entry, listed) }
      end

      private

      # The gems the project chose, which is the `DEPENDENCIES` section and never the resolved graph. A
      # transitive `minitest` / `i18n` / `ffi` is somebody else's dependency, and advising on it fires on
      # correct configuration — including, through {unconfigured?}, as a hard failure.
      def depended_gems(project_root)
        direct = Environment::LockfileResolver.direct_dependency_names(
          lockfile_path: nil, project_root: project_root
        )
        return direct if direct.empty?

        direct + direct.flat_map { |gem| UMBRELLA_GEMS.fetch(gem, []) }
      end

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
