# frozen_string_literal: true

require "spec_helper"

# Issue #1984 — `def.method-visibility-mismatch` on a class-object receiver (`K.x`) reads the singleton side of the
# visibility table: `private_class_method`, `class << self` with `private`, and their reversals. Each row's comment is
# Ruby 4.0.5's answer for the call (`ruby -e`), NoMethodError being the private call Ruby rejects. The rule reports only
# a constant receiver called from inside a `def`, so most calls below sit in `def run`.
RSpec.describe "def.method-visibility-mismatch on singleton calls (#1984)", type: :runner do
  def mismatches(source = nil, files: {})
    analyze(source, files: files).diagnostics.select { |d| d.rule == "def.method-visibility-mismatch" }
                                 .map { |d| [File.basename(d.path), d.line] }
  end

  def rules(source)
    analyze(source).diagnostics.map { |d| [d.rule, d.line] }
  end

  # Ruby: each `K.x` raises NoMethodError (private method 'x' called for class K).
  {
    "private_class_method :x" => "class K; def self.x = 1; private_class_method :x; end",
    "private_class_method def self.x" => "class K; private_class_method def self.x = 1; end",
    "a string name" => "class K; def self.x = 1; private_class_method \"x\"; end",
    "a list of names" => "class K; def self.x = 1; private_class_method [:x]; end",
    "a bare private in class << self" => "class K\n  class << self\n    private\n    def x = 1\n  end\nend",
    "a wrapping private in class << self" => "class K\n  class << self\n    private def x = 1\n  end\nend",
    "a named private in class << self" => "class K\n  class << self\n    def x = 1\n    private :x\n  end\nend",
    "an attr under a bare private in class << self" =>
      "class K\n  class << self\n    private\n    attr_reader :x\n  end\nend",
    "send(:private_class_method, :x)" => "class K; def self.x = 1; send(:private_class_method, :x); end"
  }.each do |label, declaration|
    it "reports K.x after #{label}" do
      expect(mismatches("#{declaration}\ndef run = K.x\n")).to eq([["code.rb", declaration.count("\n") + 2]])
    end
  end

  # Ruby: `Base.new`, `Base.y` (whose body calls `Base.x` explicitly) and `Sub.x` (the inherited private `Base.x`)
  # raise NoMethodError.
  it "reports `private_class_method :new`, an explicit receiver inside the class, and an inherited private method" do
    expect(mismatches(<<~RUBY)).to eq([["code.rb", 4], ["code.rb", 8], ["code.rb", 9]])
      class Base
        private_class_method :new
        def self.x = 1
        def self.y = Base.x
        private_class_method :x
      end
      class Sub < Base; end
      def build = Base.new
      def sub_x = Sub.x
    RUBY
  end

  # Ruby: each `K.x` returns normally.
  {
    "a def self.x under a bare private" => "class K; private; def self.x = 1; end",
    "a def self.x under a bare protected" => "class K; protected; def self.x = 1; end",
    "a later public_class_method" => "class K; private_class_method def self.x = 1; public_class_method :x; end",
    "a later def self.x" => "class K; private_class_method def self.x = 1; def self.x = 2; end",
    "a later define_singleton_method" =>
      "class K; private_class_method def self.x = 1; define_singleton_method(:x) { 3 }; end",
    "singleton_class.send(:public, :x)" =>
      "class K; private_class_method def self.x = 1; singleton_class.send(:public, :x); end",
    "singleton_class.class_eval { public :x }" =>
      "class K; private_class_method def self.x = 1; singleton_class.class_eval { public :x }; end",
    "a later public :x in class << self" =>
      "class K; private_class_method def self.x = 1; class << self; public :x; end; end",
    "an instance_eval def" => "class K; private_class_method def self.x = 1; end\nK.instance_eval { def x = 5 }",
    "a def K.x outside the class" => "class K; private_class_method def self.x = 1; end\ndef K.x = 6",
    "a subclass's public_class_method" =>
      "class P; private_class_method def self.x = 1; end\nclass K < P; public_class_method :x; end",
    "a module_function" => "module K; module_function; def x = 1; end",
    "a module_function in a module that extends itself" => "module K; extend self; module_function; def x = 1; end",
    "public_class_method def x (it names the singleton x)" =>
      "class K; private_class_method def self.x = 1; public_class_method def x = 2; end",
    "define_method in class << self" => "class K; class << self; private def x = 1; define_method(:x) { 2 }; end; end",
    "an alias in class << self" => "class K; class << self; private def x = 1; def y = 2; alias x y; end; end",
    "K.public_class_method(:x) outside the class" =>
      "class K; private_class_method def self.x = 1; end\nK.public_class_method(:x)",
    "K.send(:public_class_method, :x) outside the class" =>
      "class K; private_class_method def self.x = 1; end\nK.send(:public_class_method, :x)",
    "K.public_class_method(*names) outside the class" =>
      "class K; private_class_method def self.x = 1; end\nK.public_class_method(*NAMES)",
    "K.singleton_class.class_eval { public :x } outside the class" =>
      "class K; private_class_method def self.x = 1; end\nK.singleton_class.class_eval { public :x }",
    "class << K; public :x; end outside the class" =>
      "class K; private_class_method def self.x = 1; end\nclass << K; public :x; end"
  }.each do |label, declaration|
    it "is quiet on K.x after #{label}" do
      expect(mismatches("#{declaration}\ndef run = K.x\n")).to eq([])
    end
  end

  # Ruby: the rewrite in `z.rb` makes `K.x` public (it returns 2, or 1 for the `public_class_method` rows), so the call
  # in `run.rb` is quiet. The walk of `z.rb` writes no visibility of its own for `K.x`, so only a contest it leaves
  # (on the slot, or on K's wildcard singleton slot) can reach `k.rb`'s private one.
  {
    "K.public_class_method(*names)" => "NAMES = [:x]\nK.public_class_method(*NAMES)\n",
    "K.singleton_class.class_eval { public :x }" => "K.singleton_class.class_eval { public :x }\n",
    "define_method in a reopening's class << self" =>
      "class K\n  class << self\n    define_method(:x) { 2 }\n  end\nend\n",
    "an alias in a reopening's class << self" =>
      "class K\n  class << self\n    def y = 2\n    alias x y\n  end\nend\n"
  }.each do |label, rewrite|
    it "is quiet on K.x after #{label} in another file" do
      files = { "k.rb" => "class K\n  private_class_method def self.x = 1\nend\n", "z.rb" => rewrite,
                "run.rb" => "def run = K.x\n" }
      expect(mismatches(files: files)).to eq([])
    end
  end

  # Ruby: each constant below is built while the class body runs, before `private_class_method` / `private :x`, so
  # every call returns normally.
  it "is quiet on a call that runs while the class body loads" do
    expect(mismatches(<<~RUBY)).to eq([])
      class Enumy
        def initialize(n); end
        ALL = [Enumy.new(1), Enumy.new(2)].freeze
        private_class_method :new
      end
      class Suit
        def initialize(s); end
        HEARTS = Suit.new("h")
        private_class_method :new
      end
      class Mapped
        def initialize(n); end
        ALL = [1, 2].map { |n| Mapped.new(n) }
        private_class_method :new
      end
      class Sing2
        def self.x = 1
        V = Sing2.x
        class << self
          private :x
        end
      end
    RUBY
  end

  # Ruby: `self.class` may be a subclass that makes the name public again, so `VSub.new.copy` and
  # `Square.new.describe` return normally; `VBase.new` from a constant raises NoMethodError and is reported.
  it "reports only a constant receiver, not self.class" do
    expect(mismatches(<<~RUBY)).to eq([["code.rb", 13]])
      class VBase
        private_class_method :new
        def self.build = new
        def copy = self.class.new
      end
      class VSub < VBase; public_class_method :new; end
      class Shape
        def self.sides = raise("abstract")
        private_class_method :sides
        def describe = self.class.sides
      end
      class Square < Shape; def self.sides = 4; end
      def run = VBase.new
    RUBY
  end

  # Ruby: a singleton-class refinement in effect answers `Refd.x` (2), so the private call is not reported.
  it "is quiet where a refinement of the singleton class is in effect" do
    expect(mismatches(<<~RUBY)).to eq([])
      class Refd; private_class_method def self.x = 1; end
      module R
        refine Refd.singleton_class do
          def x = 2
        end
      end
      using R
      def run = Refd.x
    RUBY
  end

  # Ruby: an implicit `x`, `self.x` and `send(:x)` inside the class reach the private method.
  it "is quiet on calls the class makes on itself" do
    expect(mismatches(<<~RUBY)).to eq([])
      class K
        def self.x = 1
        private_class_method :x
        def self.implicit = x
        def self.on_self = self.x
        def self.sent = send(:x)
      end
      K.implicit
      K.on_self
      K.sent
    RUBY
  end

  # Ruby: `Hooked.x` and `Ghost.new.ip` reach `method_missing`, which answers; `Answering.x` raises NoMethodError (a
  # `respond_to_missing?` alone does not answer the call) and is still declined, as the issue asks.
  it "declines where a method_missing or respond_to_missing? sits on the chain, on either side" do
    expect(mismatches(<<~RUBY)).to eq([])
      class Hooked
        private_class_method def self.x = 1
        def self.method_missing(name, *) = name
      end
      class Answering
        def self.x = 1
        private_class_method :x
        def self.respond_to_missing?(*) = true
      end
      class Ghost
        private def ip = 1
        def method_missing(name, *) = name
      end
      def run
        Hooked.x
        Answering.x
        Ghost.new.ip
      end
    RUBY
  end

  # Ruby: `Maybe.x`, `Toggled.x` and `Possibly.x` depend on `rand`; the walk cannot place them, so the rule declines.
  it "declines where a reversal or a toggle may not run" do
    expect(mismatches(<<~RUBY)).to eq([])
      class Maybe
        private_class_method def self.x = 1
        public_class_method :x if rand > 1
      end
      class Toggled
        class << self
          private if rand > 1
          def x = 1
        end
      end
      class Possibly
        def self.x = 1
        private_class_method :x if rand > 1
      end
      def run
        Maybe.x
        Toggled.x
        Possibly.x
      end
    RUBY
  end

  # Ruby: loading the private side first leaves `Split.x` public (the later `def self.x` redefines it), the other
  # order private; file order is not load order,
  # so the slot two files disagree on is contested in either order, also in the file that makes it private. `Lone.x`
  # is private wherever it is called from.
  it "declines a singleton slot two files disagree on, and reports one file's slot from another file" do
    private_side = "class Split\n  private_class_method def self.x = 1\nend\n" \
                   "class Lone\n  private_class_method def self.x = 1\nend\ndef here = Split.x\n"
    public_side = "class Split\n  def self.x = 2\nend\n"
    [%w[a.rb b.rb], %w[b.rb a.rb]].each do |private_file, public_file|
      files = { private_file => private_side, public_file => public_side,
                "z.rb" => "def a = Split.x\ndef b = Lone.x\n" }
      expect(mismatches(files: files)).to eq([["z.rb", 2]])
    end
  end

  # Issue #2059 — Ruby raises NoMethodError (private method) on `Pcm.two(1)` and `Es.two(1)`, so the private call is
  # reported rather than `call.wrong-arity`; `Helpers.two(1)` is a module function's public copy and raises
  # ArgumentError, which stays `call.wrong-arity`.
  it "reports the private call, not the arity, on a private singleton method" do
    expect(rules(<<~RUBY).select { |rule, _| rule.start_with?("call.wrong-arity", "def.method-visibility") })
      class Pcm; def self.two(a, b) = a; private_class_method :two; end
      module Es; extend self; private def two(a, b) = a; end
      module Helpers; module_function; def two(a, b) = a; end
      def a = Pcm.two(1)
      def b = Es.two(1)
      def c = Helpers.two(1)
    RUBY
      .to eq([["def.method-visibility-mismatch", 4], ["def.method-visibility-mismatch", 5], ["call.wrong-arity", 6]])
  end

  # #2059's third shape. Ruby raises NoMethodError (private method) on `UsesExt.ex(1)`, a private method of an
  # extended module: the private call is reported and the arity is not. The singleton read can still decline on the
  # extends fold's copy (`SingletonHookDecline.copy_kind` answers `:stray` when the copy is not the module's own
  # node), and then the arity is reported instead. Where the visibility rule declines for its own reasons (a call that
  # runs while the files load, a receiver that is not a constant) and the arity check reads the method as private,
  # neither reports.
  it "reports a private method of an extended module as the private call" do
    files = {
      "ext.rb" => "module Ext\n  private def ex(a, b) = a\nend\nclass UsesExt\n  extend Ext\nend\n",
      "call.rb" => "def run = UsesExt.ex(1)\n"
    }
    found = analyze(files: files).diagnostics.map { |d| [d.rule, File.basename(d.path), d.line] }
    expect(found.select { |rule, _| rule.start_with?("call.wrong-arity", "def.method-visibility") })
      .to eq([["def.method-visibility-mismatch", "call.rb", 1]])
  end
end
