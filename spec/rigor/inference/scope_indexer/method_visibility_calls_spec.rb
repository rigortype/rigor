# frozen_string_literal: true

require "spec_helper"

# Issues #1911, #1819, #1633 — the method-visibility table (`ScopeIndexer.build_method_visibility_tables`) reads a
# `def` or `attr_*` passed to `private` / `protected` / `public` as written with that call's visibility, records the
# `attr_*` members under the running default, and applies the visibility calls Ruby runs on the body's self. Each
# expected table is Ruby 4.0.5's answer for the shape (`spec/integration/fixtures/declaration_witness/
# visibility_calls.rb` runs the same shapes under Ruby); a slot the walk cannot place is contested instead.
RSpec.describe "the method-visibility table over visibility calls (#1911, #1819, #1633)" do
  def tables(source)
    table, contested = Rigor::Inference::ScopeIndexer.build_method_visibility_tables(Prism.parse(source).value)
    [table, contested.to_set]
  end

  def table(source) = tables(source).first

  it "records a wrapped def with the call's visibility, endless or not, and keeps the default after it" do
    expect(table(<<~RUBY)).to eq("K" => { kp: :private, secret: :private, after: :public })
      class K
        private def kp; end
        private def secret = 1
        def after = 1
      end
    RUBY
  end

  it "records `public def` under a bare `private` as public, and the next def private" do
    expect(table(<<~RUBY)).to eq("K" => { foo: :public, bar: :private })
      class K
        private
        public def foo = 1
        def bar = 1
      end
    RUBY
  end

  it "records protected and private wrapped defs and attrs" do
    expect(table(<<~RUBY)).to eq("K" => { pt: :protected, r: :protected, x: :private, "x=": :private })
      class K
        protected def pt = 1
        protected attr_reader :r
        private attr_accessor :x
      end
    RUBY
  end

  it "records attr members under the running default and honours a later `private :name`" do
    expect(table(<<~RUBY)).to eq("K" => { plain: :public, "w=": :private, name: :private, "name=": :public })
      class K
        attr_reader :plain
        private
        attr_writer :w
        public
        attr_accessor :name
        private :name
      end
    RUBY
  end

  it "applies a literal list of names" do
    expect(table(<<~RUBY)).to eq("K" => { a: :private, b: :private })
      class K
        def a = 1
        def b = 1
        private %i[a]
        private [:b]
      end
    RUBY
  end

  {
    "a block" => "private {}",
    "a self receiver" => "self.private",
    "send" => "send(:private)",
    "__send__" => "__send__(:private)"
  }.each do |label, toggle|
    it "applies a bare toggle written with #{label}" do
      expect(tables("class K\n  #{toggle}\n  def a = 1\nend\n")).to eq([{ "K" => { a: :private } }, Set[]])
    end
  end

  it "applies a def wrapped through send or a self receiver" do
    expect(table(<<~RUBY)).to eq("K" => { a: :private, b: :private, c: :public })
      class K
        send(:private, def a = 1)
        self.private def b = 1
        def c = 1
      end
    RUBY
  end

  it "contests the earlier slots and the later defs after a splat" do
    expect(tables(<<~RUBY)).to eq([{ "K" => { zz: :public, a: :public } }, Set[["K", :zz], ["K", :a]]])
      class K
        def zz = 1
        private(*[:zz])
        def a = 1
      end
    RUBY
  end

  # Ruby: `K.x` is public (the `def self.x` is a public singleton method; `private` reaches the instance `x`).
  it "contests the instance slot a wrapped `def self.x` names" do
    expect(tables(<<~RUBY)).to eq([{ "K" => { x: :public, %i[singleton x] => :public } }, Set[["K", :x]]])
      class K
        def x = 1
        private def self.x = 1
      end
    RUBY
  end

  it "contests a conditional wrapped def and a def nested under another call or a list" do
    expect(tables(<<~RUBY))
      class K
        private def x = 1 if RUBY_VERSION > "3"
        private memoize def m = 1
        private [def n = 1]
        def y = 1
      end
    RUBY
      .to eq([{ "K" => { x: :private, m: :public, n: :public, y: :public } }, Set[["K", :x], ["K", :m], ["K", :n]]])
  end

  # Ruby: after a toggle the walk cannot place, a later bare def's visibility is unknown, while a wrapped def or attr
  # still takes its wrapper's.
  it "does not contest a wrapped def or attr after an uncertain toggle" do
    expect(tables(<<~RUBY)).to eq([{ "K" => { a: :public, x: :public, r: :private } }, Set[["K", :a]]])
      class K
        [1].each { private }
        def a = 1
        public def x = 1
        private attr_reader :r
      end
    RUBY
  end

  it "contests an attr written under a condition" do
    expect(tables(<<~RUBY)).to eq([{ "K" => { r: :public } }, Set[["K", :r]]])
      class K
        attr_reader :r if RUBY_VERSION > "3"
      end
    RUBY
  end

  # Issue #1984 — what they record lands on the singleton slots. Ruby: `K.s`, `K.c` private, `K.sr` public.
  it "records nothing instance-side for `class << self`, `private_class_method` or an instance_eval body" do
    expected = { "K" => { a: :private, %i[singleton s] => :private, %i[singleton sr] => :public,
                          %i[singleton c] => :private } }
    expect(table(<<~RUBY)).to eq(expected)
      class K
        class << self
          private def s = 1
          attr_reader :sr
        end
        private
        private_class_method def self.c = 1
        def a = 1
      end
      K.instance_eval do
        attr_reader :ie
        private attr_reader :pie
      end
    RUBY
  end

  # Issue #1984 — a splat names members of its own side only: `private(*names)` the instance slots,
  # `private_class_method(*names)` the singleton ones.
  it "contests only the splatted side's slots" do
    expect(tables(<<~RUBY).last).to eq(Set[["I", :i], ["S", %i[singleton s]]])
      class I
        def self.s = 1
        def i = 1
        private(*NAMES)
      end
      class S
        def self.s = 1
        def i = 1
        private_class_method(*NAMES)
      end
    RUBY
  end

  # Issue #1984 — Ruby makes each `x` public again (`define_singleton_method`, `singleton_class.send(:public, :x)`,
  # an `instance_eval` def and `def K.x` define or mark it public); the walk reads none of them, so it contests the
  # singleton slot instead of keeping the private it recorded.
  it "contests the singleton slots a rewrite the walk does not read" do
    expected = Set[["D", %i[singleton x]], ["S", %i[singleton x]], ["S", %i[singleton public]],
                   ["E", %i[singleton x]], ["F", %i[singleton x]]]
    expect(tables(<<~RUBY).last).to eq(expected)
      class D; private_class_method def self.x = 1; define_singleton_method(:x) { 2 }; end
      class S; private_class_method def self.x = 1; singleton_class.send(:public, :x); end
      class E; private_class_method def self.x = 1; end
      E.instance_eval { def x = 2 }
      class F; private_class_method def self.x = 1; end
      def F.x = 2
    RUBY
  end

  it "records wrapped defs and attrs in a meta-new block" do
    expect(table(<<~RUBY)).to eq("W" => { sx: :private, sr: :private, sy: :public })
      W = Struct.new(:m) do
        private def sx = 1
        private attr_reader :sr
        def sy = 1
      end
    RUBY
  end

  # #1569 — Ruby makes a module function's instance copy private; the table is instance-side only, so the public
  # singleton copy is not in it. Each expected table is Ruby 4.0.5's `private_instance_methods(false)` answer.
  describe "module_function (#1569)" do
    it "records `module_function def x` private and leaves the default after it" do
      expect(table(<<~RUBY)).to eq("M" => { mf: :private, after: :public })
        module M
          module_function def mf = 1
          def after = 1
        end
      RUBY
    end

    it "records the defs and attr members after a bare module_function private" do
      expect(tables(<<~RUBY)).to eq([{ "M" => { a: :private, r: :private } }, Set[]])
        module M
          module_function
          def a = 1
          attr_reader :r
        end
      RUBY
    end

    it "records a name `module_function :x` names private at the call, and a later def with the default" do
      expect(table(<<~RUBY)).to eq("M" => { a: :private, b: :public, c: :private })
        module M
          def a = 1
          def b = 1
          def c = 1
          module_function :a, "c"
          def b = 2
        end
      RUBY
    end

    it "applies the module_function forms written on self or sent with a literal name" do
      expect(table(<<~RUBY)).to eq("M" => { a: :private }, "N" => { b: :private })
        module M
          self.module_function
          def a = 1
        end
        module N
          send(:module_function)
          def b = 1
        end
      RUBY
    end

    it "ends the private default at a bare public or protected, and records `public def` public" do
      expect(table(<<~RUBY)).to eq("M" => { x: :public, y: :private, z: :public }, "P" => { w: :protected })
        module M
          module_function
          public def x = 1
          def y = 1
          public
          def z = 1
        end
        module P
          module_function
          protected
          def w = 1
        end
      RUBY
    end

    it "contests a def after a bare public that may not run, rather than recording it public" do
      expect(tables(<<~RUBY)).to eq([{ "M" => { k: :private } }, Set[["M", :k]]])
        module M
          module_function
          public if ENV["X"]
          def k = 1
        end
      RUBY
    end

    # Issue #1984 — `private_class_method :d` records the singleton slot. Ruby: `M.d` is private.
    it "leaves the instance slot alone at extend self and private_class_method" do
      expect(tables(<<~RUBY)).to eq([{ "M" => { d: :private, %i[singleton d] => :private } }, Set[]])
        module M
          extend self
          module_function
          def d = 1
          private_class_method :d
        end
      RUBY
    end
  end
end
