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
          Point = Struct.new(:x) do
            private
            def helper; end
          end
          def bar; end
        end
      RUBY

      expect(visibilities_of(source)).to eq("bar" => "public")
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
