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
  # Integer#to_s is nearer than the Object patch.
  it "still reports a patch on a class that is not an ancestor, and checks a nearer class's own method" do
    result = run_project("ext/core.rb" => patch, "lib/a.rb" => "[1].only_hash\n1.to_s(1, 2, 3)\n")

    expect(rules(result)).to eq([["a.rb", 1, "call.undefined-method"], ["a.rb", 2, "call.wrong-arity"]])
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

    # Flip this when the pre_eval: scanner records `include` / `prepend` edges (#1708): Ruby runs both calls.
    it "is still reported when the pre_eval: file is outside the analysed paths" do
      result = run_project("ext/core.rb" => mixin_patch, "lib/a.rb" => mixin_calls)

      expect(rules(result)).to eq([["a.rb", 1, "call.undefined-method"], ["a.rb", 2, "call.undefined-method"]])
    end
  end
end
