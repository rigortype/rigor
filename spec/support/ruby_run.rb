# frozen_string_literal: true

require "bundler"
require "open3"
require "rbconfig"
require "tmpdir"

# Runs a Ruby source under the suite's own Ruby in an unbundled child and returns what it printed. The witness
# specs use it to prove what a fixture's truth is ("Ruby prints ...") beside what `rigor check` reports.
#
# `prelude` is Ruby source loaded before `source` with `-r`, so the child has a shim (an `ActiveSupport::Concern`
# stand-in) that `rigor check` over the same `source` never sees: the analysed file stays free of it.
module RubyRun
  module_function

  TIME_LIMIT = 20

  # Runs the suite's Ruby with `args` in an unbundled child and returns [stdout, stderr, status]; a child past
  # TIME_LIMIT seconds is killed and raises.
  def capture(*args)
    Bundler.with_unbundled_env do
      Open3.popen3(RbConfig.ruby, *args) do |stdin, out, err, waiter|
        stdin.close
        readers = [out, err].map do |io|
          Thread.new do
            io.read
          rescue IOError # the pipe closes under the read once a child past the limit is killed
            nil
          end
        end
        unless waiter.join(TIME_LIMIT)
          Process.kill(:KILL, waiter.pid)
          raise "ruby #{args.first(2).join(' ')} ran past #{TIME_LIMIT}s"
        end
        [readers[0].value, readers[1].value, waiter.value]
      end
    end
  end

  def stdout(source, prelude: nil)
    Dir.mktmpdir("rigor-ruby-run-") do |dir|
      path = File.join(dir, "fixture.rb")
      File.write(path, source)
      args = []
      if prelude
        prelude_path = File.join(dir, "prelude.rb")
        File.write(prelude_path, prelude)
        args += ["-r", prelude_path]
      end
      out, err, status = capture(*args, path)
      raise "Ruby failed on the fixture (#{status.exitstatus}): #{err}" unless status.success?

      out
    end
  end
end
