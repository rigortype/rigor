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

  def stdout(source, prelude: nil)
    Dir.mktmpdir("rigor-ruby-run-") do |dir|
      path = File.join(dir, "fixture.rb")
      File.write(path, source)
      args = [RbConfig.ruby]
      if prelude
        prelude_path = File.join(dir, "prelude.rb")
        File.write(prelude_path, prelude)
        args += ["-r", prelude_path]
      end
      out, err, status = Bundler.with_unbundled_env { Open3.capture3(*args, path) }
      raise "Ruby failed on the fixture (#{status.exitstatus}): #{err}" unless status.success?

      out
    end
  end
end
