# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# #1572's singleton side across files. A reopening in another file that extends an RBS-known module after the
# project module puts that module ahead of the definer (Ruby: `C.singleton_class.ancestors` starts
# `[#<Class:C>, Enumerable, M]`), so the typing read withholds and `C.to_a.first` stops firing. The warm run must
# re-check the consumer the new file moved. The oracle is a full `--no-cache` run of the same tree; the driver is
# `IncrementalSession`, as in `unsettled_chain_incremental_spec.rb`.
RSpec.describe "an RBS-known module extended ahead of the definer — incremental (#1572)" do
  def configuration(dir) = Rigor::Configuration.new("paths" => [dir])

  def shared_environment = (@shared_environment ||= Rigor::Environment.for_project)

  def diagnostics(list)
    list.select { |d| d.rule == "call.undefined-method" }.map { |d| [File.basename(d.path), d.line] }.sort
  end

  def full_run(dir)
    runner = Rigor::Analysis::Runner.new(configuration: configuration(dir), cache_store: nil,
                                         environment: shared_environment)
    diagnostics(guarded_run(runner).diagnostics)
  end

  it "re-checks the consumer when a new file reopens the class with `extend Enumerable`" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.rb"), "module M\n  def to_a = 1\nend\nclass C\n  extend M\n  " \
                                         "def self.each = yield(\"a\")\nend\n")
      File.write(File.join(dir, "c.rb"), "C.to_a.first\n")
      session = Rigor::Analysis::IncrementalSession.new(configuration: configuration(dir), paths: [dir],
                                                        environment: shared_environment)
      # Before the edit Ruby raises NoMethodError (`1.first`): the baseline fires.
      expect(diagnostics(guarded_baseline(session))).to eq([["c.rb", 1]])

      File.write(File.join(dir, "b.rb"), "class C\n  extend Enumerable\nend\n")
      warm = diagnostics(guarded_recheck(session).diagnostics)
      cold = full_run(dir)
      expect(cold).to eq([])
      expect(warm).to eq(cold)
    end
  end
end
