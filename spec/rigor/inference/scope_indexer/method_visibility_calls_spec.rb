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

  it "contests the instance slot a wrapped `def self.x` names" do
    expect(tables(<<~RUBY)).to eq([{ "K" => { x: :public } }, Set[["K", :x]]])
      class K
        def x = 1
        private def self.x = 1
      end
    RUBY
  end

  it "contests a conditional wrapped def and a def nested under another call" do
    expect(tables(<<~RUBY)).to eq([{ "K" => { x: :private, m: :public, y: :public } }, Set[["K", :x], ["K", :m]]])
      class K
        private def x = 1 if RUBY_VERSION > "3"
        private memoize def m = 1
        def y = 1
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

  it "records nothing instance-side for `class << self`, `private_class_method` or an instance_eval body" do
    expect(table(<<~RUBY)).to eq("K" => { a: :private })
      class K
        class << self
          private def s = 1
          attr_reader :sr
        end
        private
        private_class_method def self.c = 1
        def a = 1
      end
      K.instance_eval { private attr_reader :ie }
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

  it "keeps the named module_function form as before (#1569 owns its visibility)" do
    expect(table(<<~RUBY)).to eq("M" => { mf: :public, after: :public })
      module M
        module_function def mf = 1
        def after = 1
      end
    RUBY
  end
end
