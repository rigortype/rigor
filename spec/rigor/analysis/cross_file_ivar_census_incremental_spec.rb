# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Issues #2079 / #2170 — the class-ivar census joins another file's writes, and those of the modules and
# superclasses on the class's chain, into the entries it holds. Each read files `own_write_type:<owner>#<ivar>`,
# which the incremental session fires when a file's coarse write values for the pair move, a type change under the
# same name included. The oracle is a full `--no-cache` run of the same tree.
RSpec.describe "cross-file ivar census — incremental" do
  let(:reader) { "class E\n  def initialize = (@x = nil)\n  def get = @x.upcase\nend\n" }

  def configuration(dir) = Rigor::Configuration.new("paths" => [dir])

  def shared_environment
    @shared_environment ||= Rigor::Environment.for_project
  end

  def session_for(dir)
    Rigor::Analysis::IncrementalSession.new(configuration: configuration(dir), paths: [dir],
                                            environment: shared_environment)
  end

  def rows(diagnostics)
    diagnostics.select { |d| d.rule == "call.undefined-method" }.map { |d| [File.basename(d.path), d.line] }.sort
  end

  def full_run(dir)
    runner = Rigor::Analysis::Runner.new(configuration: configuration(dir), cache_store: nil,
                                         environment: shared_environment)
    rows(guarded_run(runner).diagnostics)
  end

  def write_files(dir, files)
    files.each { |name, source| File.write(File.join(dir, name), source) }
  end

  # Writes `files` with `a.rb` the reader, checks the baseline against a full run, applies each edit in turn and
  # expects the warm run to match the full run, and `a.rb` to be re-checked or not as each step says.
  def expect_steps(files, steps, baseline:)
    Dir.mktmpdir do |dir|
      write_files(dir, files.merge("a.rb" => reader))
      session = session_for(dir)
      expect([rows(guarded_baseline(session)), full_run(dir)]).to eq([baseline, baseline])
      steps.each { |edit, rechecked, expected| expect_step(dir, session, edit, rechecked, expected) }
    end
  end

  def expect_step(dir, session, edit, rechecked, expected)
    write_files(dir, edit)
    recheck = guarded_recheck(session)
    expect(recheck.affected.include?(File.join(dir, "a.rb"))).to eq(rechecked), edit.inspect
    expect([rows(recheck.diagnostics), full_run(dir)]).to eq([expected, expected]), edit.inspect
  end

  it "re-checks the reader when a reopening's write changes type, and not when its value does not move" do
    expect_steps(
      { "b.rb" => "class E\n  def set = (@x = \"a\")\nend\n" },
      [
        [{ "b.rb" => "class E\n  def set = (@x = nil)\nend\n" }, true, [["a.rb", 3]]],
        [{ "b.rb" => "class E\n  def set = (@x = \"a\")\nend\n" }, true, []],
        [{ "b.rb" => "class E\n  def set = (@x = \"a\"; nil)\nend\n" }, false, []]
      ],
      baseline: []
    )
  end

  it "re-checks the reader when an included module in another file changes what it writes" do
    expect_steps(
      { "b.rb" => "module M\n  def set = (@x = \"a\")\nend\n",
        "c.rb" => "class E\n  include M\nend\n" },
      [
        [{ "b.rb" => "module M\n  def set = (@y = \"a\")\nend\n" }, true, [["a.rb", 3]]],
        [{ "b.rb" => "module M\n  def set = (@x = \"a\")\nend\n" }, true, []]
      ],
      baseline: []
    )
  end

  it "re-checks the reader when another file removes the include" do
    expect_steps(
      { "b.rb" => "module M\n  def set = (@x = \"a\")\nend\n",
        "c.rb" => "class E\n  include M\nend\n" },
      [[{ "c.rb" => "class E\nend\n" }, true, [["a.rb", 3]]]],
      baseline: []
    )
  end
end
