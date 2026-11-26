# frozen_string_literal: true

# Issue #3419 — the class ivar index dropped a `nil` an attribute can hold at runtime, so `rigor sig-gen` printed
# its reader without `nil`: after a conditional `return` in `initialize`, for an ivar only `def self.initialize`
# wrote (which `new` never calls), and for an ivar `initialize` reads before anything sets it. Each example runs the
# class under Ruby 4.0.5 to show the `nil`, then reads the signature sig-gen proposes. The last group checks that
# `rigor check` stays quiet on correct programs of the same shapes.
require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "the transient nil the generated attribute keeps (#3419)", type: :runner do
  around do |example|
    Dir.mktmpdir("rigor-transient-nil-") { |dir| Dir.chdir(dir) { example.run } }
  end

  def write(relative, contents)
    FileUtils.mkdir_p(File.dirname(relative))
    File.write(relative, contents)
    relative
  end

  def configuration
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0))
  end

  def loaded(source, name) = Module.new.tap { it.module_eval(source) }.const_get(name)

  # The signature sig-gen proposes for `name`.
  def rbs_of(path, name)
    Rigor::SigGen::Generator.new(configuration: configuration, paths: [path]).run.find { it.method_name == name }.rbs
  end

  def diagnostics
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    guarded_run(runner, %w[lib]).diagnostics.map { |d| [d.rule, d.line] }
  end

  it "keeps the `nil` an `initialize` leaves when it returns before the write" do
    source = "class H1\n  attr_reader :y\n  def initialize(c)\n    @y = nil\n    return if c\n    @y = 1\n  end\nend\n"
    path = write("lib/h1.rb", source)

    expect(loaded(source, :H1).new(true).y).to be_nil
    expect(rbs_of(path, :y)).to eq("def y: () -> (1 | nil)")
  end

  it "keeps the `nil` of an ivar only a singleton-side `initialize` writes besides a method" do
    source = "class H3a\n  def self.initialize; @a = 1; end\n  def a; @a; end\n  def n; @a = 2; end\nend\n"
    path = write("lib/h3a.rb", source)

    expect(loaded(source, :H3a).new.a).to be_nil
    expect(rbs_of(path, :a)).to eq("def a: () -> (1 | 2 | nil)")
  end

  it "keeps the `nil` of an ivar `initialize` reads before anything sets it" do
    source = "class H3c\n  attr_reader :y\n  def initialize; @y.to_s; end\n  def set; @y = 1; end\nend\n"
    path = write("lib/h3c.rb", source)

    expect(loaded(source, :H3c).new.y).to be_nil
    expect(rbs_of(path, :y)).to eq("def y: () -> (1 | nil)")
  end

  # An ivar every path of `initialize` sets keeps no `nil`, so a sibling's call on it is no call on `nil`.
  it "reports nothing on a class whose `initialize` sets the ivar on every path it completes" do
    write("lib/box.rb", <<~RUBY)
      class Box
        attr_reader :y
        def initialize(c)
          @y = nil
          raise ArgumentError, "no" if c
          @y = "s"
        end

        def use = @y.upcase
      end
    RUBY

    expect(rbs_of("lib/box.rb", :y)).to eq('def y: () -> "s"')
    expect(diagnostics).to eq([])
  end

  it "reports nothing for a call on an ivar a returning `initialize` may leave nil, guarded at the read" do
    write("lib/box.rb", <<~RUBY)
      class Box
        def initialize(c)
          @y = nil
          return if c
          @y = "s"
        end

        def use = @y&.upcase
        def size = @y ? @y.size : 0
      end
    RUBY

    expect(diagnostics).to eq([])
  end
end
