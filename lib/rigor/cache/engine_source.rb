# frozen_string_literal: true

require "digest"

require_relative "../version"

module Rigor
  module Cache
    # Issue #285 — the identity of the ENGINE'S OWN SOURCE, as a cache-key slot.
    #
    # Every Rigor cache whose value is a function of what the analyzer COMPUTES (the ADR-45 run-result
    # cache, the #134 mutation-result cache) keys on `Rigor::VERSION`. For a gem installed from RubyGems
    # that is exact — the version pins the bytes. For anyone running an edited working tree it is not, and
    # the failure is invisible: a warm `rigor check` replays the pre-edit diagnostics verbatim, so a
    # before/after measurement of an engine change reports `0 new, 0 gone` no matter what the change does.
    # That shape of false zero survived into #152's FP evaluation before it was caught.
    #
    # ## The two regimes
    #
    # {.identity} answers `nil` for a tree whose identity `Rigor::VERSION` already fixes — a RubyGems
    # install, recognised by its `<gem_home>/gems/rigortype-<VERSION>` directory layout. The caller then
    # adds NO slot, so a released gem's cache key is byte-identical to the one it had before this module
    # existed and pays not one syscall for it. Everything else — a contributor's checkout, a `bundle add
    # rigor, github:` clone (where two commits share one `Rigor::VERSION`), a `path:` gem — is treated as
    # mutable and gets a content digest of the engine's source tree.
    #
    # The predicate is deliberately POSITIVE about being pinned, so every case it fails to recognise lands
    # on the safe side: an unrecognised release pays one directory walk and one extra cache generation,
    # while an unrecognised checkout would have served a stale answer.
    #
    # ## Why a content digest and not a stat tuple
    #
    # A `(size, mtime, ctime, inode)` walk is ~3× cheaper (measured: 5.4 ms vs 17 ms over this repo's 539
    # engine files), and ADR-87 WD1 trusts exactly that tuple for FRESHNESS. It cannot be used here:
    # {Descriptor::FileEntry} states the rule directly — a stat tuple carries machine-local, per-run
    # nondeterministic data and MUST NOT enter a descriptor used as a cache KEY. On the freshness side a
    # moved tuple falls back to the recorded digest, so a fresh checkout of unchanged content still
    # validates; a KEY has no such fallback, so keying on stat would make every CI run and every branch
    # switch a total miss for the `github:`-tracking users this module exists to protect.
    #
    # ## Never a wrong hit
    #
    # A mutable tree whose digest cannot be computed raises {Unavailable} rather than answering `nil`.
    # Both callers already rescue a malformed key into "no cache for this run", which is the only sound
    # reading: falling back to the version-only key would restore precisely the blind spot being fixed.
    module EngineSource
      # Raised when the tree is not version-pinned AND its source cannot be digested. Deliberately not
      # rescued in this module — see the class doc's last paragraph.
      class Unavailable < StandardError; end

      # The RubyGems package name. `<name>-<version>` is the install directory layout {.version_pinned?}
      # recognises; the constant is not read from the gemspec because this file loads on the boot-slimming
      # probe path, which must not touch RubyGems' specification machinery.
      GEM_NAME = "rigortype"

      # Engine source, relative to the gem root. `plugins/` ships inside the same gem and its recognisers
      # move diagnostics exactly as `lib/` does, so an edit there must invalidate too; `examples/`,
      # `apps/` and `tool/` are not loaded by an analysis and stay out.
      SOURCE_DIRECTORIES = %w[lib plugins].freeze

      # The one directory whose absence means "this is not an engine tree". `plugins/` may legitimately be
      # missing (a slimmed install contributes nothing); a missing `lib/` would silently shrink the digest
      # to whatever else happened to be there, which is exactly the weakening this module forbids.
      REQUIRED_DIRECTORY = "lib"

      module_function

      # @return [String] the gem root — the directory holding `lib/`, three levels above this file.
      def root
        @root ||= File.expand_path("../../..", __dir__)
      end

      # @param root [String] the gem root, defaulted through {.root} so a spec can relocate the tree.
      # @return [String, nil] a digest identifying the engine's current source, or nil when the tree is
      #   version-pinned and the caller should add no slot at all.
      # @raise [Unavailable] when a mutable tree's source cannot be read.
      def identity(root = self.root)
        return nil if version_pinned?(root)

        digest_tree(root)
      end

      # True when `Rigor::VERSION` already pins this tree's bytes: an immutable RubyGems install, laid out
      # as `…/gems/rigortype-<VERSION>`. The `.git` probe is the belt to that braces — a working tree that
      # somehow occupies a release-shaped path is still a working tree.
      def version_pinned?(root)
        return false unless File.basename(root) == "#{GEM_NAME}-#{Rigor::VERSION}"
        return false unless File.basename(File.dirname(root)) == "gems"

        !File.exist?(File.join(root, ".git"))
      end

      # A SHA-256 over every engine `.rb` file: its ROOT-RELATIVE path (so the digest survives moving or
      # re-cloning the checkout) followed by its bytes, in sorted path order.
      #
      # Not memoised: {Analysis::RunCacheKey.descriptor} is reached at most twice per process (the
      # boot-slimming probe, then the runner on a miss), so a memo would save one walk on the path that
      # already pays for a full analysis while adding state that a fork-pool worker would inherit.
      def digest_tree(root)
        unless File.directory?(File.join(root, REQUIRED_DIRECTORY))
          raise Unavailable, "#{root} has no #{REQUIRED_DIRECTORY}/ to identify the engine by"
        end

        digest = Digest::SHA256.new
        prefix = "#{root}#{File::SEPARATOR}"
        count = 0
        source_files(root).each do |path|
          digest << path.delete_prefix(prefix) << "\0"
          digest.file(path)
          count += 1
        end
        raise Unavailable, "no engine source found under #{root}" if count.zero?

        digest.hexdigest
      rescue SystemCallError, IOError => e
        raise Unavailable, "engine source under #{root} could not be read: #{e.message}"
      end

      # Sorted absolute paths of every engine `.rb` file, across the directories that exist.
      def source_files(root)
        SOURCE_DIRECTORIES.flat_map do |relative|
          directory = File.join(root, relative)
          File.directory?(directory) ? Dir.glob(File.join(directory, "**", "*.rb")) : []
        end.sort
      end
    end
  end
end
