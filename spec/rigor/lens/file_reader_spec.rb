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

    it "applies a named call only when it is written directly in the body" do
      source = <<~RUBY
        class V
          def a = 1
          def b = 2
          def c = 3
          def d = 4
          private %i[a]
          def configure
            private :b
          end
          protected(*NAMES)
          def e = 5
        end
      RUBY
      visibilities = sites(source).filter_map { |site| [site["name"], site["visibility"]] if site["owner"] }.to_h

      expect(visibilities).to include("a" => nil, "b" => nil, "c" => nil, "d" => nil, "e" => nil)
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
  end
end
