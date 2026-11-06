# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# #2884 — a Ruby class inherits a `def self.new` its ancestor's signature declares, so `Widget.new`'s type depends on
# the superclass edge of every class on Widget's chain, written in other files. Giving `Base` the superclass `X`
# (whose signature declares `def self.new: () -> Y`) makes `Widget.new` a `Y`, and `.count.upcase` then calls
# `upcase` on an Integer; taking the edge away makes it a `Widget` again. The warm run must re-check `caller.rb` each
# time. The oracle is a full `--no-cache` run of the same tree; the driver is `IncrementalSession`, as in
# `rbs_complete_bridge_incremental_spec.rb`.
RSpec.describe "a declared `def self.new` inherited through another file's superclass edge — incremental (#2884)" do
  def configuration(dir)
    Rigor::Configuration.new("paths" => [File.join(dir, "lib")], "signature_paths" => [File.join(dir, "sig")])
  end

  def shared_environment(dir)
    (@shared_environment ||= Rigor::Environment.for_project(root: dir, signature_paths: [File.join(dir, "sig")]))
  end

  def diagnostics(list)
    list.select { |d| d.rule == "call.undefined-method" }.map { |d| [File.basename(d.path), d.line] }.sort
  end

  def full_run(dir)
    runner = Rigor::Analysis::Runner.new(configuration: configuration(dir), cache_store: nil,
                                         environment: shared_environment(dir))
    diagnostics(guarded_run(runner).diagnostics)
  end

  it "re-checks the caller when a superclass edge onto the declaring class is added and removed" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "sig", "x.rbs"),
                 "class X\n  def self.new: () -> Y\nend\nclass Y\n  def count: () -> Integer\nend\n")
      File.write(File.join(dir, "lib", "x.rb"), "class X; end\nclass Y; def count = 1; end\n")
      File.write(File.join(dir, "lib", "base.rb"), "class Base; end\n")
      File.write(File.join(dir, "lib", "model.rb"), "class Widget < Base; end\n")
      File.write(File.join(dir, "lib", "caller.rb"), "Widget.new.count.upcase\n")
      session = Rigor::Analysis::IncrementalSession.new(configuration: configuration(dir),
                                                        paths: [File.join(dir, "lib")],
                                                        environment: shared_environment(dir))
      expect(diagnostics(guarded_baseline(session))).to eq([])

      File.write(File.join(dir, "lib", "base.rb"), "class Base < X; end\n")
      warm = diagnostics(guarded_recheck(session).diagnostics)
      expect(full_run(dir)).to eq([["caller.rb", 1]])
      expect(warm).to eq([["caller.rb", 1]])

      File.write(File.join(dir, "lib", "base.rb"), "class Base; end\n")
      warm = diagnostics(guarded_recheck(session).diagnostics)
      expect(full_run(dir)).to eq([])
      expect(warm).to eq([])
    end
  end
end
