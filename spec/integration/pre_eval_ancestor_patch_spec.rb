# frozen_string_literal: true

# Issue #1708 — a `pre_eval:` patch on an ancestor (`class Object; def zz`, `class Numeric; def nn`,
# `module Enumerable; def sum_by`) gives the method to every receiver whose class descends from it, in Ruby's
# order: a nearer class's own method wins. The patch file sits outside `paths:`, so nothing but the `pre_eval:`
# registry knows of it. Each Ruby 4.0.5 witness is the comment beside its call.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a pre_eval: patch on an ancestor reaches its descendants (#1708)" do
  around do |example|
    Dir.mktmpdir("rigor-pre-eval-ancestor-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:patch) { <<~RUBY }
    class Object; def zz = :object; end
    class Numeric; def nn = :numeric; end
    module Comparable; def cc = :comparable; end
    module Enumerable; def sum_by = :enumerable; end
    module Kernel; def kk = :kernel; end
    class Object; def to_s(a, b, c) = :object_to_s; end
    class Hash; def only_hash = :hash; end
  RUBY
  let(:calls) { <<~RUBY }
    rand(3).zz         # => :object
    1.5.nn             # => :numeric
    1.cc               # => :comparable
    "a".cc             # => :comparable
    [1].sum_by         # => :enumerable
    { a: 1 }.sum_by    # => :enumerable
    "x".zz             # => :object
    rand(3).kk         # => :kernel
    Integer.zz         # => :object
    Integer.kk         # => :kernel
    x = rand(2).zero? ? 1 : "a"
    x.zz               # => :object
  RUBY

  def run_project(files, config = {})
    files.each do |path, source|
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source)
    end
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "pre_eval" => ["ext/core.rb"], "workers" => 0)
                                    .merge(config)
    )
    guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
  end

  def rules(result) = result.diagnostics.map { |d| [File.basename(d.path), d.line, d.qualified_rule] }

  it "does not report a method a pre_eval: patch gives an ancestor" do
    result = run_project("ext/core.rb" => patch, "lib/a.rb" => calls, "lib/b.rb" => "rand(3).nn\n")

    expect(rules(result)).to eq([])
  end

  it "does not report a bare top-level call a pre_eval: patch on Kernel defines" do
    result = run_project("ext/core.rb" => patch, "lib/a.rb" => "kk # => :kernel\n")

    expect(rules(result)).to eq([])
  end

  it "does not report under the fork pool" do
    result = run_project({ "ext/core.rb" => patch, "lib/a.rb" => calls, "lib/b.rb" => "rand(3).nn\n" },
                         { "workers" => 2 })

    expect(rules(result)).to eq([])
  end

  # `[1].only_hash` raises NoMethodError: Hash is not an Array ancestor. `1.to_s(1, 2, 3)` raises ArgumentError:
  # Integer#to_s is nearer than the Object patch. Guard: passes without the fix; it fails if the ancestor walk is
  # read for a non-ancestor or where a nearer class's own method is checked.
  it "still reports a patch on a class that is not an ancestor, and checks a nearer class's own method" do
    result = run_project("ext/core.rb" => patch, "lib/a.rb" => "[1].only_hash\n1.to_s(1, 2, 3)\n")

    expect(rules(result)).to eq([["a.rb", 1, "call.undefined-method"], ["a.rb", 2, "call.wrong-arity"]])
  end

  # Review of #2098 — a method the project's own source defines on a nearer class wins over the ancestor's patch,
  # in Ruby and in the type the call reads, so the patch's `nil` must not narrow `res` to 1. Ruby: each `res` is
  # "s" and `res.upcase` runs.
  describe "a nearer method the project's source defines" do
    let(:nil_patch) { "class Object; def nn = nil; def self.sn = nil; end\n" }
    let(:use) { ->(call) { "res = #{call}.nil? ? 1 : \"s\"\nres.upcase\n" } }

    it "wins over the patch on a core receiver the project reopens" do
      result = run_project("ext/core.rb" => nil_patch, "lib/int.rb" => "class Integer; def nn = \"s\"; end\n",
                           "lib/use.rb" => use.call("rand(3).nn"))

      expect(rules(result)).to eq([])
    end

    it "wins over the patch on a class the project's sig/ declares" do
      result = run_project("ext/core.rb" => nil_patch,
                           "sig/foo.rbs" => "class Foo\n  def initialize: () -> void\nend\n",
                           "lib/foo.rb" => "class Foo; def nn = \"s\"; end\n", "lib/use.rb" => use.call("Foo.new.nn"))

      expect(rules(result)).to eq([])
    end

    it "wins over the patch through a module the project includes into the receiver's class" do
      result = run_project("ext/core.rb" => nil_patch,
                           "lib/m.rb" => "module M; def nn = \"s\"; end\nclass Integer; include M; end\n",
                           "lib/use.rb" => use.call("rand(3).nn"))

      expect(rules(result)).to eq([])
    end

    it "wins over the patch through a module the project prepends to the patched owner" do
      result = run_project("ext/core.rb" => nil_patch,
                           "lib/p.rb" => "module P; def nn = \"s\"; end\nclass Object; prepend P; end\n",
                           "lib/use.rb" => use.call("rand(3).nn"))

      expect(rules(result)).to eq([])
    end

    # A `lib/` reopen of the patched owner itself, loaded after the `pre_eval:` file, replaces the patch. The walk
    # stops at any owner with a source `def`, so a module the project includes into that owner (which Ruby reaches
    # AFTER the owner's patch) stops it too: conservative, the call is left to user-method inference.
    it "wins over the patch when the project reopens the patched owner" do
      result = run_project("ext/core.rb" => nil_patch, "lib/o.rb" => "class Object; def nn = \"s\"; end\n",
                           "lib/use.rb" => use.call("rand(3).nn"))

      expect(rules(result)).to eq([])
    end

    # Ruby: the reader answers nil, so `res` is "s"; the patch's :sym would make it 1. Guard: an earlier tier types the
    # reader, so this passes with the walk's source probe removed; no reachable call pins its `discovered_method?` arm.
    it "wins over the patch through an attr_reader the project declares" do
      result = run_project("ext/core.rb" => "class Object; def na = :sym; end\n",
                           "lib/int.rb" => "class Integer; attr_reader :na; end\n",
                           "lib/use.rb" => "res = rand(3).na.nil? ? \"s\" : 1\nres.upcase\n")

      expect(rules(result)).to eq([])
    end

    it "wins over the patch on the singleton side" do
      result = run_project("ext/core.rb" => nil_patch, "lib/int.rb" => "class Integer; def self.sn = \"s\"; end\n",
                           "lib/use.rb" => use.call("Integer.sn"))

      expect(rules(result)).to eq([])
    end
  end

  # Review of #2098 — a private, protected or module_function patch answers only the calls Ruby lets reach it. Each
  # Ruby 4.0.5 witness is the comment beside its call; before #1708 the explicit-receiver calls reported, and #2098
  # had made the ancestor walk accept them.
  describe "a patch's visibility" do
    let(:visibility_patch) { <<~RUBY }
      module Kernel; private def kp = 1; end
      class Object; private def pz = 1; end
      module Kernel; module_function def kmf = 3; end
      class Numeric; protected def np = 2; end
      class Object; def pq = 1; private :pq; end
      class Numeric; private; def nprv = 1; end
      class Integer; private def ip = 1; end
    RUBY

    it "reports a private, protected or module_function patch called with an explicit receiver" do
      result = run_project("ext/core.rb" => visibility_patch, "lib/a.rb" => <<~RUBY)
        1.kp     # NoMethodError: private method 'kp' called for an instance of Integer
        1.pz     # NoMethodError: private method 'pz'
        1.kmf    # NoMethodError: private method 'kmf'
        1.np     # NoMethodError: protected method 'np' (main is no Numeric)
        "a".pq   # NoMethodError: private method 'pq' (private :pq after the def)
        1.5.nprv # NoMethodError: private method 'nprv' (a def after a bare private)
        1.ip     # NoMethodError: private method 'ip' (the receiver's own class)
      RUBY

      expect(rules(result)).to eq((1..7).map { |line| ["a.rb", line, "call.undefined-method"] })
    end

    it "does not report the same patches called on self, or protected from an instance of the owner" do
      result = run_project("ext/core.rb" => visibility_patch, "lib/a.rb" => <<~RUBY)
        kp         # => 1
        kmf        # => 3
        Kernel.kmf # => 3, module_function's public singleton copy
        self.pz    # => 1
        class Integer
          def gi = [2.np, nprv, ip, self.kp] # => [2, 1, 1, 1]
        end
      RUBY

      expect(rules(result)).to eq([])
    end

    it "follows the binding Ruby calls: a nearer public patch, a later public :x, and an alias's own visibility" do
      result = run_project("ext/core.rb" => <<~PATCH, "lib/a.rb" => <<~RUBY)
        module Kernel; private def ov = 1; end
        class Object; def ov = 2; end
        class Object; private def q = 1; end
        class Object; public :q; end
        class Object; private; def a1 = 1; alias b1 a1; end
        class Object; def a2 = 1; private; alias b2 a2; end
      PATCH
        1.ov # => 2
        1.q  # => 1
        1.b2 # => 1, an alias keeps a2's public visibility
        1.b1 # NoMethodError: private method 'b1', as a1 is
      RUBY

      expect(rules(result)).to eq([["a.rb", 4, "call.undefined-method"]])
    end

    # Ruby raises NoMethodError (protected method 'np' called for an instance of Integer): `Foo` is no Numeric. Guard:
    # a class RBS does not know may be anything, so a protected patch answers a call from it; it passes without the fix.
    it "does not report a protected patch called from a class RBS does not know" do
      result = run_project("ext/core.rb" => visibility_patch, "lib/a.rb" => "class Foo; def go = 1.np; end\n")

      expect(rules(result)).to eq([])
    end

    it "reports under the fork pool" do
      result = run_project({ "ext/core.rb" => visibility_patch, "lib/a.rb" => "1.kp\n1.np\n" }, { "workers" => 2 })

      expect(rules(result)).to eq([["a.rb", 1, "call.undefined-method"], ["a.rb", 2, "call.undefined-method"]])
    end
  end

  describe "a module a pre_eval: file mixes into an ancestor" do
    let(:mixin_patch) { <<~RUBY }
      module NumExt; def inc_m = :inc; end
      Numeric.include(NumExt)
      module NumPre; def pre_m = :pre; end
      Numeric.prepend(NumPre)
    RUBY

    let(:mixin_calls) { "1.inc_m # => :inc\n1.5.pre_m # => :pre\n" }

    # Guard: #1722's `RbsReceiverSurface` answers this through the analysed file's mixin edges, not this fix.
    it "is not reported when the pre_eval: file is also analysed" do
      result = run_project({ "lib/core_ext.rb" => mixin_patch, "lib/a.rb" => mixin_calls },
                           { "pre_eval" => ["lib/core_ext.rb"] })

      expect(rules(result)).to eq([])
    end

    it "is not reported when the pre_eval: file is outside the analysed paths" do
      result = run_project("ext/core.rb" => mixin_patch, "lib/a.rb" => mixin_calls)

      expect(rules(result)).to eq([])
    end

    it "reaches the module through every spelling and owner" do
      result = run_project({ "ext/core.rb" => <<~PATCH, "ext/mods.rb" => <<~MODS, "lib/a.rb" => <<~RUBY },
        class Numeric; include InBody; end
        Comparable.include(CmpExt)
        Object.include(ObjExt)
        module Outer; module Inner; def inner_m = :inner; end; ::Numeric.include(Inner); end
      PATCH
        module InBody; def body_m = :body; end
        module CmpExt; def cmp_m = :cmp; end
        module ObjExt; def obj_m = :obj; end
      MODS
        1.body_m    # => :body
        1.5.body_m  # => :body
        1.cmp_m     # => :cmp
        "a".cmp_m   # => :cmp
        [1].obj_m   # => :obj
        Integer.obj_m # => :obj, Integer is an Object
        rand(3).inner_m # => :inner
      RUBY
                           { "pre_eval" => ["ext/mods.rb", "ext/core.rb"] })

      expect(rules(result)).to eq([])
    end

    # Ruby: P#pm runs ahead of Numeric#pm, and Numeric#im ahead of I#im, so each `res` is "s" and `res.upcase` runs.
    # Read in the wrong order, the other method's nil makes `res` 1.
    it "searches a prepended module ahead of the owner and an included one after it" do
      result = run_project("ext/core.rb" => <<~PATCH, "lib/a.rb" => <<~RUBY)
        class Numeric; def pm = nil; def im = "s"; end
        module P; def pm = "s"; end
        module I; def im = nil; end
        Numeric.prepend(P)
        Numeric.include(I)
      PATCH
        res = rand(3).pm.nil? ? 1 : "s"
        res.upcase
        res2 = rand(3).im.nil? ? 1 : "s"
        res2.upcase
      RUBY

      expect(rules(result)).to eq([])
    end

    # Ruby raises ArgumentError: Integer#abs is nearer than the module Numeric includes. Guard: the RBS tier answers
    # first, with or without the mixin edge.
    it "leaves a method the receiver's RBS declares to the RBS" do
      result = run_project("ext/core.rb" => "module AbsExt; def abs(a) = a; end\nNumeric.include(AbsExt)\n",
                           "lib/a.rb" => "1.abs(1)\n")

      expect(rules(result)).to eq([["a.rb", 1, "call.wrong-arity"]])
    end

    it "is not reported under the fork pool" do
      result = run_project({ "ext/core.rb" => mixin_patch, "lib/a.rb" => mixin_calls }, { "workers" => 2 })

      expect(rules(result)).to eq([])
    end
  end
end
