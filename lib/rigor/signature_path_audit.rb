# frozen_string_literal: true

module Rigor
  # Classifies each configured `signature_paths:` entry by what it actually contributes to
  # the RBS environment, so a caller can warn when a configured path resolves to nothing.
  #
  # The failure this guards against is silent. {Environment::RbsLoader} `add`s a
  # `signature_paths:` entry only when `path.directory?`, and only the `.rbs` files under it
  # carry signatures — so a typo'd or moved path (or a directory holding no `.rbs`) loads
  # zero signatures with no trace on stderr or in the run summary. The downstream symptom is
  # the most authoritative diagnostics: every call into the extensions the missing RBS was
  # meant to describe fires `call.undefined-method` at `evidence_tier: high`. A one-character
  # path typo can manufacture hundreds of plausible-looking false positives; surfacing the
  # empty entry makes the real cause visible.
  #
  # The audit deliberately mirrors the loader's own acceptance test (`path.directory?` + a
  # recursive `**/*.rbs` glob) so a `:ok` verdict means the loader did load from it and a
  # warning means it did not.
  #
  # {.bundled_plugin_routes} answers the mirror-image question — an entry that loads too
  # *little of the plugin*, rather than nothing at all. See its own comment.
  module SignaturePathAudit
    # The `plugins/` tree of the engine running this code, anchored from THIS file
    # (`<root>/lib/rigor/signature_path_audit.rb`) so a git checkout and an installed
    # `rigortype` gem answer identically — the anchor {Plugin::Loader::ENGINE_ROOT} uses, for
    # the reason it documents.
    #
    # Deliberately re-derived rather than read off `Plugin::Loader`: ADR-87 WD4 keeps this
    # file, which every `rigor check` loads before the cache probe, off the plugin
    # subsystem's require graph — and that graph is order-dependent (`plugin/registry.rb`
    # resolves `NodeRuleWalk` at load, which only `rigor/plugin.rb` has required by then), so
    # requiring the loader from here fails outright. `signature_path_audit_spec` pins the two
    # anchors equal, and pins this discovery against `Loader.bundled_plugin_sig_path`, so the
    # duplication cannot drift unnoticed.
    BUNDLED_PLUGINS_ROOT = File.expand_path("../../plugins", __dir__)

    # One configured `signature_paths:` entry's resolution status.
    #
    # `status` is one of:
    # - `:ok`            — a directory containing at least one `.rbs`.
    # - `:missing`       — the path does not exist.
    # - `:not_directory` — the path exists but is not a directory (the loader only `add`s
    #   directories, so a `.rbs` file passed directly is silently ignored).
    # - `:empty`         — a directory with no `.rbs` file (recursive).
    Entry = Data.define(:path, :status, :rbs_file_count) do
      def ok?
        status == :ok
      end

      def warning?
        !ok?
      end

      # One-line, human-facing reason. The wording matches the loader's actual behaviour
      # ("loaded nothing from it") rather than the filesystem error, so the message points
      # at the consequence.
      def message
        case status
        when :missing
          "signature_paths: #{path.inspect} does not exist (no signatures loaded from it)"
        when :not_directory
          "signature_paths: #{path.inspect} is not a directory (no signatures loaded from it)"
        when :empty
          "signature_paths: #{path.inspect} matched 0 signature files"
        else
          "signature_paths: #{path.inspect} loaded #{rbs_file_count} signature file(s)"
        end
      end

      def to_h
        { "path" => path, "status" => status.to_s, "rbs_file_count" => rbs_file_count, "message" => message }
      end
    end

    # Audits each configured entry. `signature_paths` is the {Configuration#signature_paths}
    # array (absolute paths, already resolved against the config file's directory). Pass
    # `nil` — the unset default, where Rigor auto-detects `<root>/sig` — to get an empty
    # result: an absent auto-detected `sig/` is a normal setup, not a misconfiguration, so it
    # is never audited.
    def self.audit(signature_paths)
      Array(signature_paths).map { |path| classify(path.to_s) }
    end

    # The subset of {audit} that resolved to nothing — the entries worth warning about.
    def self.warnings(signature_paths)
      audit(signature_paths).select(&:warning?)
    end

    def self.classify(path)
      return Entry.new(path: path, status: :missing, rbs_file_count: 0) unless File.exist?(path)
      return Entry.new(path: path, status: :not_directory, rbs_file_count: 0) unless File.directory?(path)

      count = Dir.glob(File.join(path, "**", "*.rbs")).size
      Entry.new(path: path, status: count.zero? ? :empty : :ok, rbs_file_count: count)
    end

    # One configured entry that reaches the `sig/` of a plugin THIS engine bundles, while
    # `plugins:` never names that plugin (issue #697).
    BundledPluginRoute = Data.define(:path, :gem) do
      # Names the plugin and the one edit that fixes it. The consequence is spelled out
      # because the symptom the user actually sees is `call.undefined-method` on code that
      # runs — nothing in that row points back at the `signature_paths:` line.
      def message
        "signature_paths: #{path.inspect} loads the signatures of the bundled plugin #{gem.inspect}, " \
          "which `plugins:` does not name — so the plugin's manifest never loads, and the classes it " \
          "declares only partially on purpose (ADR-26 `open_receivers:`) are read as complete, which " \
          "reports methods your code really defines as undefined. " \
          "Add #{gem.inspect} to `plugins:` instead of naming its `sig/` in `signature_paths:`."
      end

      def to_h
        { "path" => path, "gem" => gem, "message" => message }
      end
    end

    # The mirror image of {.warnings}: an entry the loader reads perfectly well, which
    # nevertheless leaves the user worse off than not configuring it.
    #
    # A bundled plugin ships two halves that only work together — the RBS under its `sig/`,
    # and the manifest that says which of those declarations are deliberately partial
    # (ADR-26 `open_receivers:`). `plugins:` loads both; `signature_paths:` loads only the
    # first, and the partial declarations then read as complete, so a scope the application
    # really defines draws `call.undefined-method`. This is a configuration mistake with no
    # visible cause, so it is reported here rather than fixed by teaching the check rules yet
    # another route to the same protection — which is [#660](https://github.com/rigortype/rigor/issues/660)'s
    # question to settle, not this warning's.
    #
    # **What it asks is what the entry LOADS, not what it looks like**, exactly as
    # `Environment::RbsLoader.bundled_overlay_twin_signatures_loaded?` does for the overlay
    # stand-down: both sides are `File.realpath`'d and matched against the plugin's actual
    # `.rbs` files, so a symlink or a case-variant spelling answers the same as the directory
    # itself, and an entry naming a file (or a directory that does not exist) — which the
    # loader reads nothing from — matches nothing. The two are not single-homed because the
    # overlay-side predicate lives on the RBS loader, and ADR-87 WD4 keeps this file, which
    # every `rigor check` loads before the cache probe, off the engine's require graph.
    #
    # @param signature_paths — {Configuration#signature_paths}; `nil` (the unset default,
    #   where Rigor auto-detects `<root>/sig`) is never audited.
    # @param plugins — the raw {Configuration#plugins} list.
    def self.bundled_plugin_routes(signature_paths, plugins = [])
      entries = resolved_entries(signature_paths)
      return [] if entries.empty?

      root = canonical_path(BUNDLED_PLUGINS_ROOT)
      return [] if root.nil? || entries.none? { |(_, dir)| overlapping?(dir, root) }

      listed = listed_plugin_names(plugins)
      bundled_plugin_sig_dirs.reject { |gem, _| listed?(gem, listed) }.flat_map do |gem, sig_dir|
        files = canonical_rbs_files(sig_dir)
        next [] if files.empty?

        entries.filter_map do |(entry, dir)|
          BundledPluginRoute.new(path: entry, gem: gem) if files.any? { |file| under?(file, dir) }
        end
      end
    end

    # `[entry as configured, canonical directory]` for every entry the loader would read from.
    def self.resolved_entries(signature_paths)
      Array(signature_paths).filter_map do |entry|
        dir = canonical_path(entry.to_s)
        [entry.to_s, dir] if dir && File.directory?(dir)
      end
    end
    private_class_method :resolved_entries

    # Gem name of every plugin the engine bundles that ships signatures, to its `sig/`.
    # Derived from the `plugins/` tree rather than listed, for {Plugin::FirstParty}'s reason:
    # a list would be a second source of truth, and its first drift would silently stop
    # warning about the plugin that drifted.
    def self.bundled_plugin_sig_dirs
      return {} unless File.directory?(BUNDLED_PLUGINS_ROOT)

      Dir.children(BUNDLED_PLUGINS_ROOT).sort.filter_map do |gem|
        sig = File.join(BUNDLED_PLUGINS_ROOT, gem, "sig")
        [gem, sig] if File.directory?(sig)
      end.to_h
    end

    # Every name a `plugins:` entry puts on the record, in both the bare-string and the
    # `gem:` / `id:` hash forms. An `enabled: false` entry counts as named even though it
    # loads nothing: the user has demonstrably found the plugin, and telling them to add what
    # is already there would be worse than staying quiet. Under-warning is this module's
    # standing FP-safe direction.
    def self.listed_plugin_names(plugins)
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
    private_class_method :listed_plugin_names

    # A bundled plugin's manifest id is its gem name minus the `rigor-` prefix, and `plugins:`
    # accepts either spelling as `id:`, so both count as naming it.
    def self.listed?(gem, listed)
      require_relative "plugin/first_party"
      listed.include?(gem) || listed.include?(gem.delete_prefix(Plugin::FirstParty::GEM_PREFIX))
    end
    private_class_method :listed?

    def self.canonical_rbs_files(dir)
      Dir.glob(File.join(dir, "**", "*.rbs")).filter_map { |file| canonical_path(file) }
    end
    private_class_method :canonical_rbs_files

    # `File.realpath`, not `File.expand_path`: it resolves symlinks and, on a case-folding
    # filesystem, the on-disk spelling. It raises for a path that does not exist, which is
    # the answer wanted here — a path the loader cannot read is not a route to anything.
    def self.canonical_path(path)
      File.realpath(path.to_s)
    rescue SystemCallError
      nil
    end
    private_class_method :canonical_path

    def self.under?(path, dir)
      path.start_with?("#{dir}#{File::SEPARATOR}")
    end
    private_class_method :under?

    # Whether the two directories could possibly share a file. The cheap prune that keeps the
    # per-plugin globs off every run whose `signature_paths:` point at the project's own tree.
    def self.overlapping?(one, other)
      one == other || under?(one, other) || under?(other, one)
    end
    private_class_method :overlapping?
  end
end
