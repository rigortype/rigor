# frozen_string_literal: true

require_relative "rbs_collection_discovery"

module Rigor
  class Environment
    # Stdlib libraries that `Environment.for_project` loads on top of RBS core
    # unless the caller passes an explicit `libraries:` array. Each entry MUST be a stdlib library name
    # accepted by `RBS::EnvironmentLoader#has_library?`; unknown libraries MUST fail-soft
    # (`RbsLoader#build_env` already filters through `has_library?`). The default set covers the common
    # stdlib surface a Ruby program is likely to import, plus the analyzer-adjacent gems shipping their own
    # RBS in this bundle (`prism`, `rbs`). The list below is the enumeration — no prose gloss restates a
    # subset of it, here or in `docs/internal-spec/inference-engine.md` § Environment Surface, because a
    # restated subset silently rots as entries are added. On hosts where one of these libraries is not
    # installed, the loader silently drops it.
    #
    # Callers MAY add to the default by passing `libraries: %w[csv ...]`; the explicit list is appended to
    # `DEFAULT_LIBRARIES` and de-duplicated. Callers that need a strictly RBS-core view MUST construct an
    # `RbsLoader` directly instead of going through `for_project`.
    #
    # ADR-87 WD4 — extracted to its own light file (no engine requires) so the boot-slimming hit probe can
    # reconstruct `Environment.for_project`'s merged library list — which feeds the run cache KEY's
    # `rbs.libraries` slot — WITHOUT building the RBS environment (or loading the inference engine).
    DEFAULT_LIBRARIES = %w[
      pathname optparse json yaml fileutils tempfile tmpdir
      stringio forwardable digest securerandom
      uri logger date
      pp delegate observable abbrev find tsort singleton
      shellwords benchmark base64 did_you_mean
      monitor mutex_m timeout
      open3 erb etc ipaddr bigdecimal bigdecimal-math
      prettyprint random-formatter time open-uri resolv
      csv pstore objspace io-console cgi cgi-escape
      strscan
      prism rbs
    ].freeze

    # The library list a run loads before its `RequiredFeatures` tokens: {DEFAULT_LIBRARIES}, then the
    # configured `libraries:`, then — issue #2946 — the `source: { type: stdlib }` entries of the run's
    # `rbs_collection.lock.yaml` ({RbsCollectionDiscovery.stdlib_library_names}), de-duplicated in that order.
    # `Environment.for_project` and the boot-slimming probe's `RunCacheKey.libraries_config_entries` both build
    # it here, so the cache key's `rbs.libraries` slot names the lockfile's libraries on both paths.
    def self.base_libraries(libraries, rbs_collection_lockfile:, rbs_collection_auto_detect:, root: Dir.pwd)
      collection_stdlib = RbsCollectionDiscovery.stdlib_library_names(
        lockfile_path: rbs_collection_lockfile, project_root: root, auto_detect: rbs_collection_auto_detect
      )
      (DEFAULT_LIBRARIES + libraries.map(&:to_s) + collection_stdlib).uniq
    end
  end
end
