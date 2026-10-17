# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Issue #1596 — a class guard's narrowing of an instance variable survives an implicit-self call whose callee is
# proven to write no such variable (`Inference::SelfCallIvarWrites`). That proof reads the callee's body, every
# method it reaches, and the subclasses that could override it, and gives up on an owner another file reopens, so
# an edit to any of them in another file must re-check the caller. The oracle is a full `--no-cache` run of the
# same tree, driven as in `prepend_region_incremental_spec.rb`.
RSpec.describe "self-call ivar-write proof — incremental" do
  let(:caller_source) do
    <<~RUBY
      require "stringio"

      class Holder < Base
        def initialize = (@io = STDOUT)

        def dump
          return unless @io.is_a?(StringIO)

          log("dumping")
          @io.string
        end
      end
    RUBY
  end

  def configuration(dir)
    Rigor::Configuration.new("paths" => [dir])
  end

  def shared_environment
    @shared_environment ||= Rigor::Environment.for_project
  end

  def session_for(dir)
    Rigor::Analysis::IncrementalSession.new(
      configuration: configuration(dir), paths: [dir], environment: shared_environment
    )
  end

  def undefined_methods(diagnostics)
    found = diagnostics.select { |d| d.rule == "call.undefined-method" }
    found.map { |d| [File.basename(d.path), d.line] }.sort
  end

  def full_run(dir)
    runner = Rigor::Analysis::Runner.new(
      configuration: configuration(dir), cache_store: nil, environment: shared_environment
    )
    undefined_methods(guarded_run(runner).diagnostics)
  end

  # Writes the tree, takes a baseline (quiet, as a full run is), applies `edit`, and expects the warm run to report
  # the read in `a.rb` as the full run does.
  def expect_recheck_to_report(files, edit)
    Dir.mktmpdir do |dir|
      write_files(dir, files.merge("a.rb" => caller_source))
      session = session_for(dir)
      expect(undefined_methods(guarded_baseline(session))).to eq([])
      expect(full_run(dir)).to eq([])

      write_files(dir, edit)
      recheck = guarded_recheck(session)
      expect(recheck.affected).to include(File.join(dir, "a.rb"))
      expect([undefined_methods(recheck.diagnostics), full_run(dir)]).to eq([[["a.rb", 10]], [["a.rb", 10]]])
    end
  end

  def write_files(dir, files)
    files.each { |name, source| File.write(File.join(dir, name), source) }
  end

  it "re-checks the caller when the callee in another file starts writing the variable" do
    expect_recheck_to_report(
      { "b.rb" => "class Base\n  def log(message) = warn(message)\nend\n" },
      { "b.rb" => "class Base\n  def log(_message) = (@io = STDOUT)\nend\n" }
    )
  end

  it "re-checks the caller when a method the callee reaches starts writing the variable" do
    expect_recheck_to_report(
      { "b.rb" => "class Base < Root\n  def log(message) = note(message)\nend\n",
        "c.rb" => "class Root\n  def note(message) = warn(message)\nend\n" },
      { "c.rb" => "class Root\n  def note(_message) = (@io = STDOUT)\nend\n" }
    )
  end

  it "re-checks the caller when a new subclass overrides the callee with a write" do
    expect_recheck_to_report(
      { "b.rb" => "class Base\n  def log(message) = warn(message)\nend\n" },
      { "d.rb" => "class Loud < Holder\n  def log(_message) = (@io = STDOUT)\nend\n" }
    )
  end

  it "re-checks the caller when an existing subclass gains a `define_method` override" do
    expect_recheck_to_report(
      { "b.rb" => "class Base\n  def log(message) = warn(message)\nend\n", "d.rb" => "class Loud < Holder\nend\n" },
      { "d.rb" => "class Loud < Holder\n  define_method(:log) { |_message| @io = STDOUT }\nend\n" }
    )
  end

  # Issue #1596 — a second file declaring the owner gives the proof up, whatever it defines.
  it "re-checks the caller when a new file reopens the callee's owner" do
    expect_recheck_to_report(
      { "b.rb" => "class Base\n  def log(message) = warn(message)\nend\n" },
      { "e.rb" => "class Base\n  def log(_message) = (@io = STDOUT)\nend\n" }
    )
  end

  # Issue #1979 — a class built on `Data.define` is no subclass of `Holder`, so its `to_s` leaves the proof standing;
  # an edit that makes its superclass expression name `Holder`, or a write that may shadow `Data`, gives it up.
  it "re-checks the caller when a constructed class's superclass starts naming self's class" do
    expect_recheck_to_report(
      { "b.rb" => "class Base\n  def log(message) = warn(message)\nend\n",
        "d.rb" => "class Fact < Data.define(:a)\n  def to_s = \"f\"\nend\n" },
      { "d.rb" => "class Fact < Class.new(Holder)\n  def to_s = \"f\"\nend\n" }
    )
  end

  it "re-checks the caller when another file assigns a constant named as a constructed class's receiver" do
    expect_recheck_to_report(
      { "b.rb" => "class Base\n  def log(message) = warn(message)\nend\n",
        "d.rb" => "class Fact < Data.define(:a)\n  def to_s = \"f\"\nend\n", "f.rb" => "module App\nend\n" },
      { "f.rb" => "module App\n  Data = 1\nend\n" }
    )
  end
end
