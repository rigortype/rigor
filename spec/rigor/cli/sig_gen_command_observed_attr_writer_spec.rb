# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/cli"
require "rigor/cli/sig_gen_command"
require "rigor/configuration"

# #1410 — under `--params=observed` the constructor argument a call site passed types an attribute only while the
# constructor's `@ivar = param` is all that writes the field. An attr writer, a hand-written setter or a write in
# another method lets it hold anything, so its reader and writer are skipped as `untyped_return` instead of being
# rendered as the observed literal (`def count=: (0) -> 0`), which made `box.count = 5` a type error.
RSpec.describe Rigor::CLI::SigGenCommand do
  let(:root) { Dir.mktmpdir }

  around { |example| Dir.chdir(root) { example.run } }

  after { FileUtils.remove_entry(root) }

  def write(relative, body)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def sig_gen(*argv)
    write(".rigor.yml", "paths:\n  - lib\nsignature_paths:\n  - sig\n")
    out = StringIO.new
    described_class.new(argv: [*argv, "--config=#{File.join(root, '.rigor.yml')}"], out: out, err: StringIO.new).run
    out.string
  end

  def observed_print = sig_gen("--print", "--params=observed", "--observe=test")

  def section(out, class_name)
    out[/^class #{class_name}\n.*?^end/m].to_s
  end

  before do
    write("lib/boxes.rb", <<~RUBY)
      class Box
        def initialize(count)
          @count = count
        end
        attr_accessor :count
      end

      class WBox
        def initialize(count)
          @count = count
        end
        attr_writer :count
        attr_reader :count
      end

      class HBox
        def initialize(count)
          @count = count
        end
        attr_reader :count
        def count=(v)
          @count = v
        end
      end

      class RBox
        def initialize(count)
          @count = count
        end
        attr_reader :count
      end

      class ResetBox
        def initialize(count)
          @count = count
        end
        attr_reader :count
        def reset = @count = nil
      end

      class SelfBox
        def initialize(count)
          @count = count
        end
        attr_reader :count
        def self.make(c) = @count = c
        class << self
          attr_accessor :count
          def reset = @count = nil
        end
      end

      class DefineBox
        def initialize(count)
          @count = count
        end
        attr_reader :count
        define_method(:reset) { @count = nil }
      end

      class SetBox
        def initialize(count, label)
          @count = count
          @label = label
        end
        attr_reader :count, :label
        def bump(n) = instance_variable_set(:@count, n)
      end

      class OptsBox
        def initialize(count, opts)
          @count = count
          opts.each { |k, v| instance_variable_set(:"@\#{k}", v) }
        end
        attr_reader :count
      end
    RUBY
    write("test/boxes_test.rb", <<~RUBY)
      Box.new(0)
      WBox.new(0)
      HBox.new(0)
      RBox.new(0)
      ResetBox.new(0)
      SelfBox.new(0)
      DefineBox.new(0)
      SetBox.new(0, "a")
      OptsBox.new(0, {})
    RUBY
  end

  it "skips the reader and writer of an attr_accessor instead of rendering the observed literal" do
    box = section(observed_print, "Box")

    expect(box).to include("def initialize: (0) -> void")
    expect(box).not_to include("def count")
  end

  it "skips an attr_writer and its separate attr_reader" do
    expect(section(observed_print, "WBox")).not_to include("def count")
  end

  it "skips the reader of a field a hand-written setter writes, and still skips the setter" do
    expect(section(observed_print, "HBox")).not_to include("def count")
  end

  it "skips the reader of a field another method writes" do
    reset_box = section(observed_print, "ResetBox")

    expect(reset_box).to include("def reset: () -> nil")
    expect(reset_box).not_to include("def count:")
  end

  it "skips the reader of a field a define_method block writes" do
    expect(section(observed_print, "DefineBox")).not_to include("def count:")
  end

  it "keeps the observed type for a reader whose only write is the constructor's" do
    expect(section(observed_print, "RBox")).to include("def count: () -> 0")
  end

  it "keeps the observed type when the other writes are the class object's own ivar" do
    expect(section(observed_print, "SelfBox")).to include("def count: () -> 0")
  end

  it "skips the reader of a field an instance_variable_set on self names, and keeps its sibling" do
    set_box = section(observed_print, "SetBox")

    expect(set_box).not_to include("def count:")
    expect(set_box).to include(%(def label: () -> "a"))
  end

  it "skips every observed reader of a class whose instance_variable_set name is computed" do
    expect(section(observed_print, "OptsBox")).not_to include("def count:")
  end

  # Guard: without observations nothing reaches the observed-ivar map, before or after #1410.
  it "skips every attr method under --params=untyped" do
    out = sig_gen("--print")

    expect(out).not_to include("def count")
  end

  it "writes a sig/ under which assigning the attributes reports nothing" do
    write("lib/caller.rb", <<~RUBY)
      box = Box.new(0)
      box.count = 5
      box.count = "x"
      wbox = WBox.new(0)
      wbox.count = 5
      wbox.count = "x"
      hbox = HBox.new(0)
      hbox.count = 5
      hbox.count = "x"
    RUBY
    sig_gen("--write", "--overwrite", "--params=observed", "--observe=test")
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0)
    )

    result = guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])

    expect(File.read(File.join(root, "sig", "boxes.rbs"))).to include("class Box")
    expect(result.diagnostics.map { |d| "#{d.qualified_rule}: #{d.message}" }).to eq([])
  end
end
