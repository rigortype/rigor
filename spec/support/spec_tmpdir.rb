# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Temp-directory lifetime for the spec suite (issue #330).
#
# The suite used to leave ~25 directories / ~86 MB behind per `make test`, and because nothing ever reclaimed
# them the residue accumulated across sessions until a run hit `Errno::ENOSPC`. The damage is not the disk: under
# `ENOSPC` the failures surface as `Dir.mktmpdir` / `Dir.chdir` / `File.write` errors scattered across specs that
# have nothing to do with the change under test, so they read as unrelated flake — and in a mutation census a
# spec that errors out scores as a *non-kill*, so the leak can fabricate survivors.
#
# Two things live here.
#
# 1. {.install!} points `ENV["TMPDIR"]` at a private {ROOT} for the rest of the process. Every `Dir.mktmpdir` /
#    `Tempfile` in this rspec process, in anything it forks, and in anything it shells out to therefore lands
#    inside one directory this process owns. That is what makes the residue check below free of false positives:
#    `make test-binpacker` runs many rspec processes against a single system temp dir, so "entries that appeared
#    while I ran" would otherwise count a sibling worker's live directories as this worker's leak.
# 2. {.suite_lifetime} is for the handful of directories whose lifetime genuinely is the spec *process* — the
#    process-wide caches in `RunnerHelpers` / `PluginHelpers` and the one-per-file environment root in
#    `fold_runtime_parity_spec`. They have no block to close and no example to hang an `after` hook on, so they
#    are registered here and released by {.release_registered!} from the single `after(:suite)` hook in
#    `spec_helper.rb`. Everything else — anything scoped to an example or narrower — belongs in a `Dir.mktmpdir`
#    block or an `after` hook at its own call site; this module is deliberately not a sweeper.
#
# {.discard!} is pid-guarded: a forked child that exits normally must not remove the parent's root, and the
# fork paths that matter (`Inference::ForkMap`, the runner pool coordinators, `Plugin::Isolation`) use `exit!`
# and never reach an `at_exit` at all.
module SpecTmpdir
  # The private temp root, created in the system temp dir *before* the redirect so it is the only entry this
  # process contributes there. Removed wholesale by {.discard!} however the process ends.
  ROOT = Dir.mktmpdir("rigor-spec-run-")

  # The pid that owns {ROOT}. Anything else observing this constant is a forked child.
  OWNER_PID = Process.pid

  class << self
    # Redirects the process (and its children) into {ROOT} and arranges for {ROOT} to be removed even when the
    # run aborts before `after(:suite)` — a `--fail-fast` bail, a load error, an interrupt.
    def install!
      ENV["TMPDIR"] = ROOT
      at_exit { discard! }
    end

    # A temp directory whose lifetime is the whole spec process. Released by {.release_registered!}.
    #
    # @param prefix [String] `Dir.mktmpdir` prefix, kept descriptive so a residue report names its owner.
    # @return [String] the directory path.
    def suite_lifetime(prefix)
      dir = Dir.mktmpdir(prefix)
      registry << dir
      dir
    end

    # Removes every directory handed out by {.suite_lifetime}. Idempotent.
    def release_registered!
      registry.each { |dir| FileUtils.rm_rf(dir) }
      registry.clear
    end

    # What is still inside {ROOT}. Empty is the contract; a non-empty answer names the leaking prefixes.
    #
    # @return [Array<String>] basenames.
    def residue
      return [] unless File.directory?(ROOT)

      Dir.children(ROOT).sort
    end

    # Removes {ROOT} and everything under it. A no-op off the owning process.
    def discard!
      return unless Process.pid == OWNER_PID

      FileUtils.rm_rf(ROOT)
    end

    private

    def registry
      @registry ||= []
    end
  end
end
