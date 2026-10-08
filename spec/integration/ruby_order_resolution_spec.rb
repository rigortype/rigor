# frozen_string_literal: true

# The `rigor check` reproductions of the false positives the breadth-first ancestor walks produced, each beside
# a control on the same file that must still fire — so a run that analysed nothing cannot pass by reporting
# nothing. `spec/integration/resolution_chain_witness_spec.rb` compares the same shapes with Ruby. #1570's
# shape is pinned where the chain's two worlds leave it: the arity rule declines (ADR-119 C1b).

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "resolution in Ruby's ancestor order (#1567, #1568, #1570, #1571)" do
  def diagnostics_for(source)
    FileUtils.mkdir_p("lib")
    File.write(File.join("lib", "demo.rb"), source)
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0)
    )
    guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
      .diagnostics.reject { |diagnostic| diagnostic.severity == :info }
      .map { |diagnostic| [diagnostic.line, diagnostic.qualified_rule] }
  end

  def diagnostics_for_files(files)
    FileUtils.mkdir_p("lib")
    files.each { |name, source| File.write(File.join("lib", name), source) }
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0)
    )
    guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
      .diagnostics.reject { |diagnostic| diagnostic.severity == :info }
      .map { |diagnostic| [File.basename(diagnostic.path), diagnostic.line, diagnostic.qualified_rule] }
  end

  around do |example|
    Dir.mktmpdir("rigor-ruby-order-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "types a method from a module an included module includes, not from the superclass (#1567)" do
    expect(diagnostics_for(<<~RUBY)).to eq([[21, "call.undefined-method"]])
      class Base
        def foo = 1
      end

      module M
        def foo = "m"
      end

      module A
        include M
      end

      class C < Base
        include A

        def bar = foo
      end

      C.new.bar.upcase
      # The control: `Base#foo` is 1.
      Base.new.foo.upcase
    RUBY
  end

  it "types a class method from a module an extended module includes, not from the superclass (#1567)" do
    expect(diagnostics_for(<<~RUBY)).to eq([[18, "call.undefined-method"]])
      class Base
        def self.foo = 1
      end

      module M
        def foo = "m"
      end

      module A
        include M
      end

      class C < Base
        extend A
      end

      C.foo.upcase
      Base.foo.upcase
    RUBY
  end

  it "calls a prepended module's public method, not the class's private one (#1568)" do
    expect(diagnostics_for(<<~RUBY)).to eq([[20, "def.method-visibility-mismatch"]])
      module P
        def foo = :p
      end

      class C
        prepend P

        private

        def foo = :c
      end

      class D
        private

        def foo = :d
      end

      C.new.foo
      D.new.foo
    RUBY
  end

  it "does not report the class's private method as reducing a prepended module's visibility (#1568)" do
    expect(diagnostics_for(<<~RUBY)).to eq([[20, "def.override-visibility-reduced"]])
      module P
        def foo = :p
      end

      class C
        prepend P

        private

        def foo = :c
      end

      class Base
        def foo = :base
      end

      class D < Base
        private

        def foo = :d
      end
    RUBY
  end

  # Ruby skips `C`'s `include M` (`Base` already carries it), so `C.new.foo` is `Base#foo` and correct; but the
  # tables cannot tell that run from one where `Base` was reopened to include `M` after `C` did (`[C, M, Base, M]`,
  # `M#foo(x)`). The two worlds disagree, the candidate-set read answers `UNKNOWN` (ADR-119 C1b), and line 19 is
  # silent. Line 20 is the control.
  it "declines the arity check for an include of a module the superclass already includes (#1570)" do
    expect(diagnostics_for(<<~RUBY)).to eq([[20, "call.wrong-arity"]])
      module M
        def foo(x) = "m\#{x}"
      end

      class Base
        include M

        def foo = 1
      end

      class C < Base
        include M
      end

      class E
        def foo = 1
      end

      C.new.foo
      E.new.foo(1)
    RUBY
  end

  # #1625, a known tp-lost by design (ADR-119 C1d-a): the second `def run` sits in an `if`, so its def-node slot is
  # contested and the candidate-set read takes the earlier `run(a)` as well; the two worlds disagree on the arity
  # and the read answers `UNKNOWN`. Ruby raises ArgumentError in both worlds (`run(a)` and `run(a) = p(a)` both take
  # one argument), so the silence is a lost true positive. Flip this when #1625 is fixed: the expectation becomes
  # `[[1, "call.wrong-arity"]]`.
  it "stays silent on a wrong-arity call to a def a conditional redefinition shadows (#1625, tp-lost today)" do
    expect(diagnostics_for(<<~RUBY)).to eq([])
      class Svc; def run(a) = a; if ENV["DEBUG"]; def run(a) = p(a); end; end; Svc.new.run(1, 2)
    RUBY
  end

  # The #1570 shape as a program Ruby can run: the same text with a `p` where the diagnostic source calls.
  def issue_1570_source(tail)
    <<~RUBY
      module M
        def foo(x) = "m\#{x}"
      end

      class Base
        include M

        def foo = 1
      end

      class C < Base
        include M
      end

      class E
        def foo = 1
      end

      #{tail}
    RUBY
  end

  # Ruby's answer for #1570: `C.ancestors` is `[C, Base, M, ...]`, so `C.new.foo` is `Base#foo` and returns 1.
  it "runs #1570's include of a module the superclass already includes as Base#foo under Ruby" do
    expect(RubyRun.stdout(issue_1570_source("p C.ancestors.first(3)\np C.new.foo"))).to eq("[C, Base, M]\n1\n")
  end

  # The same program as the pin above, from the shared source: line 19 (`C.new.foo`) is correct under Ruby's run
  # and silent; line 20 is the control and stays.
  it "reports no arity error for an include of a module the superclass already includes (#1570)" do
    expect(diagnostics_for(issue_1570_source("C.new.foo\nE.new.foo(1)"))).to eq([[20, "call.wrong-arity"]])
  end

  # #1607 — the singleton-side form of #1570. `extend M` on `C` is skipped because `Base`'s singleton already
  # carries `M`, so `C.foo` is `Base.foo` and prints 1; the singleton side of `SourceArity` still settles to master's
  # order, which reads `M#foo(x)`. Flip when ADR-119 C2 designs the singleton side of the candidate-set read.
  it "runs the singleton-side #1570 as Base.foo under Ruby" do
    expect(RubyRun.stdout("#{singleton_1570_source}p C.foo\n")).to eq("1\n")
  end

  def singleton_1570_source
    <<~RUBY
      module M; def foo(x) = "m\#{x}"; end
      class Base; extend M; def self.foo = 1; end
      class C < Base; extend M; end
    RUBY
  end

  it "reports no arity error for an extend of a module the superclass already extends (#1607)" do
    pending "https://github.com/rigortype/rigor/issues/1607 — singleton side, ADR-119 C2; the line is a false positive"

    expect(diagnostics_for("#{singleton_1570_source}C.foo\n")).to eq([])
  end

  # The arity rule's hedges survive the move of its levels onto the chain: a module whose method table the
  # project rewrites dynamically (`ENVELOPE_DYNAMIC_MARK`) still declines every level it sits in, in either
  # world, and the same shape without the mark still fires.
  it "keeps declining a call through a module with a dynamically rewritten surface" do
    expect(diagnostics_for(<<~RUBY)).to eq([])
      module D
        %i[x].each { |name| define_method(name) { nil } }
      end

      class Base
        include D

        def foo(a) = a
      end

      class C < Base
        include D
      end

      C.new.foo(1, 2)
    RUBY
  end

  it "fires on the same call once the module's surface is its literal definitions" do
    expect(diagnostics_for(<<~RUBY)).to eq([[15, "call.wrong-arity"]])
      module D
        def x = nil
      end

      class Base
        include D

        def foo(a) = a
      end

      class C < Base
        include D
      end

      C.new.foo(1, 2)
    RUBY
  end

  # A body reopened after an includer ran leaves the tables in a state the skip rule reads one way and Ruby
  # ran the other (`ResolutionChain#settle`). The readers keep master's answer there, so none of these may fire —
  # `Base#foo`'s `1` is what the final tables alone would type the call as. Each keeps a control that must.
  it "keeps master's answer where the superclass was reopened to include a module the class already included" do
    expect(diagnostics_for(<<~RUBY)).to eq([[18, "call.undefined-method"]])
      module M
        def foo = "m"
      end

      class Base
        def foo = 1
      end

      class C < Base
        include M
      end

      class Base
        include M
      end

      C.new.foo.upcase
      Base.new.foo.upcase
    RUBY
  end

  it "keeps master's answer where an included module was reopened to include a module the class already included" do
    expect(diagnostics_for(<<~RUBY)).to eq([[19, "call.undefined-method"]])
      module M
        def foo = "m"
      end

      module N
        def foo = 1
      end

      class C
        include M
        include N
      end

      module M
        include N
      end

      C.new.foo + 1
      nil.upcase
    RUBY
  end

  # Two skips, and neither world a one-skip-at-a-time logic compares reaches Ruby's definer: `C` ran its
  # includes while `N` was still empty (`[C, D, Base, A, Deep, N, D]`, `D#foo`), and the final tables make both
  # of them skips, which both worlds turn into `Deep#foo`. A chain with two skips settles to master's order, so
  # `C.new.foo` is `D#foo`'s string and the correct `.upcase` is silent. The control is the same call on `Base`,
  # where `Deep#foo`'s `1` is right.
  it "does not type a two-skip chain from a definer Ruby does not call" do
    expect(diagnostics_for(<<~RUBY)).to eq([[30, "call.undefined-method"]])
      module Deep
        def foo = 1
      end

      module D
        def foo = "d"
      end

      module A
        include Deep
      end

      module N; end

      class Base
        include N
        include A
      end

      class C < Base
        include D
        include A
      end

      module N
        include D
      end

      C.new.foo.upcase
      Base.new.foo.upcase
    RUBY
  end

  # Round-1 review. Ruby's result for `prepend A` depends on whether `A` included `M` before or after the
  # prepend ran, which the tables cannot tell; `A` includes `M` LAST here, so the prepend saw an empty `A`
  # and Ruby reads `C`'s own `X`. A chain that puts `M` first would type `X` as `M::X` and fire on correct code.
  it "does not read a constant through a module the prepend saw before it included what the superclass carries" do
    expect(diagnostics_for(<<~RUBY)).to eq([])
      module A; end
      module M; X = "m"; end
      class C; include M; X = 1; end
      class D < C; prepend A; def bar = X.even?; end
      module A; include M; end
    RUBY
  end

  # `E#foo` overrides the private `D#foo`, so the chain that put `M` ahead of `D` reported a second reduction on
  # `E#foo` that Ruby's `[E, A, D, C, M]` does not have. `D#foo` reducing `M#foo` (line 17) was reported through
  # master's order while `A` includes `M` after `D` prepended it; since ADR-119 C1c the override lint reads
  # `DefinerResolution` and declines on that unsettled chain (an `Unknown`), so neither line fires.
  it "does not report a reduced override through the same prepend shape" do
    expect(diagnostics_for(<<~RUBY)).to eq([])
      module A
      end

      module M
        def foo = 2
      end

      class C
        include M
      end

      class D < C
        prepend A

        private

        def foo = 1
      end

      module A
        include M
      end

      class E < D
        private

        def foo = 3
      end
    RUBY
  end

  # Round-1 review, fuzzer find. `M0` was prepended empty and includes `M3` last; `Base` reached `M3` through
  # `M2` first, so the prepended `M0` gets no `M3` of its own and `C`'s `X` is `Base`'s. A module the prepend
  # region carries and a later include skips is order-dependent, which settles the chain to master's order.
  it "does not read a constant from a module a prepended module got after the class's include reached it" do
    expect(diagnostics_for(<<~RUBY)).to eq([])
      module M0; end
      module M2; end
      module M3; X = "m3"; end
      class Base; X = 1; end
      class C < Base; def bar = X.even?; end
      module M2; include M3; end
      class Base; prepend M0; end
      class Base; include M2; end
      module M0; include M3; end
    RUBY
  end

  # ADR-119 H1 — an edge whose ORDER the tables cannot vouch for (`DiscoveryIndex#unpositioned_mixins`, or a
  # class declared in several files with several edges) makes the chain untrustworthy even where nothing was
  # skipped, so each chain that draws on one settles to master's order. Every example below has no skip, and the
  # chain alone would answer `M#foo` (a String) where master answers `Base#foo` (an Integer).
  describe "mixin edges whose order is not a fact settle to master" do
    let(:prelude) do
      "module M; def foo = \"m\"; end\nmodule A; include M; end\nclass Base; def foo = 1; end\n"
    end

    # The chain alone answers `M#foo`, master's order answers `Base#foo`: the chain stands for neither, so the typing
    # read answers `UNKNOWN` (C2-b1) and `C.new.foo` is `Dynamic`. Ruby with `RIGOR_X` unset never runs the include:
    # `C.new.foo` is `Base#foo` and `upcase` IS missing, a true positive this silences by design (tp-lost, ADR-119
    # E5): the file alone cannot say which world runs, and the other world's `C.new.foo` is `M#foo`'s String.
    it "types a conditional include's call as Dynamic" do
      expect(diagnostics_for(<<~RUBY)).to eq([])
        #{prelude}class C < Base; include A if ENV["RIGOR_X"]; end

        C.new.foo.upcase
      RUBY
    end

    it "runs both worlds of the conditional include under Ruby" do
      source = "#{prelude}class C < Base; include A if ENV[\"RIGOR_X\"]; end\n"
      expect(RubyRun.stdout("#{source}p C.new.foo\n")).to eq("1\n")
      expect(RubyRun.stdout("ENV[\"RIGOR_X\"] = \"1\"\n#{source}p C.new.foo\n")).to eq("\"m\"\n")
    end

    # `setup` is never called: `C.ancestors` is `[C, Base]` in Ruby and `upcase` IS missing (tp-lost by design, as
    # above: a method body's include runs whenever the method is called, which the tables cannot know).
    it "types an include inside a method body as Dynamic" do
      expect(diagnostics_for(<<~RUBY)).to eq([])
        #{prelude}class C < Base; def self.setup = include(A); end

        C.new.foo.upcase
      RUBY
    end

    # Ruby's own answer is `M#foo` for the next three (their order is real but unknowable to the tables), so
    # master's `Base#foo` is silent on `even?`; a chain that read them would fire on the String.
    it "keeps master's answer for a class declared in two files, each with an include" do
      expect(diagnostics_for_files("a.rb" => <<~RUBY, "b.rb" => "class C; include Z; end\nC.new.foo.even?\n"))
        #{prelude}module Z; end
        class C < Base; include A; end
      RUBY
        .to eq([])
    end

    it "keeps master's answer for a class that includes a concern with `included do include A end`" do
      expect(diagnostics_for(<<~RUBY)).to eq([])
        #{prelude}module Concern
          extend ActiveSupport::Concern
          included do
            include A
          end
        end

        class C < Base; include Concern; end

        C.new.foo.even?
      RUBY
    end

    it "keeps master's answer for a class that includes a module whose hook includes another" do
      expect(diagnostics_for(<<~RUBY)).to eq([])
        #{prelude}module Hook
          def self.included(base) = base.include(A)
        end

        class C < Base; include Hook; include A; end

        C.new.foo.even?
      RUBY
    end
  end

  # Round-2 review. `M0` prepends `M1` AND (later) includes it, which the tables record exactly as a plain
  # `prepend M1`; `M1` then includes `M3`. Ruby's `C.ancestors` is `[C, M1, M0, M1, M3]`, so `X` is `M0`'s
  # String. The chain, which cannot see the include, would put `M3` ahead of `M0` and type `X` as an Integer.
  # The indexer names a module written to both the include and the prepend table unpositioned, so the chain
  # settles to master's order.
  it "does not read a constant through a prepended module's own includes ahead of the includer" do
    expect(diagnostics_for(<<~RUBY)).to eq([])
      module M0; X = "m0"; end
      module M1; end
      module M3; X = 3; end
      module M0; prepend M1; end
      class C; include M0; def bar = X.upcase; end
      module M0; include M1; end
      module M1; include M3; end
    RUBY
  end

  # Round-3 review. The prepend table keeps every statement, so the readers that walk it raw answer what they
  # always did: Ruby skips the repeated `prepend M1`, and `M1` (the first) stays nearest.
  it "keeps the first of a repeated prepend where the prepended module later includes another" do
    expect(diagnostics_for(<<~RUBY)).to eq([])
      module M1; def foo = "m1"; end
      module M3; def foo = 3; end
      class D; prepend M1; end
      module M1; include M3; end
      class D; prepend M3; end
      class D; prepend M1; end
      D.new.foo.upcase
    RUBY
  end

  # A repeated `extend` keeps the table position it always had, which the folded singleton tables read; Ruby's
  # `[K, M2, M4]` runs `M2#foo`, a String, and so does the reader's answer.
  it "keeps the readers' answer for a repeated extend of a module that later includes another" do
    expect(diagnostics_for(<<~RUBY)).to eq([])
      module M4; def foo = 1; end
      module M2; def foo = "m2"; end
      class K; extend M2; end
      module M2; include M4; end
      class K; extend M4; extend M2; end
      K.foo.upcase
    RUBY
  end

  # The singleton side resolved a class that only `extend`s as an external entry, so the modules it extends
  # vanished from the chain and the skip among them went uncounted.
  it "does not type a singleton method from a module a class that only extends carries" do
    expect(diagnostics_for(<<~RUBY)).to eq([])
      module Deep; def foo = "deep"; end
      module E0; include Deep; end
      module E1; include Deep; end
      class Base; extend E0; end
      class C < Base; def self.foo = 1; end
      class D < C; extend E1; end
      D.foo.even?
    RUBY
  end

  # `C.new.foo` is `Base#foo` (1) when `X` is set (`Base` already includes `M`, so `C`'s include is a skip) and `M#foo`
  # (a String) when it is not, so line 15 is world-dependent and typed `Dynamic` (C2-b1). `Base.new.foo` is `Base#foo`
  # in both worlds (its own `def` precedes the include), so line 16 is a true positive the typing read also loses:
  # the conditional include is relevant to `foo` (`M` defines it), so the read declines although `Base`'s own
  # `def` comes first (tp-lost by design, ADR-119 E5).
  it "types the class's call as Dynamic where a conditional include in the superclass makes its include a skip" do
    expect(diagnostics_for(<<~RUBY)).to eq([])
      module M
        def foo = "m"
      end

      class Base
        include M if ENV["X"]

        def foo = 1
      end

      class C < Base
        include M
      end

      C.new.foo.upcase
      Base.new.foo.upcase
    RUBY
  end

  it "reads a constant from a module an included module includes, not from the superclass (#1571)" do
    expect(diagnostics_for(<<~RUBY)).to eq([[23, "call.undefined-method"]])
      class Base
        X = 1
      end

      module M
        X = "m"
      end

      module A
        include M
      end

      class C < Base
        include A
        def bar = X
      end

      class D < Base
        def bar = X
      end

      C.new.bar.upcase
      D.new.bar.upcase
    RUBY
  end

  # #1592 — a singleton-side mixin written in a block. The extend walk dropped every block it did not recognise, so
  # `[1].each { extend X }` recorded nothing and the singleton chain stood without `X`. Ruby prints "X" for each
  # `K.bar` below. Only a block that provably runs at least once with the body's `self` (`tap` / `then`, an iterator
  # over a non-empty literal), written in a class body, is read as the body's own;
  # a block on any other object (an instance, an `on_load` hook) is skipped, as it was. The
  # control on the same source (`Kc`, no mixin) must still fire, so a run that analysed nothing cannot pass.
  describe "a singleton-side mixin inside a block, method or hook (#1592)" do
    let(:prelude) do
      "module X; def bar = \"X\"; end\nclass Base; def self.bar = 1; def self.baz = 1; end\n" \
        "class Kc < Base; end\nKc.baz.upcase\n"
    end
    let(:control) { [[4, "call.undefined-method"]] }

    it "records an `extend` inside an iterator" do
      expect(diagnostics_for("#{prelude}class K < Base\n  [1].each { extend X }\nend\nK.bar.upcase\n")).to eq(control)
    end

    it "records a `class << self; include` inside an iterator" do
      source = "#{prelude}class K < Base\n  [1].each { class << self; include X; end }\nend\nK.bar.upcase\n"
      expect(diagnostics_for(source)).to eq(control)
    end

    it "keeps an `extend` inside a method body" do
      source = "#{prelude}class K < Base\n  def self.setup = extend(X)\nend\nK.setup\nK.bar.upcase\n"
      expect(diagnostics_for(source)).to eq(control)
    end

    it "keeps a `class << self; include` inside a method body" do
      source = "#{prelude}class K < Base\n  def self.setup; class << self; include X; end; end\nend\n" \
               "K.setup\nK.bar.upcase\n"
      expect(diagnostics_for(source)).to eq(control)
    end

    # Ruby: each `label` below is Base's "x" (an `extend` in these blocks reaches the instance, or the class
    # `on_load` loads, never `Svc` / `Engine`), so `upcase` exists. Recording the edge on the enclosing class typed
    # each read as Counted's Integer.
    it "does not record an `extend` in a block that runs on another object" do
      source = <<~RUBY
        class Base; def self.label = "x"; end
        module Counted; def label = 1; end
        class Svc < Base
          def call = @lock.synchronize { extend Counted }
        end
        class Engine < Base
          ActiveSupport.on_load(:active_record) { extend Counted }
        end
        Svc.label.upcase
        Engine.label.upcase
      RUBY
      expect(diagnostics_for(source)).to eq([])
    end

    # A block that may never yield records nothing: `Registry.each` here never calls its block, a lazy `map` never
    # forces it, `[].each` and `0.times` never run it. Ruby's `label` is Base's "x" for each, so `upcase` exists.
    it "does not record an `extend` in a block that may never run" do
      source = <<~RUBY
        class Base; def self.label = "x"; end
        module Counted; def label = 1; end
        class Registry; def self.each; end; end
        LAZY = (1..Float::INFINITY).lazy
        class T1 < Base; Registry.each { extend Counted }; end
        class T2 < Base; LAZY.map { extend Counted }; end
        class T3 < Base; [].each { extend Counted }; end
        class T4 < Base; 0.times { extend Counted }; end
        T1.label.upcase
        T2.label.upcase
        T3.label.upcase
        T4.label.upcase
      RUBY
      expect(diagnostics_for(source)).to eq([])
    end

    # `tap` / `then` count only on a literal. `Registry.tap` is the constant's own (here `nil`, the block never
    # runs), and a receiverless or `self.` `tap` may reach the class's own singleton `tap`, so none records
    # anything; Ruby's `label` is Base's "x" for all three. `Base.tap { extend Counted }` would extend the class in
    # Ruby, a missed case.
    it "does not record an `extend` in `tap` on a constant, on self or without a receiver" do
      source = <<~RUBY
        class Base; def self.label = "x"; end
        module Counted; def label = 1; end
        class Registry; def self.tap = nil; end
        class U1 < Base; Registry.tap { extend Counted }; end
        class U2 < Base; def self.tap = nil; tap { extend Counted }; end
        class U3 < Base; def self.tap = nil; self.tap { extend Counted }; end
        U1.label.upcase
        U2.label.upcase
        U3.label.upcase
      RUBY
      expect(diagnostics_for(source)).to eq([])
    end

    # `1.then` yields once with the body's `self`, so Ruby's `T5.label` is Counted's 1.
    it "records an `extend` in `then` on a literal as the class's own" do
      source = <<~RUBY
        class Base; def self.label = "x"; end
        module Counted; def label = 1; end
        class T5 < Base; 1.then { extend Counted }; end
        T5.label.upcase
      RUBY
      expect(diagnostics_for(source)).to eq([[4, "call.undefined-method"]])
    end

    # #1567 with a block extend: the class's own singleton chain stays settled, because the block extend is
    # positioned. Ruby: `K.foo` is A's M#foo "m" (Unrelated has no `foo`), so `upcase` exists.
    it "keeps Ruby's singleton order for a class with a positioned block extend" do
      source = <<~RUBY
        module Unrelated; def zzz = 1; end
        class Base; def self.foo = 1; end
        module M; def foo = "m"; end
        module A; include M; end
        class K < Base; extend A; [1].each { extend Unrelated }; end
        K.foo.upcase
      RUBY
      expect(diagnostics_for(source)).to eq([])
    end

    # #1567 stays: an included module's own conditional `extend`, or a hook that extends its includer, is not the
    # includer's edge, so the includer's singleton chain must keep Ruby's order (`A`'s `M#foo`, not Base's).
    {
      "conditional extend" => "module Plugin; extend Unrelated if RUBY_VERSION > \"3\"; end",
      "hook extend" => "module Plugin; def self.included(base) = base.extend(Unrelated); end"
    }.each do |label, plugin|
      it "keeps Ruby's singleton order for an includer of a module with a #{label}" do
        source = <<~RUBY
          module Unrelated; def zzz = 1; end
          #{plugin}
          class Base; def self.foo = 1; end
          module M; def foo = "m"; end
          module A; include M; end
          class K < Base; include Plugin; extend A; end
          K.foo.upcase
        RUBY
        expect(diagnostics_for(source)).to eq([])
      end
    end

    # flip this when #1592 is fixed: Ruby prints "X" for `K.bar`, so the diagnostic is a false positive. Neither
    # the chain nor master's walk files a hook-driven edge under the includer; modelling `included do` /
    # `class_methods do` belongs to a follow-up ADR.
    it "still types a read through a concern's `included do extend X end` from master's order" do
      source = <<~RUBY
        #{prelude}module C
          extend ActiveSupport::Concern
          included do
            extend X
          end
        end
        class K < Base; include C; end
        K.bar.upcase
      RUBY
      expect(diagnostics_for(source)).to eq(control + [[12, "call.undefined-method"]])
    end

    # flip this when #1592 is fixed: Ruby prints "X" for `K.bar`; same shape as the concern above.
    it "still types a read through a `self.included(base)` hook that extends the includer from master's order" do
      source = <<~RUBY
        #{prelude}module H
          def self.included(base) = base.extend(X)
        end
        class K < Base; include H; end
        K.bar.upcase
      RUBY
      expect(diagnostics_for(source)).to eq(control + [[9, "call.undefined-method"]])
    end
  end

  # #1572 — an RBS-known module included after a project module that defines the same name. Ruby prints "a":
  # `C.ancestors` is `[C, Enumerable, M, ...]`, so `to_a` is `Enumerable#to_a`. The user-method tier reads the
  # project definers only and skips `Enumerable`, so it types the call from `M#to_a` (1). Line 16 is the control.
  describe "an RBS-known module included after a project module (#1572)" do
    let(:source) do
      <<~RUBY
        module M
          def to_a = 1
        end

        class C
          include M
          include Enumerable

          def each
            yield "a"
          end
        end

        K = Struct.new(:x)
        C.new.to_a.first
        K.new(1).x.upcase
      RUBY
    end

    it "runs Enumerable#to_a under Ruby" do
      expect(RubyRun.stdout("#{source.lines[0..12].join}\np C.new.to_a.first\np C.ancestors.first(3)\n"))
        .to eq("\"a\"\n[C, Enumerable, M]\n")
    end

    # UNKNOWN at C2-b1, so `C.new.to_a` types `Dynamic` and line 15 is silent (Ruby: `"a"`, a String, so `first` exists;
    # master's `M#to_a` Integer made it a false positive). #1572 later types it from `Enumerable` (an Array of String
    # elements) instead of `Dynamic`; line 16 is the control that this source still analyses.
    it "UNKNOWN at C2-b1; #1572 later types it from Enumerable" do
      expect(diagnostics_for(source)).to eq([[16, "call.undefined-method"]])
    end
  end

  # #1594 — a concern whose `included do` block includes a module makes every includer's chain unsettled, so the
  # read answers from master's order, which misses `A`'s `M#foo` and types `C.new.foo` as `Base#foo` (1). Ruby
  # prints "M" (ancestors `[C, A, M, Concern, Base]`; the chain lists `Concern` first, the same answer). The
  # `.even?` example above hides it. The Ruby run loads a minimal `ActiveSupport::Concern` (`included do`
  # semantics) that `rigor check` never sees: the analysed file has no activesupport in scope.
  describe "a concern's `included do include A end` (#1594)" do
    let(:concern_shim) do
      <<~RUBY
        module ActiveSupport
          module Concern
            def self.extended(base) = base.instance_variable_set(:@_included_block, nil)

            def included(base = nil, &block)
              if base.nil?
                @_included_block = block
              else
                super
                base.class_eval(&@_included_block) if @_included_block
              end
            end
          end
        end
      RUBY
    end
    let(:source) do
      <<~RUBY
        module M; def foo = "M"; end
        module A; include M; end
        module Concern
          extend ActiveSupport::Concern
          included do
            include A
          end
        end
        class Base; def foo = 1; end
        class C < Base; include Concern; end
        class Kc < Base; end
        Kc.new.foo.upcase
        C.new.foo.upcase
      RUBY
    end

    it "runs M#foo under Ruby" do
      program = "#{source.lines[0..10].join}p C.new.foo\np C.ancestors.first(5)\n"
      printed = RubyRun.stdout(program, prelude: concern_shim)

      expect(printed).to eq("\"M\"\n[C, A, M, Concern, Base]\n")
    end

    # C2-b1 migrated the instance typing read: the unsettled chain answers `UNKNOWN`, `C.new.foo` types `Dynamic` and
    # the `upcase` on line 13 is silent (it was a false positive: Ruby's `C.new.foo` is "M"); line 12 is the control
    # (`Kc` has no concern, `Base#foo` is an Integer).
    it "reports only the control" do
      expect(diagnostics_for(source)).to eq([[12, "call.undefined-method"]])
    end
  end

  # ADR-119 C2-b1 — the instance typing read answers from a definer only where the chain stands for the name. A
  # conditional `def` contests the slot (C1d-a's siblings), so the call types `Dynamic`; Ruby's answer depends on a
  # world the file cannot name, and the String of the unconditional `def` is right in only one of them.
  describe "the typing read declines on a conditional definer (C2-b1)" do
    let(:source) do
      <<~RUBY
        class C
          def foo = "a"
          def foo = 1 if ENV["RIGOR_X"]
        end
        C.new.foo.upcase
        Plain = Struct.new(:x)
        Plain.new(1).x.upcase
      RUBY
    end

    it "runs both worlds under Ruby" do
      body = source.lines[0..3].join
      expect(RubyRun.stdout("#{body}p C.new.foo\n")).to eq("\"a\"\n")
      expect(RubyRun.stdout("ENV[\"RIGOR_X\"] = \"1\"\n#{body}p C.new.foo\n")).to eq("1\n")
    end

    it "types the call Dynamic, with the unrelated control still firing" do
      expect(diagnostics_for(source)).to eq([[7, "call.undefined-method"]])
    end
  end

  # The same shape with an unconditional `def` still types: the migration silences only what the chain cannot
  # stand for.
  it "still types a call through an unconditional definer (C2-b1)" do
    expect(diagnostics_for(<<~RUBY)).to eq([[4, "call.undefined-method"]])
      class C
        def foo = 1
      end
      C.new.foo.upcase
    RUBY
  end
end
