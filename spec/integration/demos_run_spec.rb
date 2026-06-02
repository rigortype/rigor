# frozen_string_literal: true

require "spec_helper"
require "open3"
require "json"
require "rbconfig"

# Behavioural guard (option B): EVERY bundled plugin / example `demo/`
# project must run end-to-end under the real `rigor check` CLI without
# crashing. `all_plugins_load_spec.rb` proves each plugin *loads*; this
# proves each shipped demo — the runnable artefact a user copies — still
# *analyses* cleanly.
#
# ## Why a subprocess (and why that is the CI-reliable choice)
#
# Each demo is run via a fresh `ruby exe/rigor check` subprocess rather
# than in-process, for two reasons that together make it deterministic
# in GitHub Actions:
#
#   1. **Fresh process = real plugin load.** The Rigor plugin loader
#      keys "did this gem register a plugin?" on the registry diff across
#      its `require`. In one long-lived test process that `require` is
#      cached after the first spec touches the gem, so an in-process run
#      could silently fail-soft (plugin not re-registered) and test
#      nothing. A subprocess loads every plugin for real, exactly as a
#      user's `rigor check` does.
#   2. **No locale/encoding surface in the assertion.** Demo diagnostics
#      contain non-ASCII (e.g. the `—` in statesman's messages). Ruby's
#      JSON generator emits raw UTF-8 under a UTF-8 locale and ASCII
#      `\uXXXX` escapes under a C locale, so `rigor` itself never crashes
#      on output regardless of `LANG` (verified under `LC_ALL=C`). The
#      test reads the captured bytes back as UTF-8 explicitly, so the
#      assertion is locale-independent on the CI runner too.
#
# The subprocess inherits the parent's environment — under
# `make test-parallel` (which CI runs) that is a `bundle exec` context,
# so `RUBYOPT=-rbundler/setup` carries the gem environment into the
# child. `--no-cache` keeps each run hermetic (no cache writes into the
# repo tree, no stale-cache cross-run coupling).
#
# A "crash" is any of: a terminating signal (segfault), a non
# {0 (clean), 1 (diagnostics found)} exit (e.g. 64 usage error or an
# uncaught-exception exit), a Ruby backtrace on stderr, or stdout that
# is not the expected JSON report. A demo that merely *reports*
# diagnostics (exit 1) is working, not crashing.

DEMO_REPO_ROOT = File.expand_path("../..", __dir__)
DEMO_RIGOR_EXE = File.join(DEMO_REPO_ROOT, "exe", "rigor")
DEMO_DIRS = (
  Dir[File.join(DEMO_REPO_ROOT, "plugins", "*", "demo")] +
  Dir[File.join(DEMO_REPO_ROOT, "examples", "*", "demo")]
).select { |dir| File.directory?(dir) }.sort.freeze

RSpec.describe "bundled plugin / example demos all run (no-crash guard)" do
  # Run `rigor check` over a demo dir in a fresh subprocess; return
  # [stdout(UTF-8), stderr(UTF-8), Process::Status].
  def run_demo_check(demo_dir)
    out, err, status = Open3.capture3(
      RbConfig.ruby, DEMO_RIGOR_EXE, "check", "--no-cache", "--format", "json",
      chdir: demo_dir
    )
    [out.dup.force_encoding("UTF-8"), err.dup.force_encoding("UTF-8"), status]
  end

  def demo_label(demo_dir)
    demo_dir.sub("#{DEMO_REPO_ROOT}/", "")
  end

  it "finds demo projects to exercise" do
    # Guards the glob itself: a path regression that found no demos would
    # otherwise make every generated example silently vanish.
    expect(DEMO_DIRS).not_to be_empty
  end

  DEMO_DIRS.each do |demo_dir|
    describe demo_dir.sub("#{DEMO_REPO_ROOT}/", "") do
      it "runs `rigor check` end-to-end without crashing" do
        label = demo_label(demo_dir)
        stdout, stderr, status = run_demo_check(demo_dir)

        expect(status.signaled?).to be(false), "rigor was killed by a signal on #{label} (likely a native crash)"
        expect(stderr).not_to match(/\.rb:\d+:in /), "rigor emitted a Ruby backtrace on #{label}:\n#{stderr}"
        expect([0, 1]).to(
          include(status.exitstatus),
          "rigor exited #{status.exitstatus} on #{label} (expected 0=clean or 1=diagnostics):\n#{stderr}"
        )

        report =
          begin
            JSON.parse(stdout)
          rescue JSON::ParserError => e
            raise "rigor did not emit a JSON report on #{label} (#{e.message}); stdout head:\n#{stdout[0, 300]}"
          end
        expect(report).to be_a(Hash)
        expect(report).to have_key("diagnostics")
        expect(report["diagnostics"]).to be_an(Array)
      end
    end
  end
end
