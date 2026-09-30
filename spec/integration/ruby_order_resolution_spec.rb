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
