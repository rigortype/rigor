# frozen_string_literal: true

# The `rigor check` reproductions of the false positives the breadth-first ancestor walks produced, each beside
# a control on the same file that must still fire — so a run that analysed nothing cannot pass by reporting
# nothing. `spec/integration/resolution_chain_witness_spec.rb` compares the same shapes with Ruby. #1570's
# shape is pinned where the chain's two worlds leave it: at master's answer.

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

  # Flip this when ADR-119 PR C fixes #1570 at `SourceArity`'s decision point. Ruby skips `C`'s `include M`
  # (`Base` already carries it), so `C.new.foo` is `Base#foo` and correct; but the tables cannot tell that run
  # from one where `Base` was reopened to include `M` after `C` did (`[C, M, Base, M]`, `M#foo(x)`), the two
  # worlds disagree, and the rule keeps master's answer, which checks the call against `M#foo`. PR C makes
  # that disagreement answer `Unknown`, so line 19 goes silent. Line 20 is the control.
  it "keeps master's answer for an include of a module the superclass already includes (#1570)" do
    expect(diagnostics_for(<<~RUBY)).to eq([[19, "call.wrong-arity"], [20, "call.wrong-arity"]])
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

  # `D#foo` reduces `M#foo` (line 17, master says so too); `E#foo` overrides the private `D#foo`, so the chain
  # that put `M` ahead of `D` reported a second reduction on `E#foo` that Ruby's `[E, A, D, C, M]` does not have.
  it "does not report a reduced override through the same prepend shape" do
    expect(diagnostics_for(<<~RUBY)).to eq([[17, "def.override-visibility-reduced"]])
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

    # Ruby, with `RIGOR_X` unset, never runs the include: `C.new.foo` is `Base#foo`, and `upcase` is missing.
    it "keeps master's answer for a conditional include" do
      expect(diagnostics_for(<<~RUBY)).to eq([[6, "call.undefined-method"]])
        #{prelude}class C < Base; include A if ENV["RIGOR_X"]; end

        C.new.foo.upcase
      RUBY
    end

    # `setup` is never called: `C.ancestors` is `[C, Base]` in Ruby.
    it "keeps master's answer for an include inside a method body" do
      expect(diagnostics_for(<<~RUBY)).to eq([[6, "call.undefined-method"]])
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

  it "keeps master's answer where a conditional include in the superclass makes the class's include a skip" do
    expect(diagnostics_for(<<~RUBY)).to eq([[16, "call.undefined-method"]])
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
end
