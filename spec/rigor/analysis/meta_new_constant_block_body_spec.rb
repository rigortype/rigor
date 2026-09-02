# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Issue #590 — `Const = Struct.new(:text) do … end` evaluates its block as a CLASS BODY, exactly like the bare
# `Struct.new(:text) do … end` #319 re-homed, but the constant-write rvalue never reached that arm: the
# `StatementEvaluator` had no handler for a constant write, so the block body was never walked and
# `ScopeIndexer.propagate` handed every node inside the ENCLOSING scope. At file top level that is a nil `self_type`,
# so `Scope#toplevel?` held inside every `def` of the body and `call.unresolved-toplevel` fired on the struct's own
# member reads — the `text` in `def shout; text.upcase; end` — and on `attr_reader` in a `Const = Class.new do` body,
# the very macro #319 silenced at every other position. Inside a module the body borrowed the module's `self`
# instead: a wrong receiver that merely happened to stay silent.
#
# The fix enters the body under the constant's qualified name — the key `ScopeIndexer` already files the body's defs
# and member layout under — and, for the `Struct.new` / `Data.define` block forms, registers the members as discovered
# readers the way `class X < Struct.new(...)` always did, so a member that shadows a `Kernel` private (`lambda`)
# resolves as the struct's reader rather than as `Kernel#lambda`. Every silence below is paired with a still-fires
# sibling: the rules involved are the ones the fix touches, and a silence-only spec passes on a build that stopped
# running them.
RSpec.describe "meta-new block body at constant-write position" do
  def diagnostics_for(source)
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(lib)
      File.write(File.join(lib, "a.rb"), source)
      Rigor::Analysis::Runner.new(
        configuration: Rigor::Configuration.new("paths" => [lib]),
        cache_store: nil
      ).run.diagnostics.reject { |d| d.path.to_s.end_with?(".rigor.yml") }
    end
  end

  def rules_for(source) = diagnostics_for(source).map(&:rule)

  it "reports nothing for the issue's repro" do
    expect(diagnostics_for(<<~RUBY).map(&:message)).to be_empty
      Line = Struct.new(:text) do
        def shout
          text.upcase
        end
      end
      p Line.new("a").shout
    RUBY
  end

  it "treats member reads, the member setter and a singleton def as the struct class's own" do
    expect(rules_for(<<~RUBY)).not_to include("call.unresolved-toplevel")
      Line = Struct.new(:text) do
        def shout
          text.upcase
        end

        def rename(value)
          self.text = value
        end

        def self.build
          new("a")
        end
      end
      p Line
    RUBY
  end

  it "treats a class-level macro in a Class.new constant body as a macro, not a toplevel call" do
    expect(rules_for(<<~RUBY)).not_to include("call.unresolved-toplevel")
      Observer = Class.new do
        attr_reader :count
      end
      p Observer
    RUBY
  end

  it "enters a Data.define constant body the same way" do
    expect(rules_for(<<~RUBY)).not_to include("call.unresolved-toplevel")
      Point = Data.define(:x) do
        def shout
          x.to_s
        end
      end
      p Point
    RUBY
  end

  it "enters a constant-path write's body under the call site's anonymous name" do
    expect(rules_for(<<~RUBY)).not_to include("call.unresolved-toplevel")
      module Outer; end
      Outer::Line = Struct.new(:text) do
        def shout
          text.upcase
        end
      end
      p Outer::Line
    RUBY
  end

  # ADR-34 keeps the rule out of class bodies (ADR-24 WD3 leniency): the constant-write body is now the same class
  # body its bare-expression and `class X < Struct.new` spellings always were, so an unknown name inside a `def` there
  # is exactly as lenient as in those — the fix does not trade one inconsistency for another.
  it "leaves an unknown name inside a body def as lenient as the bare-expression form" do
    constant_form = rules_for(<<~RUBY)
      Line = Struct.new(:text) do
        def go
          totally_unknown
        end
      end
      p Line
    RUBY
    bare_form = rules_for(<<~RUBY)
      Struct.new(:text) do
        def go
          totally_unknown
        end
      end
    RUBY

    expect(constant_form).not_to include("call.unresolved-toplevel")
    expect(bare_form).not_to include("call.unresolved-toplevel")
  end

  # The instrument can say "yes": the #316 DSL-block control — a block whose `self` nothing models — still warns on
  # an unknown name inside its def, and a genuine toplevel macro call still warns too.
  it "still warns about an unknown call inside a plain DSL block's def" do
    unresolved = diagnostics_for(<<~RUBY).select { |d| d.rule == "call.unresolved-toplevel" }
      describe_thing do
        def helper
          totally_unknown
        end
      end
    RUBY

    expect(unresolved.map(&:message)).to include(/`totally_unknown`/)
  end

  it "still warns about a real toplevel macro call" do
    expect(rules_for("attr_reader :count")).to include("call.unresolved-toplevel")
  end

  it "still checks the statements inside the constant body" do
    expect(rules_for(<<~RUBY)).to include("call.wrong-arity")
      Line = Struct.new(:text) do
        def shout
          Object.new(1)
        end
      end
      p Line
    RUBY
  end

  describe "member readers in the discovered-methods table" do
    it "resolves a member that shadows a Kernel private through the struct, not Kernel" do
      expect(rules_for(<<~RUBY)).not_to include("call.undefined-method")
        Line = Struct.new(:lambda) do
          def shout
            lambda.upcase
          end
        end
        p Line
      RUBY
    end

    it "does so for the anonymous block form too" do
      expect(rules_for(<<~RUBY)).not_to include("call.undefined-method")
        Struct.new(:lambda) do
          def shout
            lambda.upcase
          end
        end
      RUBY
    end

    # Same body, one member fewer: `lambda` is Kernel's again and yields a Proc, so the rule still fires.
    it "still reports the Kernel private when the name is not a member" do
      expect(diagnostics_for(<<~RUBY).map(&:message)).to include(/upcase.*Proc/)
        Line = Struct.new(:text) do
          def shout
            lambda.upcase
          end
        end
        p Line
      RUBY
    end
  end

  describe Rigor::Inference::ScopeIndexer do
    def index_and_program(source)
      program = Prism.parse(source).value
      [described_class.index(program, default_scope: Rigor::Scope.empty), program]
    end

    it "keys the body by the constant's qualified name, appended to the lexical context" do
      index, program = index_and_program(<<~RUBY)
        module Outer
          Line = Struct.new(:text) do
            def shout
              text.upcase
            end
          end
        end
      RUBY
      def_node = program.statements.body.first.body.body.first.value.block.body.body.first
      member_read = def_node.body.body.first.receiver
      scope = index[member_read]

      expect(scope.toplevel?).to be(false)
      expect(scope.self_type.describe(:short)).to eq("Outer::Line")
      expect(index[def_node].self_type.describe(:short)).to eq("singleton(Outer::Line)")
    end

    it "registers the members of a constant-write struct body as discovered readers" do
      index, program = index_and_program(<<~RUBY)
        Line = Struct.new(:text, :indent) do
          def shout
            text.upcase
          end
        end
      RUBY
      scope = index[program.statements.body.first]

      expect(scope.discovered_method?("Line", :text, :instance)).to be(true)
      expect(scope.discovered_method?("Line", :indent, :instance)).to be(true)
      expect(scope.discovered_method?("Line", :shout, :instance)).to be(true)
    end

    it "registers the members of an anonymous struct body under the call site's synthetic name" do
      index, program = index_and_program(<<~RUBY)
        klass = Struct.new(:text) do
          def shout
            text.upcase
          end
        end
      RUBY
      call = program.statements.body.first.value
      scope = index[program.statements.body.first]
      name = Rigor::Inference::AnonymousMetaClass.name_for(call)

      expect(scope.discovered_method?(name, :text, :instance)).to be(true)
    end

    # A body the ScopeIndexer's stricter argument check does not key by the constant (`Struct.new(*names)`) is
    # registered under the anonymous name, and the walk must enter it under that same name — the two passes agree
    # because the walk asks the ScopeIndexer's own recognition instead of re-spelling it.
    it "enters a splat-member constant body under the anonymous name the ScopeIndexer used" do
      index, program = index_and_program(<<~RUBY)
        names = [:text]
        Line = Struct.new(*names) do
          def shout
            1
          end
        end
      RUBY
      write = program.statements.body[1]
      def_node = write.value.block.body.body.first
      name = Rigor::Inference::AnonymousMetaClass.name_for(write.value)

      expect(index[def_node.body].self_type).to eq(Rigor::Type::Combinator.nominal_of(name))
      expect(index[write].discovered_method?(name, :shout, :instance)).to be(true)
    end
  end
end
