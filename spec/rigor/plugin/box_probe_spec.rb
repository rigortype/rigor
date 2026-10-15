# frozen_string_literal: true

require "spec_helper"
require "rigor/plugin/box_probe"
require "open3"
require "tmpdir"
require "fileutils"
require "stringio"

# The launcher's pre-exec check that the running Ruby can host Rigor under `RUBY_BOX=1` (Ruby Bug #22260). The
# classification examples drive the real spawn + pipe path through stand-in `ruby` executables, so each verdict is
# reached the way the launcher reaches it; the last group runs the probe against the Ruby running this suite.
released_without_fix = RUBY_PATCHLEVEL >= 0 &&
                       Gem::Version.new(RUBY_VERSION).between?(Gem::Version.new("4.0.0"), Gem::Version.new("4.0.7"))

RSpec.describe Rigor::Plugin::BoxProbe do
  def fake_ruby(dir, body)
    path = File.join(dir, "ruby")
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, path)
    path
  end

  # The stand-ins are `/bin/sh` scripts; CI is Linux-only.
  describe ".unsupported_reason", unless: Gem.win_platform? do
    it "passes a Ruby whose child prints the reproducer's correct answer" do
      Dir.mktmpdir do |dir|
        expect(described_class.unsupported_reason(fake_ruby(dir, "printf '(3/4)'"))).to be_nil
      end
    end

    it "names the missing feature when the child reports Ruby::Box inactive" do
      Dir.mktmpdir do |dir|
        expect(described_class.unsupported_reason(fake_ruby(dir, "exit 2")))
          .to include("Ruby::Box is not available")
      end
    end

    it "names Bug #22260 when the child dies on a signal" do
      Dir.mktmpdir do |dir|
        expect(described_class.unsupported_reason(fake_ruby(dir, "kill -SEGV $$")))
          .to include("Ruby Bug #22260")
      end
    end

    it "refuses a child that exits cleanly with the wrong answer without blaming the bug" do
      Dir.mktmpdir do |dir|
        reason = described_class.unsupported_reason(fake_ruby(dir, "printf '(1/2)'"))
        expect(reason).to include("probe failed")
        expect(reason).not_to include("22260")
      end
    end

    it "refuses a child that fails to boot without blaming the bug" do
      Dir.mktmpdir do |dir|
        reason = described_class.unsupported_reason(fake_ruby(dir, "exit 1"))
        expect(reason).to include("probe failed")
        expect(reason).not_to include("22260")
      end
    end

    it "gives the child an empty RUBYOPT, so a caller's -r cannot fail the probe" do
      Dir.mktmpdir do |dir|
        ruby = fake_ruby(dir, %([ -z "$RUBYOPT" ] && printf '(3/4)'))
        saved = ENV.fetch("RUBYOPT", nil)
        ENV["RUBYOPT"] = "-rno_such_feature_for_rigor_probe"
        begin
          expect(described_class.unsupported_reason(ruby)).to be_nil
        ensure
          ENV["RUBYOPT"] = saved
        end
      end
    end

    it "kills a child that outlives the deadline and refuses" do
      stub_const("#{described_class}::DEADLINE_SECONDS", 0.2)
      Dir.mktmpdir do |dir|
        expect(described_class.unsupported_reason(fake_ruby(dir, "exec sleep 30"))).to include("could not run")
      end
    end

    it "refuses when the Ruby cannot be started at all" do
      Dir.mktmpdir do |dir|
        expect(described_class.unsupported_reason(File.join(dir, "no-such-ruby"))).to include("could not run")
      end
    end
  end

  # A stand-in `ruby` that records each start in `calls` and then runs `body`, so a test can count probe children.
  def counting_ruby(dir, body)
    fake_ruby(dir, %(echo x >> "#{dir}/calls"\n#{body}))
  end

  def probe_calls(dir)
    path = File.join(dir, "calls")
    File.exist?(path) ? File.readlines(path).size : 0
  end

  describe ".cached_unsupported_reason", unless: Gem.win_platform? do
    it "runs the probe on a miss and answers the next call from the cache without a child" do
      Dir.mktmpdir do |dir|
        ruby = counting_ruby(dir, "printf '(3/4)'")
        cache = File.join(dir, "cache")
        expect(described_class.cached_unsupported_reason(ruby, cache_dir: cache)).to be_nil
        expect(described_class.cached_unsupported_reason(ruby, cache_dir: cache)).to be_nil
        expect(probe_calls(dir)).to eq(1)
      end
    end

    it "caches a crash refusal and returns the same reason on a hit" do
      Dir.mktmpdir do |dir|
        ruby = counting_ruby(dir, "kill -SEGV $$")
        cache = File.join(dir, "cache")
        first = described_class.cached_unsupported_reason(ruby, cache_dir: cache)
        expect(first).to include("Ruby Bug #22260")
        expect(described_class.cached_unsupported_reason(ruby, cache_dir: cache)).to eq(first)
        expect(probe_calls(dir)).to eq(1)
      end
    end

    it "runs the probe again when the cache file is corrupt" do
      Dir.mktmpdir do |dir|
        ruby = counting_ruby(dir, "printf '(3/4)'")
        cache = File.join(dir, "cache")
        path = described_class.cache_path(cache, ruby)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "garbage")
        expect(described_class.cached_unsupported_reason(ruby, cache_dir: cache)).to be_nil
        expect(probe_calls(dir)).to eq(1)
      end
    end

    it "misses when the Ruby build differs" do
      Dir.mktmpdir do |dir|
        ruby = counting_ruby(dir, "printf '(3/4)'")
        cache = File.join(dir, "cache")
        described_class.cached_unsupported_reason(ruby, cache_dir: cache)
        stub_const("RUBY_DESCRIPTION", "#{RUBY_DESCRIPTION} (another build)")
        described_class.cached_unsupported_reason(ruby, cache_dir: cache)
        expect(probe_calls(dir)).to eq(2)
      end
    end

    %w[RUBY_VERSION RUBY_PATCHLEVEL RUBY_REVISION].each do |constant|
      it "misses when #{constant} differs" do
        Dir.mktmpdir do |dir|
          ruby = counting_ruby(dir, "printf '(3/4)'")
          cache = File.join(dir, "cache")
          described_class.cached_unsupported_reason(ruby, cache_dir: cache)
          stub_const(constant, "#{Object.const_get(constant)}-another-build")
          described_class.cached_unsupported_reason(ruby, cache_dir: cache)
          expect(probe_calls(dir)).to eq(2)
        end
      end
    end

    it "misses for a Ruby at another path even when the build is the same" do
      Dir.mktmpdir do |dir|
        first_dir = File.join(dir, "a")
        second_dir = File.join(dir, "b")
        [first_dir, second_dir].each { |d| FileUtils.mkdir_p(d) }
        cache = File.join(dir, "cache")
        described_class.cached_unsupported_reason(counting_ruby(first_dir, "printf '(3/4)'"), cache_dir: cache)
        described_class.cached_unsupported_reason(counting_ruby(second_dir, "printf '(3/4)'"), cache_dir: cache)
        expect([probe_calls(first_dir), probe_calls(second_dir)]).to eq([1, 1])
      end
    end

    %w[BUS ABRT ILL].each do |signal|
      it "caches a refusal from a child killed by SIG#{signal}" do
        Dir.mktmpdir do |dir|
          ruby = counting_ruby(dir, "kill -#{signal} $$")
          cache = File.join(dir, "cache")
          2.times { expect(described_class.cached_unsupported_reason(ruby, cache_dir: cache)).to include("22260") }
          expect(probe_calls(dir)).to eq(1)
        end
      end
    end

    it "caches the verdict that Ruby::Box is not available" do
      Dir.mktmpdir do |dir|
        ruby = counting_ruby(dir, "exit 2")
        cache = File.join(dir, "cache")
        2.times do
          expect(described_class.cached_unsupported_reason(ruby, cache_dir: cache)).to include("not available")
        end
        expect(probe_calls(dir)).to eq(1)
      end
    end

    it "answers without raising when the cache directory cannot be written" do
      Dir.mktmpdir do |dir|
        ruby = counting_ruby(dir, "printf '(3/4)'")
        cache = File.join(dir, "cache")
        FileUtils.mkdir_p(cache)
        File.chmod(0o555, cache)
        begin
          expect(described_class.cached_unsupported_reason(ruby, cache_dir: cache)).to be_nil
          expect(File.exist?(described_class.cache_path(cache, ruby))).to be(false)
        ensure
          File.chmod(0o755, cache)
        end
      end
    end

    it "leaves no cache file behind when the write is interrupted part-way" do
      Dir.mktmpdir do |dir|
        ruby = counting_ruby(dir, "printf '(3/4)'")
        cache = File.join(dir, "cache")
        allow(File).to receive(:write).and_wrap_original do |original, target, body|
          original.call(target, body[0, 5])
          raise IOError, "interrupted"
        end
        described_class.cached_unsupported_reason(ruby, cache_dir: cache)
        expect(File.exist?(described_class.cache_path(cache, ruby))).to be(false)
      end
    end

    it "rejects a cache file whose format line is wrong even when its verdict line is valid" do
      Dir.mktmpdir do |dir|
        ruby = counting_ruby(dir, "kill -SEGV $$")
        cache = File.join(dir, "cache")
        path = described_class.cache_path(cache, ruby)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "rigor-box-probe-v0\npass")
        expect(described_class.cached_unsupported_reason(ruby, cache_dir: cache)).to include("22260")
        expect(probe_calls(dir)).to eq(1)
      end
    end

    it "never caches a probe that failed without a verdict about the Ruby" do
      Dir.mktmpdir do |dir|
        ruby = counting_ruby(dir, "exit 1")
        cache = File.join(dir, "cache")
        2.times { expect(described_class.cached_unsupported_reason(ruby, cache_dir: cache)).to include("probe failed") }
        expect(probe_calls(dir)).to eq(2)
      end
    end

    it "never caches a child killed by a signal the bug does not raise" do
      Dir.mktmpdir do |dir|
        ruby = counting_ruby(dir, "kill -KILL $$")
        cache = File.join(dir, "cache")
        2.times { described_class.cached_unsupported_reason(ruby, cache_dir: cache) }
        expect(probe_calls(dir)).to eq(2)
      end
    end

    it "probes every time when no cache directory is available" do
      Dir.mktmpdir do |dir|
        ruby = counting_ruby(dir, "printf '(3/4)'")
        2.times { described_class.cached_unsupported_reason(ruby, cache_dir: nil) }
        expect(probe_calls(dir)).to eq(2)
      end
    end
  end

  describe ".default_cache_dir" do
    it "uses an absolute XDG_CACHE_HOME" do
      expect(described_class.default_cache_dir({ "XDG_CACHE_HOME" => "/x/cache" })).to eq("/x/cache/rigor")
    end

    it "falls back to ~/.cache for an unset or relative XDG_CACHE_HOME" do
      expected = File.join(Dir.home, ".cache", "rigor")
      expect([described_class.default_cache_dir({}), described_class.default_cache_dir({ "XDG_CACHE_HOME" => "rel" })])
        .to eq([expected, expected])
    end

    it "turns the cache off for a relative or empty HOME when XDG_CACHE_HOME does not apply" do
      expect([described_class.default_cache_dir({ "HOME" => "rel" }),
              described_class.default_cache_dir({ "HOME" => "" }),
              described_class.default_cache_dir({ "HOME" => "", "XDG_CACHE_HOME" => "rel" })])
        .to eq([nil, nil, nil])
    end

    it "uses an absolute HOME" do
      expect(described_class.default_cache_dir({ "HOME" => "/h" })).to eq("/h/.cache/rigor")
    end
  end

  describe ".needs_reexec?" do
    let(:stderr) { StringIO.new }
    let(:refusal) { "Ruby 4.0.5 crashes running Ractor-shareable procs inside Ruby::Box (Ruby Bug #22260)" }

    def reexec?(env, box_active: true)
      described_class.needs_reexec?(env, stderr: stderr, box_active: box_active, cache_dir: "/unused")
    end

    def probe_answers(reason)
      allow(described_class).to receive(:cached_unsupported_reason).and_return(reason)
    end

    context "with RUBY_BOX already set" do
      it "re-execs without RUBY_BOX, drops the ruby_box request, marks the child and says so when the probe fails" do
        probe_answers(refusal)
        env = { "RUBY_BOX" => "1", "RIGOR_PLUGIN_ISOLATION" => "ruby_box", "RIGOR_BOX" => "1" }
        expect(reexec?(env)).to be(true)
        expect(env).to eq(described_class::REEXEC_MARKER => "1")
        expect(stderr.string).to eq("rigor: RUBY_BOX is set, but #{refusal}. " \
                                    "Re-running without RUBY_BOX; plugins will not run inside Ruby::Box.\n")
      end

      it "keeps RUBY_BOX and does not re-exec when the probe passes" do
        probe_answers(nil)
        env = { "RUBY_BOX" => "1" }
        expect(reexec?(env)).to be(false)
        expect([env, stderr.string]).to eq([{ "RUBY_BOX" => "1" }, ""])
      end

      it "does not probe when Ruby::Box is not active in this process" do
        allow(described_class).to receive(:cached_unsupported_reason)
        env = { "RUBY_BOX" => "1" }
        expect(reexec?(env, box_active: false)).to be(false)
        expect(described_class).not_to have_received(:cached_unsupported_reason)
        expect(env).to eq("RUBY_BOX" => "1")
      end

      it "treats a Ruby without Ruby::Box as inactive and neither probes nor prints a notice" do
        hide_const("Ruby::Box")
        allow(described_class).to receive(:cached_unsupported_reason)
        env = { "RUBY_BOX" => "1" }
        expect(described_class.box_active?).to be(false)
        expect(described_class.needs_reexec?(env, stderr: stderr, cache_dir: "/unused")).to be(false)
        expect(described_class).not_to have_received(:cached_unsupported_reason)
        expect([env, stderr.string]).to eq([{ "RUBY_BOX" => "1" }, ""])
      end
    end

    it "does nothing and does not probe when RUBY_BOX is unset and ruby_box is not requested" do
      allow(described_class).to receive(:cached_unsupported_reason)
      env = { "RIGOR_PLUGIN_ISOLATION" => "process" }
      expect(reexec?(env)).to be(false)
      expect(described_class).not_to have_received(:cached_unsupported_reason)
      expect(env).to eq("RIGOR_PLUGIN_ISOLATION" => "process")
    end

    it "neither probes nor re-execs in a re-exec'ed child, and clears the marker" do
      allow(described_class).to receive(:cached_unsupported_reason)
      env = { "RUBY_BOX" => "1", "RIGOR_PLUGIN_ISOLATION" => "ruby_box", described_class::REEXEC_MARKER => "1" }
      expect(reexec?(env)).to be(false)
      expect(described_class).not_to have_received(:cached_unsupported_reason)
      expect(env).to eq("RUBY_BOX" => "1", "RIGOR_PLUGIN_ISOLATION" => "ruby_box")
    end

    it "re-execs a ruby_box request under a marked RUBY_BOX=1 when the probe passes" do
      probe_answers(nil)
      env = { "RIGOR_BOX" => "1" }
      expect(reexec?(env)).to be(true)
      expect(env).to eq("RIGOR_BOX" => "1", "RUBY_BOX" => "1", "RIGOR_PLUGIN_ISOLATION" => "ruby_box",
                        described_class::REEXEC_MARKER => "1")
    end

    it "drops a ruby_box request with a warning when the probe fails" do
      probe_answers(refusal)
      env = { "RIGOR_PLUGIN_ISOLATION" => "ruby_box" }
      expect(reexec?(env)).to be(false)
      expect(env).to eq({})
      expect(stderr.string).to start_with("rigor: ruby_box plugin isolation is unavailable: #{refusal}.")
    end
  end

  # The launcher end to end: `RUBY_BOX=1` preset, a cached refusal for this Ruby, a `rigor check` whose first
  # Ractor-shareable lambda would crash inside the box on an affected Ruby.
  describe "exe/rigor with RUBY_BOX preset", if: defined?(Ruby::Box), unless: Gem.win_platform? do
    it "re-execs without RUBY_BOX on a cached refusal, keeping argv and the exit status" do
      Dir.mktmpdir do |dir|
        cache = File.join(dir, "xdg")
        path = described_class.cache_path(File.join(cache, "rigor"), RbConfig.ruby)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "#{described_class::CACHE_FORMAT}\nfail\nseeded refusal\n")
        source = File.join(dir, "probe_target.rb")
        File.write(source, "1.no_such_method_here\n")
        exe = File.expand_path("../../../exe/rigor", __dir__)
        out, err, status = Open3.capture3(
          { "RUBY_BOX" => "1", "XDG_CACHE_HOME" => cache, described_class::REEXEC_MARKER => nil },
          RbConfig.ruby, exe, "check", "--no-cache", "--no-baseline", source,
          stdin_data: "", chdir: File.expand_path("../../..", __dir__)
        )
        expect(err.scan(/^rigor: RUBY_BOX is set, but seeded refusal\. Re-running without RUBY_BOX/).size).to eq(1)
        expect([status.signaled?, status.exitstatus]).to eq([false, 1])
        expect(out).to include("probe_target.rb:1:3: error: undefined method")
      end
    end
  end

  # A re-exec'ed child sees only the marker; the launcher must still load the probe and clear the marker, so a
  # `rigor` that child starts in turn probes again instead of inheriting the skip.
  describe "exe/rigor with only the re-exec marker set", unless: Gem.win_platform? do
    it "loads the probe and clears RIGOR_BOX_PROBED before Rigor runs" do
      Dir.mktmpdir do |dir|
        shim = File.join(dir, "report_marker.rb")
        File.write(shim, <<~RUBY)
          at_exit do
            $stderr.puts "marker=\#{ENV.key?("RIGOR_BOX_PROBED")} probe=\#{defined?(Rigor::Plugin::BoxProbe) ? 1 : 0}"
          end
        RUBY
        exe = File.expand_path("../../../exe/rigor", __dir__)
        _out, err, status = Open3.capture3(
          { "RUBY_BOX" => nil, "RIGOR_PLUGIN_ISOLATION" => nil, "RIGOR_BOX" => nil,
            described_class::REEXEC_MARKER => "1" },
          RbConfig.ruby, "-r", shim, exe, "version", stdin_data: ""
        )
        expect([status.success?, err.lines.grep(/\Amarker=/)]).to eq([true, ["marker=false probe=1\n"]])
      end
    end
  end

  describe "against the Ruby running this suite" do
    it "answers the reproducer correctly when the box guard is removed, so the pass path is reachable" do
      body = described_class::SCRIPT.lines.drop(1).join
      output, status = Open3.capture2({ "RUBY_BOX" => nil, "RUBYOPT" => nil }, RbConfig.ruby, "--disable-gems",
                                      "-e", body)
      expect([output, status.success?]).to eq([described_class::EXPECTED_OUTPUT, true])
    end

    it "treats Ruby::Box as absent when the child is started without RUBY_BOX" do
      output, status = Open3.capture2e({ "RUBY_BOX" => nil }, RbConfig.ruby, "--disable-gems",
                                       "-e", described_class::SCRIPT)
      expect([output, status.exitstatus]).to eq(["", 2])
    end

    it "rejects every released Ruby 4.0 through 4.0.7, which crashes on Bug #22260",
       if: released_without_fix do
      expect(described_class.unsupported_reason).to include("Ruby Bug #22260")
    end
  end
end
