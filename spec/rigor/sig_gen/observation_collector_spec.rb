# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Rigor::SigGen::ObservationCollector do
  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmpdir) }

  def write_fixture(rel_path, contents)
    full = File.join(tmpdir, rel_path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, contents)
    full
  end

  def collector(paths:, source_paths: ["lib"])
    config = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => source_paths.map { |p| File.join(tmpdir, p) },
        "signature_paths" => nil
      ).compact
    )
    described_class.new(configuration: config, paths: paths)
  end

  it "returns an empty hash when no observe paths are given" do
    expect(collector(paths: []).collect).to eq({})
  end

  it "records explicit-receiver call argument types keyed by [class, method]" do
    write_fixture("lib/calc.rb", "class Calc\n  def greet(n); n; end\nend\n")
    spec = write_fixture("spec/calc_spec.rb", <<~RUBY)
      calc = Calc.new
      calc.greet("Alice")
      calc.greet("Bob")
    RUBY

    obs = collector(paths: [spec]).collect

    expect(obs.keys).to contain_exactly(["Calc", :greet])
    expect(obs[["Calc", :greet]].size).to eq(2)
  end

  it "unions different observed types for the same parameter position" do
    write_fixture("lib/calc.rb", "class Calc\n  def m(x); x; end\nend\n")
    spec = write_fixture("spec/calc_spec.rb", <<~RUBY)
      c = Calc.new
      c.m(42)
      c.m("text")
    RUBY

    obs = collector(paths: [spec]).collect
    arg_types = obs[["Calc", :m]].flat_map(&:positional).map(&:erase_to_rbs)

    expect(arg_types).to contain_exactly("42", '"text"')
  end

  it "skips zero-argument calls" do
    write_fixture("lib/calc.rb", "class Calc\n  def go; 1; end\nend\n")
    spec = write_fixture("spec/calc_spec.rb", "Calc.new.go\n")

    expect(collector(paths: [spec]).collect).to eq({})
  end

  it "skips implicit-self calls (no explicit receiver)" do
    write_fixture("lib/calc.rb", "class Calc\n  def m(x); x; end\nend\n")
    spec = write_fixture("spec/calc_spec.rb", "helper(1)\n")

    expect(collector(paths: [spec]).collect).to eq({})
  end

  it "skips calls whose receiver does not type as a Nominal" do
    spec = write_fixture("spec/calc_spec.rb", "unknown.bar(1)\n")

    expect(collector(paths: [spec]).collect).to eq({})
  end

  it "skips splat / block / forwarding argument shapes (kwargs are now captured)" do
    write_fixture("lib/calc.rb", "class Calc\n  def m(*a); a; end\nend\n")
    spec = write_fixture("spec/calc_spec.rb", <<~RUBY)
      c = Calc.new
      c.m(*[1, 2])
    RUBY

    expect(collector(paths: [spec]).collect).to eq({})
  end

  it "captures keyword arguments into the observation's `keyword` slot" do
    write_fixture("lib/calc.rb", "class Calc\n  def m(key:); key; end\nend\n")
    spec = write_fixture("spec/calc_spec.rb", <<~RUBY)
      c = Calc.new
      c.m(key: 1)
    RUBY

    obs = collector(paths: [spec]).collect

    expect(obs[["Calc", :m]].first.keyword).to eq(key: Rigor::Type::Combinator.constant_of(1))
  end

  it "routes `Class.new(...)` observations under [class, :initialize]" do
    write_fixture("lib/calc.rb", "class Calc\n  def initialize(name); @name = name; end\nend\n")
    spec = write_fixture("spec/calc_spec.rb", "Calc.new(\"hi\")\n")

    obs = collector(paths: [spec]).collect

    expect(obs.keys).to contain_exactly(["Calc", :initialize])
    expect(obs[["Calc", :initialize]].first.positional.first.erase_to_rbs).to eq(%("hi"))
  end

  it "routes `.new` calls with kwargs into the initialize observation" do
    write_fixture("lib/calc.rb", "class Calc\n  def initialize(name:); @name = name; end\nend\n")
    spec = write_fixture("spec/calc_spec.rb", "Calc.new(name: \"hi\")\n")

    obs = collector(paths: [spec]).collect

    expect(obs[["Calc", :initialize]].first.keyword[:name].erase_to_rbs).to eq(%("hi"))
  end

  describe "RSpec-aware bindings (slice 5)" do
    before do
      write_fixture("lib/calc.rb", "class Calc\n  def m(x); x; end\nend\n")
    end

    it "credits `subject.m(x)` to Calc#m when `subject { Calc.new }` is declared" do
      spec = write_fixture("spec/calc_spec.rb", <<~RUBY)
        RSpec.describe Calc do
          subject { Calc.new }
          it "x" do
            subject.m("hello")
          end
        end
      RUBY

      obs = collector(paths: [spec]).collect

      expect(obs[["Calc", :m]].first.positional.first.erase_to_rbs).to eq('"hello"')
    end

    it "credits `let(:other) { Calc.new }; other.m(x)` to Calc#m" do
      spec = write_fixture("spec/calc_spec.rb", <<~RUBY)
        RSpec.describe Calc do
          let(:other) { Calc.new }
          it "x" do
            other.m(42)
          end
        end
      RUBY

      obs = collector(paths: [spec]).collect

      expect(obs[["Calc", :m]].first.positional.first.erase_to_rbs).to eq("42")
    end

    it "resolves `described_class.new.m(x)` against the surrounding `describe Calc`" do
      spec = write_fixture("spec/calc_spec.rb", <<~RUBY)
        RSpec.describe Calc do
          it "x" do
            described_class.new.m(:sym)
          end
        end
      RUBY

      obs = collector(paths: [spec]).collect

      expect(obs[["Calc", :m]].first.positional.first.erase_to_rbs).to eq(":sym")
    end

    it "recognises bare `describe Foo` (no RSpec receiver) as the described class" do
      spec = write_fixture("spec/calc_spec.rb", <<~RUBY)
        describe Calc do
          subject { Calc.new }
          it "x" do
            subject.m(true)
          end
        end
      RUBY

      obs = collector(paths: [spec]).collect

      expect(obs[["Calc", :m]].first.positional.first.erase_to_rbs).to eq("true")
    end

    it "honours named `subject(:foo) { ... }` bindings" do
      spec = write_fixture("spec/calc_spec.rb", <<~RUBY)
        RSpec.describe Calc do
          subject(:foo) { Calc.new }
          it "x" do
            foo.m("ok")
          end
        end
      RUBY

      obs = collector(paths: [spec]).collect

      expect(obs[["Calc", :m]].first.positional.first.erase_to_rbs).to eq('"ok"')
    end
  end
end
