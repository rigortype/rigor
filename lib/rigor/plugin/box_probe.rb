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
    # only when a run opts into `ruby_box`.
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

      module_function

      # nil when `ruby` can run Rigor under `RUBY_BOX=1`; otherwise a short reason for the launcher's
      # warning. Only a child killed by a signal is blamed on the bug; any other failure to answer is
      # reported as the probe failing, never as a pass.
      def unsupported_reason(ruby = RbConfig.ruby)
        output, status = run(ruby)
        return "the Ruby::Box probe could not run #{ruby}" if status.nil?
        return nil if status.success? && output == EXPECTED_OUTPUT
        return "Ruby::Box is not available in Ruby #{RUBY_VERSION}" if status.exitstatus == 2
        return "the Ruby::Box probe failed (#{status})" unless status.signaled?

        "Ruby #{RUBY_VERSION} crashes running Ractor-shareable procs inside Ruby::Box " \
          "(Ruby Bug #22260; a Ruby carrying its fix is needed)"
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
