# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Issue #1698, incremental half — a constant read through a module the class body includes and only RBS
# declares depends on the `include` and on whether the project binds a nearer spelling of the module's name
# (Ruby resolves `include SigHelpers` in `class User` as `User::SigHelpers` first). A file that starts
# writing `User::SigHelpers` has no other relationship with the reader, so only the name edges the ancestor
# rung files can put the reader back in the closure. The oracle at every step is a full `--no-cache` run.
RSpec.describe "constants through an RBS-only mixin — incremental (#1698)" do
  def configuration(dir)
    Rigor::Configuration.new("paths" => [File.join(dir, "lib")])
  end

  def environment(dir)
    @environment ||= Rigor::Environment.for_project(root: dir, signature_paths: [File.join(dir, "sig")])
  end

  def session_for(dir)
    Rigor::Analysis::IncrementalSession.new(
      configuration: configuration(dir), paths: [File.join(dir, "lib")], environment: environment(dir)
    )
  end

  def rules(diagnostics)
    diagnostics.reject { |d| d.severity == :info }.map { |d| "#{File.basename(d.path)}:#{d.rule}" }.sort
  end

  def full_run(dir)
    runner = Rigor::Analysis::Runner.new(
      configuration: configuration(dir), cache_store: nil, environment: environment(dir)
    )
    rules(guarded_run(runner).diagnostics)
  end

  let(:signatures) { <<~RBS }
    module SigHelpers
      class Box
        def initialize: () -> void
      end
    end
  RBS

  it "re-checks the reader when a nearer spelling of the included module appears and goes" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "sig", "helpers.rbs"), signatures)
      File.write(File.join(dir, "lib", "user.rb"), "class User\n  include SigHelpers\nend\n")
      reader = File.join(dir, "lib", "use.rb")
      File.write(reader, "class User\n  def run = Box.new.other\nend\n")
      shadow = File.join(dir, "lib", "shadow.rb")

      session = session_for(dir)
      expect(rules(guarded_baseline(session))).to eq(["use.rb:call.undefined-method"])
      expect(full_run(dir)).to eq(["use.rb:call.undefined-method"])

      File.write(shadow, "User::SigHelpers = Comparable\n")
      recheck = guarded_recheck(session)
      expect(recheck.affected).to include(reader)
      expect(rules(recheck.diagnostics)).to eq([])
      expect(full_run(dir)).to eq([])

      FileUtils.rm(shadow)
      recheck = guarded_recheck(session)
      expect(recheck.affected).to include(reader)
      expect(rules(recheck.diagnostics)).to eq(["use.rb:call.undefined-method"])
      expect(full_run(dir)).to eq(["use.rb:call.undefined-method"])
    end
  end
end
