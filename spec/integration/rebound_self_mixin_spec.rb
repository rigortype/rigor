# frozen_string_literal: true

# Issue #728 (the mixin-attribution half) — a block that REBINDS `self` owns the mixin calls written in it.
#
# `build_discovered_includes` descended into `Class.new { … }`, `Recv.class_eval { … }` and `class << self`
# with the lexically enclosing class still in hand, so `Thing = Class.new { include Taggable }` inside
# `class Outer` registered `Taggable` on `Outer`. `Outer.new.tag` then typed `:tagged` where MRI raises
# `NoMethodError` — a wrong answer, not a wider one.
#
# Every expectation here was checked against MRI on the same source:
#
#   Outer.new.tag  -> NoMethodError      Evaled.new.tag -> :tagged
#   Legit.new.tag  -> :tagged            Singly.new.tag -> NoMethodError  (Singly.tag -> :tagged)

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a mixin call in a self-rebinding block (#728)" do
  def dumps_for(source)
    FileUtils.mkdir_p("lib")
    File.write(File.join("lib", "demo.rb"), source)
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0)
    )
    result = guarded_run(
      Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib]
    )
    result.diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message)
  end

  around do |example|
    Dir.mktmpdir("rigor-rebound-mixin-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "does not give a Class.new block's include to the enclosing class" do
    expect(dumps_for(<<~RUBY)).to eq(["dump_type: Dynamic[top]"])
      module Taggable
        def tag = :tagged
      end

      class Outer
        Thing = Class.new do
          include Taggable
        end
      end

      module Runner
        def self.go
          Rigor.dump_type(Outer.new.tag)
        end
      end
    RUBY
  end

  it "gives a class_eval block's include to the receiver" do
    # The precision half of the same classification: the block's owner used to be the lexical enclosure, so
    # at the top level this include was dropped entirely and `tag` read `Dynamic[top]`. MRI resolves it.
    expect(dumps_for(<<~RUBY)).to eq(["dump_type: :tagged"])
      module Taggable
        def tag = :tagged
      end

      class Evaled
      end

      Evaled.class_eval do
        include Taggable
      end

      module Runner
        def self.go
          Rigor.dump_type(Evaled.new.tag)
        end
      end
    RUBY
  end

  it "does not give a class << self include to the instance surface" do
    # `class << self; include M; end` mixes M into the singleton: `Singly.tag` works, `Singly.new.tag`
    # raises. The instance-side table must not carry it.
    expect(dumps_for(<<~RUBY)).to eq(["dump_type: Dynamic[top]"])
      module Taggable
        def tag = :tagged
      end

      class Singly
        class << self
          include Taggable
        end
      end

      module Runner
        def self.go
          Rigor.dump_type(Singly.new.tag)
        end
      end
    RUBY
  end

  it "still records an ordinary include written in the class body" do
    # Mandatory control: the walk still does its job. Without this arm a change that dropped every include
    # would pass the three above.
    expect(dumps_for(<<~RUBY)).to eq(["dump_type: :tagged"])
      module Taggable
        def tag = :tagged
      end

      class Legit
        include Taggable
      end

      module Runner
        def self.go
          Rigor.dump_type(Legit.new.tag)
        end
      end
    RUBY
  end

  it "still records an include written in an ordinary block" do
    # An ordinary block does NOT rebind `self`, so an include inside one belongs to the enclosing class
    # exactly as before. This is the boundary the classification draws, and the arm that fails if the walk
    # starts dropping owners wholesale.
    expect(dumps_for(<<~RUBY)).to eq(["dump_type: :tagged"])
      module Taggable
        def tag = :tagged
      end

      class Conditional
        [1].each do
          include Taggable
        end
      end

      module Runner
        def self.go
          Rigor.dump_type(Conditional.new.tag)
        end
      end
    RUBY
  end
end
