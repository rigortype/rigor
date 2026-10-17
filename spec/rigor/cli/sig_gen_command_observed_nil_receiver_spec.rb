# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require "rigor/cli"
require "rigor/cli/sig_gen_command"

# #1389 — `sig-gen --params=observed` observes a call whose receiver types as `T | nil` with one `Nominal` or
# `Singleton` non-nil member as a call on that member. The ordinary producer is a test ivar written in a Minitest
# `setup` (not `initialize`, so the read types as `Foo?`) or an RSpec `before` block.
RSpec.describe Rigor::CLI::SigGenCommand do
  let(:root) { Dir.mktmpdir }

  around { |example| Dir.chdir(root) { example.run } }

  after { FileUtils.remove_entry(root) }

  def write(relative, body)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def run_observed
    write(".rigor.yml", "paths:\n  - lib\nsignature_paths:\n  - sig\n")
    out = StringIO.new
    argv = ["--print", "--params=observed", "--observe=test", "--config=#{File.join(root, '.rigor.yml')}"]
    described_class.new(argv: argv, out: out, err: StringIO.new).run
    out.string
  end

  def section(out, class_name)
    out[/^class #{class_name}\n.*?^end/m].to_s
  end

  before do
    write("lib/foo.rb", <<~RUBY)
      class Foo
        def initialize(n = 0) = nil
        def bar(x) = 1
        def self.build(x) = 1
      end
      class Bar
        def bar(x) = 1
      end
      class Sub < Foo
        def bar(x) = 2
      end
      module M
        def bar(x) = 3
      end
      class Factory
        def self.m = nil
      end
      class Account
        def deposit(x) = 10
      end
      class Label
        def deposit(x) = 20
      end
      class Repo
        def ==(other) = false
        def respond_to?(name, all = false) = true
        def is_a?(klass) = true
        def save(x) = 30
      end
      class Widget
        def spin(x) = 40
      end
      class Finder
        def self.repo(id) = nil
        def self.widget = nil
      end
    RUBY
    write("sig/factory.rbs", <<~RBS)
      class Factory
        def self.m: () -> M
      end
      class Finder
        def self.repo: (Integer) -> Repo?
        def self.widget: () -> (Widget | NilClass)
      end
    RBS
  end

  it "observes a Minitest setup ivar receiver without the rigor-minitest plugin" do
    write("test/foo_test.rb", <<~RUBY)
      class FooTest < Minitest::Test
        def setup = @foo = Foo.new
        def test_bar = @foo.bar(1)
      end
    RUBY

    expect(run_observed).to include("def bar: (1) -> 1")
  end

  it "observes an RSpec before-block ivar receiver read in an example" do
    write("test/foo_spec.rb", <<~RUBY)
      RSpec.describe Foo do
        before { @foo = Foo.new }
        it { @foo.bar(1) }
      end
    RUBY

    expect(run_observed).to include("def bar: (1) -> 1")
  end

  it "keeps the scope's own receiver type over a same-name before-block ivar" do
    write("test/foo_spec.rb", <<~RUBY)
      RSpec.describe Foo do
        before { @foo = Bar.new }
        it do
          @foo = Foo.new
          @foo.bar(1)
        end
      end
    RUBY

    out = run_observed
    expect(out[/^class Foo\n.*?^end/m]).to include("def bar: (1) -> 1")
    expect(out[/^class Bar\n.*?^end/m]).to include("def bar: (untyped) -> 1")
  end

  it "credits each nested context's before ivar to its own class" do
    write("test/target_spec.rb", <<~RUBY)
      RSpec.describe "target" do
        context "account" do
          before { @target = Account.new }
          it { @target.deposit(10) }
        end
        context "label" do
          before { @target = Label.new }
          it { @target.deposit("a") }
        end
      end
    RUBY

    out = run_observed
    expect(section(out, "Account")).to include("def deposit: (10) -> 10")
    expect(section(out, "Label")).to include('def deposit: ("a") -> 20')
  end

  it "does not bind a before ivar across sibling describes" do
    write("test/target_spec.rb", <<~RUBY)
      RSpec.describe "one" do
        before { @target = Account.new }
      end
      RSpec.describe "two" do
        it { @target.deposit(10) }
      end
    RUBY

    expect(section(run_observed, "Account")).to include("def deposit: (untyped) -> 10")
  end

  it "does not bind a before ivar into a helper class body in the example group" do
    write("test/target_spec.rb", <<~RUBY)
      RSpec.describe "one" do
        before { @target = Account.new }
        class Helper
          def run = @target.deposit(10)
        end
      end
    RUBY

    expect(section(run_observed, "Account")).to include("def deposit: (untyped) -> 10")
  end

  it "does not observe an ivar two enclosing befores write with different types" do
    write("test/target_spec.rb", <<~RUBY)
      RSpec.describe "outer" do
        before { @target = Account.new }
        context "inner" do
          before { @target = Label.new }
          it { @target.deposit(10) }
        end
      end
    RUBY

    out = run_observed
    expect(section(out, "Account")).to include("def deposit: (untyped) -> 10")
    expect(section(out, "Label")).to include("def deposit: (untyped) -> 20")
  end

  it "does not bind an ivar from a before call that has a receiver" do
    write("test/target_spec.rb", <<~RUBY)
      RSpec.describe "one" do
        hooks.before { @target = Account.new }
        it { @target.deposit(10) }
      end
    RUBY

    expect(section(run_observed, "Account")).to include("def deposit: (untyped) -> 10")
  end

  it "does not credit a Repo | nil receiver with a call nil answers, which may have run on nil" do
    write("test/repo_test.rb", <<~RUBY)
      r = Finder.repo(-1)
      r == :sym
      r.respond_to?(:zzz)
      r.is_a?(String)
      r.save(1)
    RUBY

    out = section(run_observed, "Repo")
    expect(out).to include("def ==: (untyped) -> false")
    expect(out).to include("def respond_to?: (untyped, ?untyped) -> true")
    expect(out).to include("def is_a?: (untyped) -> true")
    expect(out).to include("def save: (1) -> 30")
  end

  it "credits a safe-navigation call of a method nil answers, since &. skips it on nil" do
    write("test/repo_test.rb", "r = Finder.repo(-1)\nr&.is_a?(String)\n")

    expect(section(run_observed, "Repo")).to include("def is_a?: (singleton(String)) -> true")
  end

  it "treats an RBS NilClass member as nil" do
    write("test/widget_test.rb", "w = Finder.widget\nw.spin(1)\n")

    expect(section(run_observed, "Widget")).to include("def spin: (1) -> 40")
  end

  it "observes a safe-navigation call on a Foo | nil receiver" do
    write("test/foo_test.rb", <<~RUBY)
      class FooTest
        def setup = @foo = Foo.new
        def test_bar = @foo&.bar(1)
      end
    RUBY

    expect(run_observed).to include("def bar: (1) -> 1")
  end

  it "routes a singleton(Foo) | nil receiver's .new to initialize and leaves .build to the singleton rule" do
    write("test/foo_test.rb", <<~RUBY)
      class FooTest
        def setup = @klass = Foo
        def test_new
          @klass.new(1)
          @klass.build(2)
        end
      end
    RUBY

    out = run_observed
    expect(out).to include("def initialize: (?1) -> void")
    expect(out).to include("def self.build: (untyped) -> 1")
  end

  it "keys a project subclass and a module receiver by their own names, as the Nominal path does" do
    write("test/foo_test.rb", <<~RUBY)
      class FooTest
        def setup
          @sub = Sub.new
          @m = Factory.m
        end
        def test_bar
          @sub.bar(4)
          @m.bar(5)
        end
      end
    RUBY

    out = run_observed
    expect(out).to include("def bar: (4) -> 2")
    expect(out).to include("def bar: (5) -> 3")
    expect(out).to include("def bar: (untyped) -> 1")
  end

  it "does not observe a Foo | Bar | nil receiver" do
    write("test/foo_test.rb", <<~RUBY)
      class FooTest
        def setup = @foo = rand > 0.5 ? Foo.new : Bar.new
        def test_bar = @foo.bar(1)
      end
    RUBY

    expect(run_observed).not_to include("def bar: (1)")
  end

  # Without the single-member condition the rule would pick `Foo` out of this union too.
  it "does not observe a Foo | Bar receiver" do
    write("test/foo_test.rb", "foo = rand > 0.5 ? Foo.new : Bar.new\nfoo.bar(1)\n")

    expect(run_observed).not_to include("def bar: (1)")
  end

  # Guard: the sole `Dynamic` member is refused by the `Nominal` / `Singleton` check this change did not touch.
  it "does not observe an untyped | nil receiver" do
    write("test/foo_test.rb", <<~RUBY)
      class FooTest
        def setup = @foo = Unknown.make
        def test_bar = @foo.bar(1)
      end
    RUBY

    expect(run_observed).not_to include("def bar: (1)")
  end
end
