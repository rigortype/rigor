# frozen_string_literal: true

module Rigor
  class Environment
    # Slice A stdlib expansion. Stdlib libraries that `Environment.for_project` loads on top of RBS core
    # unless the caller passes an explicit `libraries:` array. Each entry MUST be a stdlib library name
    # accepted by `RBS::EnvironmentLoader#has_library?`; unknown libraries MUST fail-soft
    # (`RbsLoader#build_env` already filters through `has_library?`). The default set covers the common
    # stdlib surface a Ruby program is likely to import (`pathname`, `optparse`, `json`, `yaml`, `fileutils`,
    # `tempfile`, `uri`, `logger`, `date`) plus the analyzer-adjacent gems shipping their own RBS in this
    # bundle (`prism`, `rbs`). On hosts where one of these libraries is not installed, the loader silently
    # drops it.
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
  end
end
