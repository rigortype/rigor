# frozen_string_literal: true

require "rbconfig"

module Rigor
  module Plugin
    # Decides, before `exe/rigor` re-execs itself under `RUBY_BOX=1`, whether the running Ruby can host
    # Rigor inside `Ruby::Box` at all. A released Ruby up to and including 4.0.7 cannot: `env_copy()` drops
    # the box a class/module-body proc carries when `Ractor.make_shareable` isolates it, so the first
    # method call inside such a proc dereferences a NULL box and the VM segfaults (Ruby Bug #22260, fixed on
    # CRuby master by `a4ad8e461a`). Rigor defines Ractor-shareable lambdas at module scope as a standing
    # pattern, so on an affected Ruby the `ruby_box` strategy crashes the whole run rather than declining.
    #
    # The check is behavioural, not a version comparison: a child Ruby runs the bug's minimal reproducer
    # under `RUBY_BOX=1` and must print the right answer. That admits a 4.1.0dev build with the fix and a
    # future 4.0.x that backports it, and refuses a development build cut before the fix — none of which a
    # `RUBY_VERSION` bound gets right. The probe costs one short-lived `ruby --disable-gems` process, paid
    # only when a run opts into `ruby_box` or starts with `RUBY_BOX` already set, and only once per Ruby
    # build: {cached_unsupported_reason} remembers the verdict.
    #
    # Loaded by `exe/rigor` before anything else, so this file requires nothing from Rigor.
    module BoxProbe
      # A class-body lambda isolated by `Ractor.make_shareable`, then a method dispatch inside it — the
      # four ingredients the crash needs. Exits 2 when `Ruby::Box` is not active (a Ruby without the
      # feature ignores `RUBY_BOX=1`), so a missing feature is told apart from a crash.
      SCRIPT = <<~PROBE
        exit 2 unless defined?(Ruby::Box) && Ruby::Box.respond_to?(:enabled?) && Ruby::Box.enabled?
        module RigorBoxProbe
          RATIONAL = Ractor.make_shareable(lambda { |*args| Rational(*args) })
        end
        print RigorBoxProbe::RATIONAL.call(3, 4).inspect
      PROBE

      EXPECTED_OUTPUT = "(3/4)"

      # The reproducer answers in well under a second; a child still running after this is killed and
      # counted as a failure, so a wedged probe cannot hang the launcher (or `rigor lsp` behind it).
      DEADLINE_SECONDS = 10

      # Set on the environment of every re-exec this module asks for, so the re-exec'ed launcher neither
      # probes again nor re-execs again. The launcher deletes it before Rigor loads, so nothing Rigor spawns
      # inherits it.
      REEXEC_MARKER = "RIGOR_BOX_PROBED"

      # The signals the bug's NULL-box dereference ends a child with. A child killed by any other signal
      # (an OOM killer's `SIGKILL`, an operator's `SIGTERM`) is still refused, but that verdict is not cached.
      CRASH_SIGNALS = %w[SEGV BUS ABRT ILL].freeze

      CACHE_FORMAT = "rigor-box-probe-v1"

      module_function

      # Decides what `exe/rigor` does before Rigor loads, editing `env` (the real `ENV` in the launcher) in
      # place. Returns true when the launcher must re-exec itself with `env` as now edited.
      #
      # - `RUBY_BOX` already set (by hand or by a wrapper), and `Ruby::Box` active in this process: the
      #   process booted inside the box before any Rigor code ran, so on a Ruby without the Bug #22260 fix
      #   the first Ractor-shareable lambda Rigor calls segfaults. Probe (through the cache); when the Ruby
      #   is refused, print a notice, drop `RUBY_BOX` and the `ruby_box` request, and re-exec. When it
      #   passes, keep `RUBY_BOX` as the user set it.
      # - `ruby_box` requested and `RUBY_BOX` unset: probe; re-exec under `RUBY_BOX=1` when it passes,
      #   otherwise warn and drop the request.
      # - Otherwise nothing.
      def needs_reexec?(env, stderr: $stderr, box_active: box_active?, cache_dir: default_cache_dir(env))
        return false if env.delete(REEXEC_MARKER)

        if env["RUBY_BOX"].to_s.empty?
          reexec_for_box_request?(env, stderr, cache_dir)
        else
          reexec_without_preset_box?(env, stderr, box_active, cache_dir)
        end
      end

      def reexec_for_box_request?(env, stderr, cache_dir)
        isolation = env["RIGOR_PLUGIN_ISOLATION"].to_s
        return false unless isolation == "ruby_box" || !env["RIGOR_BOX"].to_s.empty?

        if (reason = cached_unsupported_reason(cache_dir: cache_dir))
          # `puts` on stderr, not `warn`: `-W0` silences `warn`, and this fallback must never be silent.
          stderr.puts "rigor: ruby_box plugin isolation is unavailable: #{reason}. " \
                      "Falling back to the configured plugins_isolation strategy (default: process)."
          drop_box_request(env)
          false
        else
          env["RUBY_BOX"] = "1"
          env["RIGOR_PLUGIN_ISOLATION"] = "ruby_box" if isolation.empty?
          env[REEXEC_MARKER] = "1"
          true
        end
      end

      def reexec_without_preset_box?(env, stderr, box_active, cache_dir)
        return false unless box_active

        reason = cached_unsupported_reason(cache_dir: cache_dir)
        return false unless reason

        stderr.puts "rigor: RUBY_BOX is set, but #{reason}. " \
                    "Re-running without RUBY_BOX; plugins will not run inside Ruby::Box."
        env.delete("RUBY_BOX")
        drop_box_request(env)
        env[REEXEC_MARKER] = "1"
        true
      end

      def drop_box_request(env)
        env.delete("RIGOR_PLUGIN_ISOLATION") if env["RIGOR_PLUGIN_ISOLATION"].to_s == "ruby_box"
        env.delete("RIGOR_BOX")
      end

      # Whether this process booted inside `Ruby::Box`. False on a Ruby without the feature, which ignores
      # `RUBY_BOX`, so a preset variable there costs nothing.
      def box_active?
        return false unless defined?(::Ruby::Box) && ::Ruby::Box.respond_to?(:enabled?)

        ::Ruby::Box.enabled? == true
      end

      # `$XDG_CACHE_HOME/rigor` when that is an absolute path, else `$HOME/.cache/rigor` when `HOME` is an
      # absolute path (the passwd entry when `HOME` is unset); nil otherwise, which turns the cache off
      # rather than writing under the working directory.
      def default_cache_dir(env)
        xdg = env["XDG_CACHE_HOME"].to_s
        return File.join(xdg, "rigor") if xdg.start_with?("/")

        home = env.key?("HOME") ? env["HOME"].to_s : Dir.home
        File.absolute_path?(home) ? File.join(home, ".cache", "rigor") : nil
      rescue ArgumentError
        nil
      end

      # {unsupported_reason}, remembered per Ruby build so a launcher that probes on every run pays for the
      # child process once. A pass is stored only when the child printed the right answer, and a refusal
      # only when it is a property of the Ruby (no `Ruby::Box`, or a crash signal); a probe that could not
      # run, timed out, or failed some other way is answered but not stored. An unreadable or corrupt
      # cache file reads as a miss; a write that fails is ignored.
      def cached_unsupported_reason(ruby = RbConfig.ruby, cache_dir:)
        path = cache_dir && cache_path(cache_dir, ruby)
        cached = path && read_cache(path)
        return cached[:reason] if cached

        reason, cacheable = verdict(ruby)
        write_cache(path, reason) if path && cacheable
        reason
      end

      # The cache file for `ruby`: keyed on the Ruby build that runs the launcher (its version, patch level,
      # revision and description) together with the executable path and the probe script itself.
      def cache_path(cache_dir, ruby)
        require "digest/sha2"
        key = [RUBY_VERSION, RUBY_PATCHLEVEL, RUBY_REVISION, RUBY_DESCRIPTION, File.expand_path(ruby), SCRIPT]
        File.join(cache_dir, "ruby-box-probe", Digest::SHA256.hexdigest(key.join("\0")))
      end

      def read_cache(path)
        format, verdict, reason = File.read(path).split("\n", 3)
        return nil unless format == CACHE_FORMAT

        case verdict
        when "pass" then reason.nil? ? { reason: nil } : nil
        when "fail" then reason.to_s.chomp.empty? ? nil : { reason: reason.chomp }
        end
      rescue SystemCallError, IOError, ArgumentError
        nil
      end

      def write_cache(path, reason)
        require "fileutils"
        FileUtils.mkdir_p(File.dirname(path))
        body = reason ? "#{CACHE_FORMAT}\nfail\n#{reason}\n" : "#{CACHE_FORMAT}\npass"
        temp = "#{path}.#{::Process.pid}.tmp"
        File.write(temp, body)
        File.rename(temp, path)
      rescue SystemCallError, IOError
        nil
      end

      # nil when `ruby` can run Rigor under `RUBY_BOX=1`; otherwise a short reason for the launcher's
      # warning. Only a child killed by a signal is blamed on the bug; any other failure to answer is
      # reported as the probe failing, never as a pass.
      def unsupported_reason(ruby = RbConfig.ruby)
        verdict(ruby).first
      end

      # `[reason, cacheable]` — {unsupported_reason}'s answer, and whether it is a property of the Ruby
      # build rather than of this one attempt.
      def verdict(ruby)
        output, status = run(ruby)
        return ["the Ruby::Box probe could not run #{ruby}", false] if status.nil?
        return [nil, true] if status.success? && output == EXPECTED_OUTPUT
        return ["Ruby::Box is not available in Ruby #{RUBY_VERSION}", true] if status.exitstatus == 2
        return ["the Ruby::Box probe failed (#{status})", false] unless status.signaled?

        ["Ruby #{RUBY_VERSION} crashes running Ractor-shareable procs inside Ruby::Box " \
         "(Ruby Bug #22260; a Ruby carrying its fix is needed)", crash_signal?(status.termsig)]
      end

      def crash_signal?(signo)
        CRASH_SIGNALS.any? { |name| Signal.list[name] == signo }
      end

      # `RUBYOPT` is cleared so a `-r` of the caller's (bootsnap, a debugger, a coverage hook) cannot fail
      # to load under `--disable-gems` and be mistaken for the crash; the probe needs nothing but core.
      def run(ruby)
        reader, writer = IO.pipe
        pid = ::Process.spawn({ "RUBY_BOX" => "1", "RUBYOPT" => nil }, ruby, "--disable-gems", "-e", SCRIPT,
                              in: File::NULL, out: writer, err: File::NULL)
        writer.close
        output = read_until_eof(reader)
        return [output, ::Process.wait2(pid).last] if output

        ::Process.kill(:KILL, pid)
        ::Process.wait(pid)
        [nil, nil]
      rescue ::SystemCallError
        [nil, nil]
      ensure
        writer&.close unless writer&.closed?
        reader&.close
      end

      # The child's whole stdout, or nil when it has not closed it by the deadline.
      def read_until_eof(reader)
        deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + DEADLINE_SECONDS
        output = +""
        loop do
          remaining = deadline - ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
          return nil unless remaining.positive? && reader.wait_readable(remaining)

          chunk = reader.read_nonblock(4096, exception: false)
          return output if chunk.nil?

          output << chunk if chunk.is_a?(String)
        end
      end
    end
  end
end
