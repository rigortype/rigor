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

  # The reverse of {#expect_recheck_to_report}: the baseline reports the read, `edit` restores the proof, and the warm
  # run must go quiet as the full run does.
  def expect_recheck_to_clear(files, edit)
    Dir.mktmpdir do |dir|
      write_files(dir, files.merge("a.rb" => caller_source))
      session = session_for(dir)
      expect(undefined_methods(guarded_baseline(session))).to eq([["a.rb", 10]])
      expect(full_run(dir)).to eq([["a.rb", 10]])

      write_files(dir, edit)
      recheck = guarded_recheck(session)
      expect(recheck.affected).to include(File.join(dir, "a.rb"))
      expect([undefined_methods(recheck.diagnostics), full_run(dir)]).to eq([[], []])
    end
  end

  def write_files(dir, files)
    files.each { |name, source| File.write(File.join(dir, name), source) }
  end

  # An ancestor's write in another file is a literal (`:closed`): it joins `Holder`'s `@io` census entry, as
  # `Dynamic[top]` unless it is a literal (#2170), and `:closed.string` raises NoMethodError under Ruby 4.0.5 as
  # `STDOUT.string` does.

  it "re-checks the caller when the callee in another file starts writing the variable" do
    expect_recheck_to_report(
      { "b.rb" => "class Base\n  def log(message) = warn(message)\nend\n" },
      { "b.rb" => "class Base\n  def log(_message) = (@io = :closed)\nend\n" }
    )
  end

  it "re-checks the caller when a method the callee reaches starts writing the variable" do
    expect_recheck_to_report(
      { "b.rb" => "class Base < Root\n  def log(message) = note(message)\nend\n",
        "c.rb" => "class Root\n  def note(message) = warn(message)\nend\n" },
      { "c.rb" => "class Root\n  def note(_message) = (@io = :closed)\nend\n" }
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
      { "e.rb" => "class Base\n  def log(_message) = (@io = :closed)\nend\n" }
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

  # Issue #2137 — a `refine` of a class on the chain (here the caller's own, ahead of the owner `Base`) marks it
  # rewritten from a file that declares nothing the chain reads, and keeps the file's declared classes, so no class key
  # fires: only the `mark:` edge `rewritten?` files re-checks the caller.
  def refining = "module R\n  refine Holder do\n    def helper = 1\n  end\nend\n"

  it "re-checks the caller when a file whose declarations stay starts refining the caller's class" do
    expect_recheck_to_report(
      { "b.rb" => "class Base\n  def log(message) = warn(message)\nend\n", "x.rb" => "module R\nend\n" },
      { "x.rb" => refining }
    )
  end

  it "re-checks the caller when a file whose declarations stay stops refining the caller's class" do
    expect_recheck_to_clear(
      { "b.rb" => "class Base\n  def log(message) = warn(message)\nend\n", "x.rb" => refining },
      { "x.rb" => "module R\nend\n" }
    )
  end

  # A guard: a dynamic rewrite on a namespace candidate (`Base` and `App::Base` from inside `module App`) moves the
  # file's class declarations, whose `class:Base` key the chain read already records.
  it "re-checks the caller when a file starts rewriting a namespace candidate of a class on the chain" do
    expect_recheck_to_report(
      { "b.rb" => "class Base\n  def log(message) = warn(message)\nend\n", "x.rb" => "module App\nend\n" },
      { "x.rb" => "module App\n  NAME = :helper\n  Base.define_method(NAME) { 1 }\nend\n" }
    )
  end

  # Issue #2163 — a `refine` of a class off the chain (`Kernel`, `Object`, `IO`) that defines a name the callee calls
  # may route that call to the refine body, so the proof gives up. No chain read covers such a class: only the
  # `refinement:` edge `refined?` files re-checks the caller when a file whose declarations stay starts or stops
  # refining the name. Issue #2203 — a refinement of a class `self` cannot reach (`String` for a `Holder`) leaves a
  # call on `self` alone; the cold table below keeps that proof.
  {
    "Kernel#warn" => ["def log(message) = warn(message)", "refine Kernel do\n    def warn(*) = 1\n  end"],
    "Object#warn" => ["def log(message) = warn(message)", "refine Object do\n    def warn(*) = 1\n  end"],
    "IO#write" => ["def log(message) = STDERR.write(message)", "refine IO do\n    def write(*) = 1\n  end"]
  }.each do |label, (callee, refine)|
    it "re-checks the caller when a file whose declarations stay starts refining #{label}" do
      expect_recheck_to_report(
        { "b.rb" => "class Base\n  #{callee}\nend\n", "x.rb" => "module R\nend\n" },
        { "x.rb" => "module R\n  #{refine}\nend\n" }
      )
    end

    it "re-checks the caller when a file whose declarations stay stops refining #{label}" do
      expect_recheck_to_clear(
        { "b.rb" => "class Base\n  #{callee}\nend\n", "x.rb" => "module R\n  #{refine}\nend\n" },
        { "x.rb" => "module R\nend\n" }
      )
    end
  end

  # Issue #2203 — a refine body that defines a name the walk cannot read (`define_method` of a computed name) records a
  # names-wildcard row, which refines every name: the proof gives up as it does for a literal `def warn`, and only the
  # `refinement:*` edge `refined?` files re-checks the caller when a file whose declarations stay starts or stops
  # writing one.
  def wildcard_refine(target = "Kernel", name = "N")
    "module R\n  refine #{target} do\n    N = :warn\n    define_method(#{name}) { |*| 1 }\n  end\nend\n"
  end

  def base_source(prefix = "") = "#{prefix}class Base\n  def log(message) = warn(message)\nend\n"

  it "re-checks the caller when a file whose declarations stay starts a computed define_method in a refinement" do
    expect_recheck_to_report(
      { "b.rb" => base_source, "x.rb" => "module R\nend\n" }, { "x.rb" => wildcard_refine }
    )
  end

  # A guard for the `refinement:*` edge: the start example pins it; this one is re-checked without it.
  it "re-checks the caller when a file whose declarations stay stops a computed define_method in a refinement" do
    expect_recheck_to_clear(
      { "b.rb" => base_source, "x.rb" => wildcard_refine }, { "x.rb" => "module R\nend\n" }
    )
  end

  # Issue #2203 — a module the project mixes into `Object` reaches every project class, so a file whose declarations
  # stay that starts mixing a refined one in must re-check the caller: only the `Object` chain the reach reads (and
  # records) sees it.
  it "re-checks the caller when a file starts mixing a module with a computed refine into Object" do
    refined = "module M\n  def z = 1\nend\n\n#{wildcard_refine('M')}"
    expect_recheck_to_report(
      { "b.rb" => base_source, "x.rb" => refined, "y.rb" => "module Y\nend\n" },
      { "y.rb" => "module Y\nend\n\nclass Object\n  include M\nend\n" }
    )
  end

  # The cold reads: the refine sits in `x.rb`, the callee in `b.rb`, the caller in `a.rb`. A row refines a call on
  # `self` when its class is one `self` reaches (`Holder`, `Object`, `Kernel`), whether or not a `using` activates it;
  # a refinement of a class `self` cannot reach, however its body is spelled, leaves the proof standing, and so does a
  # literal `define_method` of another name. The rows that keep the proof are guards against over-reading a row, which
  # no removal of the wildcard read fails; the reach read pins the unreachable-class rows.
  wild = lambda do |target = "Kernel", name = "N"|
    "module R\n  refine #{target} do\n    N = :warn\n    define_method(#{name}) { |*| 1 }\n  end\nend\n"
  end
  base = "class Base\n  def log(message) = warn(message)\nend\n"
  literal_module = ->(expression) { "module M\n  def self.f(o)\n    #{expression}\n  end\nend\n" }
  struct_caller = lambda do |superclass|
    "require \"stringio\"\n\nclass Holder < #{superclass}\n  def initialize = (@io = STDOUT)\n\n  def dump\n    " \
      "return unless @io.is_a?(StringIO)\n\n    log(\"dumping\")\n    @io.string\n  end\n\n  " \
      "def log(message) = warn(message)\nend\n"
  end
  {
    "of Kernel, activated by a `using` in the callee's file" => [{ "b.rb" => "using R\n#{base}", "x.rb" => wild.call },
                                                                 [["a.rb", 10]]],
    "of Kernel, not activated" => [{ "b.rb" => base, "x.rb" => wild.call }, [["a.rb", 10]]],
    "of Object" => [{ "b.rb" => base, "x.rb" => wild.call("Object") }, [["a.rb", 10]]],
    "of self's class" => [{ "b.rb" => base, "x.rb" => wild.call("Holder") }, [["a.rb", 10]]],
    "of self's superclass" => [{ "b.rb" => base, "x.rb" => wild.call("Base") }, [["a.rb", 10]]],
    "of a module the superclass includes" => [
      { "b.rb" => "module Mix\n  def z = 1\nend\n\nclass Base\n  include Mix\n  " \
                  "def log(message) = warn(message)\nend\n",
        "x.rb" => wild.call("Mix") },
      [["a.rb", 10]]
    ],
    # Ruby 4.0.5 runs the refined `warn` for both: a module the project mixes into `Object` sits ahead of `Kernel`, and
    # so does `PP::ObjectMixin`, an `Object` ancestor only RBS declares.
    "of a module the project mixes into Object" => [
      { "b.rb" => base, "x.rb" => "module M\n  def z = 1\nend\n\nclass Object\n  include M\nend\n\n#{wild.call('M')}" },
      [["a.rb", 10]]
    ],
    "of an RBS ancestor of Object" => [{ "b.rb" => base, "x.rb" => wild.call("PP::ObjectMixin") }, [["a.rb", 10]]],
    "of String, an unrelated class" => [{ "b.rb" => base, "x.rb" => wild.call("String") }, []],
    "of String, defining the literal name" => [
      { "b.rb" => base, "x.rb" => "module R\n  refine String do\n    def warn(*) = 1\n  end\nend\n" }, []
    ],
    "of Integer, by import_methods" => [
      { "b.rb" => base, "x.rb" => "module R\n  refine Integer do\n    import_methods Comparable\n  end\nend\n" }, []
    ],
    "of Array, in a Module.new block" => [
      { "b.rb" => base, "x.rb" => wild.call("Array").sub("module R\n", "Module.new do\n") }, []
    ],
    "of Kernel, of another literal name" => [{ "b.rb" => base, "x.rb" => wild.call("Kernel", ":other") }, []],
    "of Kernel, of another literal name in the callee's file" => [{ "b.rb" => wild.call("Kernel", ":other") + base },
                                                                  []],
    # Where the chain ends in a superclass the tables cannot name, the reach is unknown and a names-wildcard row counts
    # for no call on `self`, as before #2203; so does an unattributed `:refine` literal's `{"*" => {"*" => …}}` row.
    "of Kernel, past a superclass a constant holds as a Struct" => [
      { "b.rb" => "Base = Struct.new(:a) do\n  def log(message) = warn(message)\nend\n", "x.rb" => wild.call }, []
    ],
    "of Kernel, past a Struct.new superclass" => [
      { "a.rb" => struct_caller.call("Struct.new(:a)"), "x.rb" => wild.call }, []
    ],
    "of Kernel, past a Data.define superclass" => [
      { "a.rb" => struct_caller.call("Data.define(:a)"), "x.rb" => wild.call }, []
    ],
    "beside an indexed :refine" => [{ "b.rb" => base, "x.rb" => literal_module.call("o[:refine]") }, []],
    "beside a fetched :refine" => [{ "b.rb" => base, "x.rb" => literal_module.call("o.fetch(:refine)") }, []],
    "beside a key? :refine" => [{ "b.rb" => base, "x.rb" => literal_module.call("o.key?(:refine)") }, []],
    "beside a when :refine" => [
      { "b.rb" => base, "x.rb" => literal_module.call("case o\n    when :refine then 1\n    end") }, []
    ],
    "beside a :refine compared as the receiver" => [{ "b.rb" => base, "x.rb" => literal_module.call(":refine == o") },
                                                    []]
  }.each do |label, (files, expected)|
    it "reads a refinement #{label} as a cold run does" do
      Dir.mktmpdir do |dir|
        write_files(dir, { "a.rb" => caller_source }.merge(files))
        expect(full_run(dir)).to eq(expected)
      end
    end
  end
end
