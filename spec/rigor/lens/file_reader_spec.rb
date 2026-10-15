# frozen_string_literal: true

require "prism"

require "rigor/lens"

RSpec.describe Rigor::Lens::FileReader do
  def read(source)
    described_class.new(path: "lib/x.rb", parse_result: Prism.parse(source), index: {}.compare_by_identity,
                        spell: ->(type, _owner) { type.erase_to_rbs }).read
  end

  def sites(source)
    read(source).sites.map(&:data)
  end

  def omissions(source)
    read(source).omissions.map { |omission| omission.values_at("kind", "name") }
  end

  describe "visibility" do
    let(:source) do
      <<~RUBY
        class K
          def a; end
          private def b; end
          attr_reader :c
          protected attr_writer :d
          private
          attr_accessor :e
          def f; end
          public def g; end
          def h; end
          private :h
          def self.i; end
          if $x
            public
          end
          def j; end
        end
      RUBY
    end

    it "follows Ruby's rules for wrappers, toggles, named calls and singleton defs" do
      visibilities = sites(source).filter_map { |site| [site["name"], site["visibility"]] if site["owner"] }.to_h

      expect(visibilities).to eq("a" => "public", "b" => "private", "c" => "public", "d" => "protected",
                                 "e" => "private", "f" => "private", "g" => "public", "h" => "private",
                                 "i" => "public", "j" => nil)
    end

    def visibilities_of(source)
      sites(source).filter_map { |site| [site["name"], site["visibility"]] if site["owner"] }.to_h
    end

    it "reads a member a named call in a method body names as unknown, and leaves the rest" do
      source = "class V\n  def b = 2\n  def c = 3\n  def self.configure\n    private :b\n  end\nend\n"

      expect(visibilities_of(source)).to include("b" => nil, "c" => "public", "configure" => "public")
    end

    it "reads a non-literal named call as making the body's members unknown" do
      source = "class V\n  def a = 1\n  protected(*NAMES)\n  def e = 5\nend\n"

      expect(visibilities_of(source)).to eq("a" => nil, "e" => nil)
    end

    it "keeps a toggle inside a block local to the block" do
      source = <<~RUBY
        class Foo
          configure do
            private
          end
          Point = Struct.new(:x) do
            private
            def helper; end
          end
          def bar; end
        end
      RUBY

      expect(visibilities_of(source)).to eq("x" => "public", "helper" => "private", "bar" => "public")
    end

    it "reads a literal array argument" do
      visibilities = sites("class V
  def a = 1
  private %i[a]
end
").to_h { |site| [site["name"], site["visibility"]] }

      expect(visibilities["a"]).to eq("private")
    end

    it "reads private wrapping a singleton def as unknown, which Ruby rejects" do
      site = sites("class V
  private def self.x = 1
end
").find { |data| data["name"] == "x" }

      expect(site["visibility"]).to be_nil
    end

    it "reads a top-level def as private on Object" do
      expect(sites("def helper = 1\n").first).to include("owner" => "Object", "visibility" => "private")
    end
  end

  describe "owners" do
    it "omits declarations whose owner revision 1 cannot name" do
      source = <<~RUBY
        class Outer
          class << self
            def meta; end
            def self.meta_meta; end
          end
          class self::Dyn; end
        end
        class << self
          def main_method; end
        end
        def self.top_singleton; end
      RUBY

      expect(sites(source).filter_map { |site| [site["owner"], site["scope"], site["name"]] if site["owner"] })
        .to eq([%w[Outer singleton meta]])
      expect(omissions(source)).to include(%w[method meta_meta], ["class", "self::Dyn"], ["singleton_class", nil],
                                           %w[method top_singleton])
    end

    it "walks the body of an omitted class" do
      expect(omissions("class W
  class self::Inner
    def hidden = 1
  end
end
")).to include(%w[method hidden])
    end

    it "qualifies nested and compact constant paths" do
      expect(sites("module A\n  class B::C; end\nend\nclass ::D; end\n").map { |site| site["name"] })
        .to eq(%w[A A::B::C D])
    end
  end

  describe "module_function" do
    let(:source) do
      <<~RUBY
        module U
          def before = 0
          module_function
          def a = 1
          def b(x) = x
          private
          def c = 2
        end
        module V
          def x = 1
          def y = 2
          module_function :x
          module_function def z = 3
          module_function :missing
        end
        class C
          module_function
          def k = 1
        end
        module W
          if $x
            module_function
          end
          def m = 1
        end
      RUBY
    end

    it "reads a def a module_function covers as one private site that is a module function" do
      rows = sites(source).filter_map do |site|
        [site["owner"], site["name"], site["module_function"], site["visibility"]] if site["kind"] == "method"
      end

      expect(rows).to contain_exactly(["U", "before", false, "public"], ["U", "a", true, "private"],
                                      ["U", "b", true, "private"], ["V", "x", false, nil],
                                      ["V", "y", false, "public"])
    end

    # The named forms read differently in Ruby and in check's singleton table (#1918 review), so they are
    # omissions, and the instance methods they name read unknown visibility.
    it "leaves the named forms and the defs it cannot read as module functions as omissions" do
      expect(omissions(source).filter_map { |kind, name| name if kind == "module_function" })
        .to contain_exactly("c", "x", "x", "z", "z", "missing", "missing", "k", "m")
    end

    it "lets private_class_method reach a module function's singleton copy" do
      site = sites("module Q\n  module_function\n  def q1 = 1\n  private_class_method :q1\nend\n")
             .find { |data| data["name"] == "q1" }

      expect(site).to include("module_function" => true, "visibility" => "private",
                              "singleton_visibility" => "private")
    end

    it "does not reuse the instance-scope return for a singleton copy whose body reads self or instance state" do
      source = "module P\n  module_function\n  def me = self\n  def iv = @x\n  def sp = super\n  def plain = 1\nend\n"
      returns = sites(source).filter_map do |data|
        [data["name"], data["singleton_body_return"]] if data["module_function"]
      end.to_h

      expect(returns["me"]).to eq("state" => "unavailable", "reason" => "not_computed")
      expect(returns["iv"]).to eq("state" => "unavailable", "reason" => "not_computed")
      expect(returns["sp"]).to eq("state" => "unavailable", "reason" => "not_computed")
      expect(returns["plain"]).to eq(sites(source).find { |data| data["name"] == "plain" }["body_return"])
    end
  end

  describe "Data.define and Struct.new" do
    let(:source) do
      <<~RUBY
        module X
          P = Data.define(:a, :b) do
            def m = 1
            private
            def hidden = 2
          end
          S = Struct.new(:c, keyword_init: true)
          N = Struct.new("Named", :d)
          D = Data.define(*FIELDS)
          E ||= Data.define(:e)
          F = Data.define(:f, &blk)
        end
      RUBY
    end

    it "reads a constant-assigned builder as a class with field attributes and its block as the body" do
      rows = sites(source).map { |site| site.values_at("kind", "owner", "name", "attribute", "builder", "visibility") }

      expect(rows).to eq([["module", nil, "X", nil, nil, nil],
                          ["class", nil, "X::P", nil, "data", nil],
                          ["attribute", "X::P", "a", "reader", nil, "public"],
                          ["attribute", "X::P", "b", "reader", nil, "public"],
                          ["method", "X::P", "m", nil, nil, "public"],
                          ["method", "X::P", "hidden", nil, nil, "private"],
                          ["class", nil, "X::S", nil, "struct", nil],
                          ["attribute", "X::S", "c", "accessor", nil, "public"]])
    end

    # #1927 review: Ruby class_evals the block, so a constant, class or module written there stays with the lexical
    # scope; a builder under class << self lands on the singleton class.
    it "omits declarations whose owner the builder block or a singleton body would misname" do
      source = <<~RUBY
        module X
          P = Data.define(:a) do
            class Inner; def inner_m = 1; end
            Q = Struct.new(:b)
            LIMIT = 1
          end
          class << self
            K = Data.define(:k)
            class Foo; end
          end
        end
      RUBY
      names = sites(source).map { |site| site["name"] }

      expect(names).to eq(%w[X X::P a])
      expect(omissions(source)).to include(%w[class Inner], %w[struct_class Q], %w[constant LIMIT], %w[data_class K],
                                           %w[class Foo])
    end

    it "models symbol fields only, with keyword_init alone, unique and valid names" do
      source = <<~RUBY
        T = Data.define("t")
        S = Struct.new(:c, "d")
        O = Struct.new(:o, foo: 1)
        Dup = Data.define(:a, :a)
        Bad = Struct.new(:"a=")
        Ok = Struct.new(:k, keyword_init: true)
        Pred = Data.define(:ok?, :x!)
      RUBY

      expect(sites(source).map { |site| site["name"] }).to eq(%w[Ok k Pred ok? x!])
    end

    it "reads a field's own trailing #: on a multi-line call, and nothing of the constant's comments" do
      typed = "# @rbs inherits Data\nP = Data.define(\n  :a, #: Integer\n  :b\n)\n"
      retyped = typed.sub("#: Integer", "#: String")
      one_line = "P = Data.define(:a) #: Integer\n"
      field = ->(source, name) { sites(source).find { |site| site["name"] == name } }

      expect(field.call(typed, "a")["contract_span"]).not_to be_nil
      expect(field.call(retyped, "a")["anchor"]).not_to eq(field.call(typed, "a")["anchor"])
      expect(field.call(typed, "b")["contract_span"]).to be_nil
      expect(field.call(one_line, "a")["contract_span"]).to be_nil
    end

    it "omits the builder forms it does not model" do
      expect(omissions(source)).to include(%w[struct_class X::N], %w[data_class X::D], %w[data_class X::E],
                                           %w[data_class X::F])
    end
  end

  describe "aliases" do
    let(:source) do
      <<~RUBY
        class K
          private def x(a, &blk) = a
          alias y x
          def w = 1
          private
          alias_method :v, "w"
          alias z w
          alias u y
          private :v
          alias_method :t, :inherited_name
          def r = 1
          def r = 2
          alias q r
          attr_reader :p
          alias o p
          if $x
            alias n w
          end
          alias_method :l, :w do end
          alias_method name, :w
          alias :"k\#{1}" w
          class << self
            def s = 1
            alias j s
          end
          configure { alias i w }
        end
        module F
          module_function
          def g = 1
          alias h g
        end
        class Z
          def w = 1
          public alias_method(:m, :w)
        end
        alias top_level w
        D = Data.define(:a) do
          alias b a
        end
      RUBY
    end

    def alias_rows(source)
      sites(source).filter_map do |site|
        next unless site["alias_of"]

        [site["owner"], site["name"], site["alias_of"], site["visibility"], site["params"], site["body_return"]]
      end
    end

    it "reads a direct alias as a method site copying the original's visibility, shape and return" do
      unknown = { "state" => "unavailable", "reason" => "not_computed" }
      rows = alias_rows(source)
      x_params = sites(source).find { |site| site["name"] == "x" }.values_at("params", "body_return")

      expect(rows).to eq([["K", "y", "x", "private", *x_params], ["K", "v", "w", "private", [], unknown],
                          ["K", "z", "w", "public", [], unknown],
                          ["K", "u", "y", "private", *x_params], ["K", "t", "inherited_name", nil, nil, unknown],
                          ["K", "q", "r", "private", nil, unknown], ["K", "o", "p", "private", nil, unknown],
                          ["D", "b", "a", "public", nil, unknown]])
    end

    it "copies the original's block shape and leaves alias_of null on every other site" do
      y = sites(source).find { |site| site["name"] == "y" }

      expect(y["block"]).to eq(sites(source).find { |site| site["name"] == "x" }["block"])
      expect(sites(source).reject { |site| site["alias_of"] }.map { |site| site["alias_of"] }.uniq).to eq([nil])
    end

    it "reads an alias to a name Ruby forces private as private, and returns nothing across initialize" do
      source = <<~RUBY
        class X
          def foo(a) = a
          def initialize(v) = @v = v
          alias initialize_copy foo
          alias_method :respond_to_missing?, :foo
          alias init2 initialize
          alias bar foo
          private :foo
        end
      RUBY
      rows = sites(source).filter_map do |site|
        [site["name"], site["visibility"], site["body_return"]["state"]] if site["alias_of"]
      end

      expect(rows).to eq([%w[initialize_copy private unavailable], %w[respond_to_missing? private unavailable],
                          %w[init2 private unavailable], %w[bar public unavailable]])
      expect(sites(source).find { |site| site["name"] == "initialize" }["visibility"]).to eq("private")
      expect(sites("class E\n  attr_reader :initialize\nend\n").first(2).last["visibility"]).to be_nil
    end

    it "omits an alias it cannot place the way Ruby and check both read it" do
      names = omissions(source).filter_map { |kind, name| [name] if kind == "alias" }.flatten(1)

      expect(names).to contain_exactly("n", "m", "l", nil, "\"k\#{1}\"", "j", "i", "h", "top_level")
    end
  end

  describe "completeness" do
    it "omits what it does not model instead of dropping it" do
      source = <<~RUBY
        class Point < Struct.new(:x) do
          def hidden; end
        end
          def setup
            attr_accessor :later
            def nested; end
            define_method(:dyn) {}
          end
          A, B = 1, 2
          C ||= 1
          C += 1
        end
      RUBY

      expect(omissions(source)).to include(%w[method hidden], %w[attribute later], %w[method nested],
                                           %w[define_method dyn], ["constant", "Point::A"], ["constant", "Point::B"])
      expect(omissions(source).count { |kind, name| kind == "constant" && name == "Point::C" }).to eq(2)
    end

    # rigortype/rigor#1907: a trailing-comma assignment's rest slot is a Prism::ImplicitRestNode, which has no
    # `expression`; reading it failed the whole target.
    it "reads every shape of multiple assignment" do
      source = <<~RUBY
        class M
          left, = [1, 2]
          a, * = [1, 2]
          b, *C = [1, 2]
          (D, e), F = [[1, 2], 3]
          *G, h = [1, 2]
          (i, ), J = [[1], 2]
          (k, ::N), * = [[1, 2]]
          def kept = 1
        end
      RUBY

      expect(omissions(source).filter_map { |kind, name| name if kind == "constant" })
        .to contain_exactly("M::C", "M::D", "M::F", "M::G", "M::J", "N")
      expect(sites(source).map { |site| site["name"] }).to eq(%w[M kept])
    end

    it "lists the constants a for index or a rescue reference assigns" do
      source = <<~RUBY
        class M
          for A, (B, *C) in [[1, [2]]]; end
          for D in [1]; end
          begin
          rescue => E
          end
        end
      RUBY

      expect(omissions(source).filter_map { |kind, name| name if kind == "constant" })
        .to contain_exactly("M::A", "M::B", "M::C", "M::D", "M::E")
    end

    it "walks the expressions inside assignment targets" do
      source = "class M\n  a[define_method(:z) {}], b = 1\n  Class.new { def q; end }::A, c = 1\nend\n"

      expect(omissions(source)).to include(%w[define_method z], %w[method q])
    end
  end
end
