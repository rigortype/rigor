# frozen_string_literal: true

module Rigor
  module Plugin
    # Which plugin ids the engine itself ships (ADR-103 WD6).
    #
    # WD6's trust ladder grants two things to a **first-party bundled** plugin and to nothing else: it may
    # open the effect-label root of the framework it models rather than one named after itself
    # (`rails.*`, not `activerecord.*`), and its `effect_attributions:` may carry `discharge: true`. Both
    # rest on the same fact — a bundled plugin's framework knowledge is versioned with the engine, reviewed
    # in this repository, and gated by `make check-plugins`, which is exactly the standing a gem's shipped
    # RBS has.
    #
    # The answer is **derived, never listed**: a plugin is first-party when the engine bundles the gem that
    # would register it, which is the same question {Loader.bundled_plugin_path} already answers when it
    # decides whether to require a plugin by its engine-anchored path or by gem name. Every bundled plugin
    # id equals its gem name minus the `rigor-` prefix (pinned by spec), so the id is enough to ask. A list
    # would be a second source of truth to keep in sync with `plugins/`, and the first drift would silently
    # demote a plugin's rows to the tainted lane.
    #
    # This is a trust *ladder*, not a sandbox. ADR-2 settles that plugins are trusted gems the user
    # selected and chooses documentation over forced isolation; a plugin determined to spoof a bundled id
    # is out of scope there and stays out of scope here. What the predicate buys is that an ordinary
    # third-party plugin cannot accidentally claim authority it was never granted.
    module FirstParty
      # The prefix a bundled plugin's gem name carries over its manifest id.
      GEM_PREFIX = "rigor-"

      @memo = {}

      class << self
        # Whether `id` names a plugin the engine bundles.
        #
        # Memoised: the answer is a `File.file?` on a path fixed for the process, and the effect surfaces
        # ask it once per plugin per run — but a plugin's own specs ask it far more often than that.
        def bundled?(id)
          key = id.to_s
          return false if key.empty?

          return @memo[key] if @memo.key?(key)

          # Required here rather than at the top of the file: {Loader} pulls in the plugin {Registry},
          # which pulls in {Manifest}, which asks this module the question — a `require` cycle that would
          # leave `Loader` undefined half-way through load. The require is idempotent and this method is
          # memoised, so it costs one `$LOADED_FEATURES` probe per process.
          require_relative "loader"
          @memo[key] = !Loader.bundled_plugin_path("#{GEM_PREFIX}#{key}").nil?
        end

        # Drops the memo. For specs that stub the engine root only.
        def reset!
          @memo = {}
        end
      end
    end
  end
end
