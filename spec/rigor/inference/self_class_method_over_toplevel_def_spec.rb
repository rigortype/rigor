# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Issue #618 — `ExpressionTyper#try_local_def_dispatch` bound a same-named top-level `def` for EVERY
# implicit-self call, ahead of the receiver class's own methods and whatever `scope.self_type` said. A
# top-level `def` is a private method on `Object`, the last link of every MRO, so a class that carries the
# name wins at runtime and the top-level body is never reached; binding it first inverted that. The issue's
# repro is a struct member — a top-level `def text` typed the `text` inside
# `class Line < Struct.new(:text); def shout; text.upcase; end; end` as the def's `nil` and fired
# `undefined method 'upcase' for nil` on correct Ruby — but the inversion covered every source of a method
# name: `attr_reader`, an inherited `def`, an included module's `def`, an RBS declaration on the class.
#
# The veto is `ExpressionTyper#self_type_answers?`, and it is scoped to a `self` whose class is KNOWN. At
# genuine top level, and inside a block whose `self` is unmodelled, `scope.self_type` is nil and the
# historical binding stands untouched — #316's / #319's territory, pinned by the must-still-bind half below
# and by spec/rigor/analysis/toplevel_def_dsl_block_capture_spec.rb.
RSpec.describe "a class's own method beats a top-level def of the same name" do
  def diagnostics_for(files, signatures: {})
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(lib)
      files.each { |name, source| File.write(File.join(lib, name), source) }
      runner = Rigor::Analysis::Runner.new(
        configuration: Rigor::Configuration.new(config_for(dir, lib, signatures)),
        cache_store: nil
      )
      guarded_run(runner).diagnostics.reject { |d| d.path.to_s.end_with?(".rigor.yml") }
    end
  end

  def config_for(dir, lib, signatures)
    return { "paths" => [lib] } if signatures.empty?

    sig = File.join(dir, "sig")
    FileUtils.mkdir_p(sig)
    signatures.each { |name, source| File.write(File.join(sig, name), source) }
    { "paths" => [lib], "signature_paths" => [sig] }
  end

  def messages_for(...) = diagnostics_for(...).map(&:message)

  # The shadowing top-level def, in its own file so nothing about the repro depends on collocation.
  def shadow_source = <<~RUBY
    def text
      nil
    end
  RUBY

  def upcase_errors(source, signatures: {})
    messages_for({ "shadow.rb" => shadow_source, "subject.rb" => source }, signatures: signatures)
      .grep(/upcase/)
  end

  # --- the member / own-method wins (the issue's false positives) -------------------------------------

  it "reads a struct member declared by the `class X < Struct.new(...)` spelling" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      class Line < Struct.new(:text)
        def shout
          text.upcase
        end
      end
    RUBY
  end

  # The issue's own repro shape. It needs both halves: #619 enters the constant-assigned block as the
  # class's body (so the call has a `self_type` at all, keyed by the constant) and registers the members as
  # discovered readers; the veto here is what stops the top-level `def text` being consulted ahead of them.
  it "reads a struct member inside a `Const = Struct.new(...) do ... end` body" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      Line = Struct.new(:text) do
        def shout
          text.upcase
        end
      end
    RUBY
  end

  it "reads a Data member inside a `Const = Data.define(...) do ... end` body" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      Pt = Data.define(:text) do
        def shout
          text.upcase
        end
      end
    RUBY
  end

  it "reads a struct member inside a `Const = Class.new(Struct.new(...)) do ... end` body (#634)" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      Line = Class.new(Struct.new(:text)) do
        def shout
          text.upcase
        end
      end
    RUBY
  end

  it "reads a Data member inside a `Const = Class.new(Data.define(...)) do ... end` body (#634)" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      Pt = Class.new(Data.define(:text)) do
        def shout
          text.upcase
        end
      end
    RUBY
  end

  it "reads a struct member inside an anonymous `Class.new(Struct.new(...)) do ... end` body (#634)" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      Class.new(Struct.new(:text)) do
        def shout
          text.upcase
        end
      end
    RUBY
  end

  it "reads a struct member declared by `Const = Class.new(Struct.new(...))` and reopened (#634)" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      Point = Class.new(Struct.new(:text))

      class Point
        def shout
          text.upcase
        end
      end
    RUBY
  end

  it "reads a struct member declared by the constant spelling and reopened" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      Point = Struct.new(:text)

      class Point
        def shout
          text.upcase
        end
      end
    RUBY
  end

  it "reads a Data member declared by the constant spelling and reopened" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      Pt = Data.define(:text)

      class Pt
        def shout
          text.upcase
        end
      end
    RUBY
  end

  it "reads an attr_reader declared in a plain class" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      class Plain
        attr_reader :text

        def initialize(value)
          @text = value
        end

        def shout
          text.upcase
        end
      end
    RUBY
  end

  it "reads a method inherited from a project superclass" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      class Base
        def text
          "base"
        end
      end

      class Derived < Base
        def shout
          text.upcase
        end
      end
    RUBY
  end

  it "reads a method contributed by an included module" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      module Textual
        def text
          "mixin"
        end
      end

      class Mixed
        include Textual

        def shout
          text.upcase
        end
      end
    RUBY
  end

  it "reads a method the project's own RBS declares on the class" do
    signatures = { "widget.rbs" => <<~RBS }
      class Widget
        def text: () -> String
      end
    RBS

    expect(upcase_errors(<<~RUBY, signatures: signatures)).to be_empty
      class Widget
        def shout
          text.upcase
        end
      end
    RUBY
  end

  it "reads a class method from the class body's own singleton self" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      class ClassSide
        def self.text
          "cls"
        end

        SHOUTED = text.upcase
      end
    RUBY
  end

  # --- must still bind: the top-level def is still the answer where nothing else defines the name --------
  #
  # Each of these is the paired positive of the silences above: the same top-level `def text` returning nil,
  # the same `.upcase` on it, and the diagnostic still fires — so none of the examples above can pass on a
  # build that merely stopped binding top-level defs (or stopped analyzing) altogether.

  it "still binds a top-level def inside a class that does not define the name" do
    expect(upcase_errors(<<~RUBY)).not_to be_empty
      class Consumer
        def shout
          text.upcase
        end
      end
    RUBY
  end

  it "still binds a top-level def in a class BODY whose class does not define the name" do
    expect(upcase_errors(<<~RUBY)).not_to be_empty
      class Consumer
        SHOUTED = text.upcase
      end
    RUBY
  end

  it "still binds a top-level def collocated with its DSL-block call site" do
    collocated = <<~RUBY
      def text
        nil
      end

      RSpec.describe "y" do
        it "uses it" do
          text.upcase
        end
      end
    RUBY

    expect(messages_for({ "same.rb" => collocated }).grep(/upcase/)).not_to be_empty
  end

  it "still binds a top-level def called from genuine top-level code" do
    expect(upcase_errors("text.upcase\n")).not_to be_empty
  end

  # The RBS veto stops at `::Object`, and this is what buys that cut-off: counting EVERY inherited
  # declaration would match every name on `Object` / `Kernel` and retract the binding v0.0.3 A exists for.
  # `Widget` is RBS-known but declares nothing of its own, so `inspect` resolves only through `Object` —
  # where the RBS return is `String`, which is what makes this a discriminating assertion rather than a
  # silence: a veto that counted that owner would answer `String` and the `upcase` error would vanish.
  it "does not treat an `Object`-owned RBS declaration as reaching before the top-level def" do
    signatures = { "widget.rbs" => <<~RBS }
      class Widget
      end
    RBS

    files = { "shadow.rb" => <<~SHADOW, "subject.rb" => <<~SUBJECT }
      def inspect
        nil
      end
    SHADOW
      class Widget
        def shout
          inspect.upcase
        end
      end
    SUBJECT

    expect(messages_for(files, signatures: signatures).grep(/upcase/)).not_to be_empty
  end
  # --- issue #633: the sources the veto did not reach -------------------------------------------------
  #
  # Each pairs a must-not-fire with the must-still-fire arm one file below it, so a build that simply
  # stopped binding top-level defs cannot pass the pair.

  it "reads an `attr_accessor` inherited from a project superclass" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      class Base
        attr_accessor :text

        def initialize
          @text = "s"
        end
      end

      class Sub < Base
        def shout
          text.upcase
        end
      end
    RUBY
  end

  it "reads an `attr_reader` contributed by an included module" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      module Mixin
        attr_reader :text
      end

      class Sub
        include Mixin

        def shout
          text.upcase
        end
      end
    RUBY
  end

  it "reads a `define_method` inherited from a project superclass" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      class Base
        define_method(:text) { "s" }
      end

      class Sub < Base
        def shout
          text.upcase
        end
      end
    RUBY
  end

  it "still binds a top-level def in a subclass whose ancestors define nothing of the name" do
    expect(upcase_errors(<<~RUBY)).not_to be_empty
      class Base
        attr_accessor :other
      end

      class Sub < Base
        def shout
          text.upcase
        end
      end
    RUBY
  end

  # `Exception#message` is declared on an ancestor that precedes `::Object` in `MyErr`'s MRO, so Ruby
  # dispatches there and never reaches the top-level `def message`.
  it "reads an RBS method declared on a bundled superclass before ::Object" do
    files = { "shadow.rb" => <<~SHADOW, "subject.rb" => <<~SUBJECT }
      def message
        nil
      end
    SHADOW
      class MyErr < StandardError
        def shout
          message.upcase
        end
      end
    SUBJECT

    expect(messages_for(files).grep(/upcase/)).to be_empty
  end

  it "reads an RBS method declared on an included bundled module before ::Object" do
    files = { "shadow.rb" => <<~SHADOW, "subject.rb" => <<~SUBJECT }
      def clamp(low, high)
        nil
      end
    SHADOW
      class Cmp
        include Comparable

        def <=>(other)
          0
        end

        def within
          clamp(1, 2).to_s
        end
      end
    SUBJECT

    expect(messages_for(files).grep(/to_s/)).to be_empty
  end

  it "still binds a top-level def no bundled ancestor of the subclass declares" do
    files = { "shadow.rb" => <<~SHADOW, "subject.rb" => <<~SUBJECT }
      def text
        nil
      end
    SHADOW
      class MyErr < StandardError
        def shout
          text.upcase
        end
      end
    SUBJECT

    expect(messages_for(files).grep(/upcase/)).not_to be_empty
  end

  it "reads a `def self.` inherited from a project superclass, in the subclass body" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      class Base
        def self.text
          "b"
        end
      end

      class Sub < Base
        SHOUTED = text.upcase
      end
    RUBY
  end

  it "reads a `def self.` inherited from a project superclass, inside a class method" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      class Base
        def self.text
          "b"
        end
      end

      class Sub < Base
        def self.shout
          text.upcase
        end
      end
    RUBY
  end

  it "still binds a top-level def in a class method whose superclass has no such class method" do
    expect(upcase_errors(<<~RUBY)).not_to be_empty
      class Base
        def self.other
          "b"
        end
      end

      class Sub < Base
        def self.shout
          text.upcase
        end
      end
    RUBY
  end

  # --- `define_method` block self (issue #963 item 1) ------------------------------------------------
  #
  # `Module#define_method` turns its block into an INSTANCE method, and Ruby runs the body with `self`
  # bound to the receiving instance. The block still enters with `self` unmodelled, but the carrier it
  # inherited was the class body's `Singleton[C]` — the wrong side of the class — so the veto asked
  # whether `C.text` exists, found nothing, and let the top-level `def text` bind ahead of the reader.

  it "reads a struct member inside a `define_method` block in a `class X < Struct.new(...)` body" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      class Line < Struct.new(:text)
        define_method(:shout) { text.upcase }
      end
    RUBY
  end

  it "reads a struct member inside a `define_method` block in a `Const = Struct.new(...) do ... end` body" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      Line = Struct.new(:text) do
        define_method(:shout) { text.upcase }
      end
    RUBY
  end

  it "reads an attr_reader inside a `define_method` block" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      class Widget
        attr_reader :text

        define_method(:shout) { text.upcase }
      end
    RUBY
  end

  it "reads an attr_reader inside a `define_method` block that takes a parameter" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      class Widget
        attr_reader :text

        define_method(:shout) { |n| text.upcase * n }
      end
    RUBY
  end

  it "still binds a top-level def inside a `define_method` block when the class answers nothing" do
    expect(upcase_errors(<<~RUBY)).not_to be_empty
      class Widget
        attr_reader :other

        define_method(:shout) { text.upcase }
      end
    RUBY
  end

  # `class << self; define_method(:shout) { ... }; end` defines a CLASS method, whose `self` is the class
  # object — where an instance reader is NOT in the MRO. MRI reaches the top-level `def` there, and so
  # must Rigor: the narrowing is for the singleton class BODY only.
  it "still binds a top-level def inside a `define_method` block in a `class << self` body" do
    expect(upcase_errors(<<~RUBY)).not_to be_empty
      class Widget
        attr_reader :text

        class << self
          define_method(:shout) { text.upcase }
        end
      end
    RUBY
  end

  # ...and a `def` REACHED from that body is the other side of the same line. The singleton frame is still
  # on the stack, but `self` inside `def install` is the class object, so `define_method` there defines an
  # INSTANCE method and MRI runs the block on the instance — the shape the narrowing exists for.
  it "reads an attr_reader inside a `define_method` block in a def nested in `class << self`" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      class Widget
        attr_reader :text

        class << self
          def install
            define_method(:shout) { text.upcase }
          end
        end
      end
    RUBY
  end

  it "reads an attr_reader inside a `define_method` block in a `def self.` body" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      class Widget
        attr_reader :text

        def self.install
          define_method(:shout) { text.upcase }
        end
      end
    RUBY
  end

  # The one shape whose direction the narrowing CHANGES: `def self.text` answers the singleton side, which is
  # what the block used to be typed against. `define_method`'s block runs on an instance, where a class method
  # is not in the MRO, so the top-level `def` binds and the call reports — the same answer the plain-`def`
  # spelling has always given. This is the example a future regression of the narrowing would flip back.
  it "still binds a top-level def inside a `define_method` block when only a `def self.` answers the name" do
    expect(upcase_errors(<<~RUBY)).not_to be_empty
      class Cls
        def self.text
          "cls"
        end

        define_method(:shout) { text.upcase }
      end
    RUBY
  end

  # Both block-entry paths must decline on the same bodies. The `class << self` exclusion rides on
  # `Scope#singleton_class_body?`, so the return-typing pass — which has no frame stack of its own — applies it
  # too. A project-declared generic `define_method` makes the block's own value observable, and with the block's
  # `self` left on the singleton side the top-level `def text`'s `nil` is what it carries.
  it "keeps the return-typing path on the evaluator's side of a `class << self` body" do
    files = { "shadow.rb" => shadow_source, "subject.rb" => <<~SUBJECT }
      class Widget
        attr_reader :text

        class << self
          x = define_method(:shout) { text }
          x.upcase
        end
      end
    SUBJECT
    signatures = { "widget.rbs" => <<~RBS }
      class Widget
        def self.define_method: [T] (Symbol) { () -> T } -> T
        def text: () -> String
      end
    RBS

    expect(messages_for(files, signatures: signatures).grep(/upcase/)).not_to be_empty
  end

  # --- `Class.new(...) do ... end` (issue #963 item 1, second shape) ---------------------------------

  it "reads a struct member inside a `Const = Class.new(Struct.new(...)) do ... end` body" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      Anon = Class.new(Struct.new(:text)) do
        def shout
          text.upcase
        end
      end
    RUBY
  end

  it "reads a struct member inside a `define_method` block in a `Class.new(Struct.new(...))` body" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      Anon = Class.new(Struct.new(:text)) do
        define_method(:shout) { text.upcase }
      end
    RUBY
  end

  it "still binds a top-level def inside a `Class.new(...) do ... end` body answering nothing" do
    expect(upcase_errors(<<~RUBY)).not_to be_empty
      Anon = Class.new(Struct.new(:other)) do
        def shout
          text.upcase
        end
      end
    RUBY
  end

  # The control: a block whose `self` Rigor still does not model is untouched by the narrowing.
  it "leaves a plain block inside an instance method alone" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      class Widget
        attr_reader :text

        def run
          [1, 2].each { |n| text.upcase * n }
        end
      end
    RUBY
  end
end
