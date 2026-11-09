# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Issue #3029 — sig-gen proposed `-> bot` for abstract and template methods. A `bot` written for a base body that
# raises is wrong for every override, and a collection author cannot see an override outside the analysed code, so
# such a proposal is skipped. A `bot` that is the method's final behaviour (`throw`, a deliberate error nothing
# overrides) is still proposed.
RSpec.describe Rigor::SigGen::Generator do
  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmpdir) }

  def write_fixture(rel_path, contents)
    full = File.join(tmpdir, rel_path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, contents)
    full
  end

  def run_over(paths, signature_paths: nil)
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => paths, "signature_paths" => signature_paths).compact
    )
    described_class.new(configuration: configuration, paths: paths).run
  end

  def row(candidates, class_name, method_name, kind = :instance)
    candidates.find do |candidate|
      candidate.class_name == class_name && candidate.method_name == method_name && candidate.kind == kind
    end
  end

  def outcome(candidate)
    candidate.classification == Rigor::SigGen::Classification::SKIPPED ? candidate.skip_reason : candidate.rbs
  end

  describe "a raising base body that a subclass overrides" do
    # The subclass's own proposal is emitted (a `tighter_return` against its signed `untyped`), so the #744 guard,
    # which fires only for an override that is NOT emitted, does not cover this.
    it "skips the base when the overriding subclass is signed" do
      path = write_fixture("lib/response.rb", <<~RUBY)
        class Response
          def inspect_body = raise(ArgumentError, "unsupported")
        end
        class HtmlResponse < Response
          def inspect_body = "html"
        end
      RUBY
      write_fixture("sig/response.rbs", <<~RBS)
        class Response
          def inspect_body: () -> untyped
        end
        class HtmlResponse < Response
          def inspect_body: () -> untyped
        end
      RBS

      candidates = run_over([path], signature_paths: [File.join(tmpdir, "sig")])

      expect(outcome(row(candidates, "Response", :inspect_body))).to eq(:overridden_bot)
      expect(outcome(row(candidates, "HtmlResponse", :inspect_body))).to eq("def inspect_body: () -> String")
    end

    it "skips a singleton method a subclass's singleton overrides" do
      path = write_fixture("lib/loader.rb", <<~RUBY)
        class Loader
          def self.fetch = raise(ArgumentError, "unsupported")
        end
        class FileLoader < Loader
          def self.fetch = "file"
        end
      RUBY

      candidates = run_over([path])

      expect(outcome(row(candidates, "Loader", :fetch, :singleton))).to eq(:overridden_bot)
    end
  end

  describe "a raising module method that an includer overrides" do
    it "skips it when the including class overrides it" do
      path = write_fixture("lib/adapter.rb", <<~RUBY)
        module Db
          module SchemaStatements
            def indexes(table) = raise(ArgumentError, "unsupported")
          end
          class Adapter
            include SchemaStatements
            def indexes(table) = [table]
          end
        end
      RUBY

      candidates = run_over([path])

      expect(outcome(row(candidates, "Db::SchemaStatements", :indexes))).to eq(:overridden_bot)
    end

    it "skips it when a sibling module the subclass includes overrides it" do
      path = write_fixture("lib/adapter.rb", <<~RUBY)
        module Db
          module SchemaStatements
            def rename_table(from, to) = raise(ArgumentError, "unsupported")
          end
          class AbstractAdapter
            include SchemaStatements
          end
          module Pg
            module SchemaStatements
              def rename_table(from, to) = to
            end
          end
          class PgAdapter < AbstractAdapter
            include Pg::SchemaStatements
          end
        end
      RUBY

      candidates = run_over([path])

      expect(outcome(row(candidates, "Db::SchemaStatements", :rename_table))).to eq(:overridden_bot)
    end
  end

  describe "two included modules that define the same method" do
    it "skips the earlier include's method, which the later include overrides" do
      path = write_fixture("lib/adapter.rb", <<~RUBY)
        module Raising
          def quote(value) = raise(ArgumentError, "unsupported")
        end
        module Quoting
          def quote(value) = value.to_s
        end
        class Adapter
          include Raising
          include Quoting
        end
      RUBY

      candidates = run_over([path])

      expect(outcome(row(candidates, "Raising", :quote))).to eq(:overridden_bot)
    end
  end

  describe "a bot that comes from dispatch to an overridden hook" do
    it "skips the template method that calls the hook through self" do
      base = write_fixture("lib/source.rb", <<~RUBY)
        class Source
          def get_info(code) = load_info(code)

          protected

          def load_info(code) = invalid!("load_info")

          private

          def invalid!(name) = raise(ArgumentError, name)
        end
      RUBY
      impl = write_fixture("lib/source/ruby_source.rb", <<~RUBY)
        class Source
          class RubySource < Source
            protected

            def load_info(code) = code
          end
        end
      RUBY

      candidates = run_over([base, impl])

      expect(outcome(row(candidates, "Source", :get_info))).to eq(:template_method)
    end

    it "skips a method that calls the overridden hook on another receiver" do
      path = write_fixture("lib/zone.rb", <<~RUBY)
        class Source
          def identifiers = raise(ArgumentError, "identifiers")
        end
        class ZoneSource < Source
          def identifiers = ["UTC"]
        end
        class Zone
          def self.source = Source.new
          def self.all_identifiers = source.identifiers
        end
      RUBY

      candidates = run_over([path])

      expect(outcome(row(candidates, "Zone", :all_identifiers, :singleton))).to eq(:template_method)
    end

    it "skips a method whose bot reaches the hook through a self-dispatched helper" do
      path = write_fixture("lib/source.rb", <<~RUBY)
        class Source
          def outer = middle
          def middle = load_info
          def load_info = raise(ArgumentError, "load_info")
        end
        class RubySource < Source
          def load_info = "info"
        end
      RUBY

      candidates = run_over([path])

      expect(outcome(row(candidates, "Source", :outer))).to eq(:template_method)
    end
  end

  describe "an abstract-shaped body with no visible override" do
    it "skips a NotImplementedError body with the abstract-method reason" do
      path = write_fixture("lib/plugin.rb", <<~RUBY)
        class Plugin
          def about = raise(NotImplementedError)
          def name = raise(NotImplementedError, "subclasses define name")
        end
      RUBY

      candidates = run_over([path])

      expect(outcome(row(candidates, "Plugin", :about))).to eq(:abstract_method)
      expect(outcome(row(candidates, "Plugin", :name))).to eq(:abstract_method)
    end

    it "skips a raise whose message asks the reader to implement the method" do
      path = write_fixture("lib/plugin.rb", <<~RUBY)
        class Plugin
          class Error < StandardError; end

          def rules(context)
            raise Error.new("Please implement `rules(context)`")
          end
        end
      RUBY

      candidates = run_over([path])

      expect(outcome(row(candidates, "Plugin", :rules))).to eq(:abstract_method)
    end
  end

  describe "a final bot" do
    it "keeps a bot from throw" do
      path = write_fixture("lib/base.rb", <<~RUBY)
        class Base
          def halt(*response)
            response = response.first if response.length == 1
            throw :halt, response
          end
        end
      RUBY

      candidates = run_over([path])

      expect(outcome(row(candidates, "Base", :halt))).to eq("def halt: (*untyped) -> bot")
    end

    it "keeps a deliberate NoMethodError nothing overrides" do
      path = write_fixture("lib/restricted.rb", <<~RUBY)
        module Restricted
          def format(*args)
            fail NoMethodError,
              "you must call #format on an Image directly"
          end
        end
      RUBY

      candidates = run_over([path])

      expect(outcome(row(candidates, "Restricted", :format))).to eq("def format: (*untyped) -> bot")
    end

    it "keeps a method whose every branch raises, though it calls an overridden method" do
      path = write_fixture("lib/finder.rb", <<~RUBY)
        class Finder
          def label = "finder"

          def not_found!(ids)
            if ids.nil?
              raise ArgumentError, "no \#{label}"
            else
              raise ArgumentError, "some \#{label}"
            end
          end
        end
        class UserFinder < Finder
          def label = "user"
        end
      RUBY

      candidates = run_over([path])

      expect(outcome(row(candidates, "Finder", :not_found!))).to eq("def not_found!: (untyped) -> bot")
    end

    it "keeps a raise-only method that is not abstract-shaped and nothing overrides" do
      path = write_fixture("lib/guard.rb", <<~RUBY)
        class Guard
          def refuse! = raise(ArgumentError, "refused")
        end
        class StrictGuard < Guard
          def other = 1
        end
      RUBY

      candidates = run_over([path])

      expect(outcome(row(candidates, "Guard", :refuse!))).to eq("def refuse!: () -> bot")
    end
  end

  describe "a class whose every member is withheld" do
    it "still declares the class, so a subclass keeps its proposals" do
      path = write_fixture("lib/base.rb", <<~RUBY)
        class Base
          def name = raise(NotImplementedError)
        end
        class Sub < Base
          def name = "x"
          def size = 3
        end
      RUBY

      candidates = run_over([path])

      expect(outcome(row(candidates, "Base", :name))).to eq(:overridden_bot)
      expect(outcome(row(candidates, "Sub", :name))).to eq('def name: () -> "x"')
      expect(outcome(row(candidates, "Sub", :size))).to eq("def size: () -> 3")
      expect(row(candidates, "Sub", :size).class_shells).to include("Base")
    end

    it "still declares the class when nothing overrides its abstract method" do
      path = write_fixture("lib/base.rb", <<~RUBY)
        class Base
          def name = raise(NotImplementedError)
        end
        class Sub < Base
          def size = 3
        end
      RUBY

      candidates = run_over([path])

      expect(outcome(row(candidates, "Base", :name))).to eq(:abstract_method)
      expect(outcome(row(candidates, "Sub", :size))).to eq("def size: () -> 3")
    end

    it "rides the shell on a subclass's file when the base is alone in its own" do
      base = write_fixture("lib/base.rb", "class Base\n  def name = raise(NotImplementedError)\nend\n")
      sub = write_fixture("lib/sub.rb", "class Sub < Base\n  def size = 3\nend\n")

      candidates = run_over([base, sub])

      expect(outcome(row(candidates, "Sub", :size))).to eq("def size: () -> 3")
      expect(row(candidates, "Sub", :size).class_shells).to include("Base")
    end

    it "declares every withheld ancestor on a grandchild's file" do
      base = write_fixture("lib/base.rb", "class Base\n  def name = raise(NotImplementedError)\nend\n")
      mid = write_fixture("lib/mid.rb", "class Mid < Base\n  def kind = raise(NotImplementedError)\nend\n")
      leaf = write_fixture("lib/leaf.rb", "class Leaf < Mid\n  def size = 3\nend\n")

      candidates = run_over([base, mid, leaf])

      expect(outcome(row(candidates, "Leaf", :size))).to eq("def size: () -> 3")
      expect(row(candidates, "Leaf", :size).class_shells).to include("Base", "Mid")
    end

    it "shelters a base the #744 guard withheld, too" do
      path = write_fixture("lib/fmt.rb", <<~RUBY)
        class Base
          def target_class = nil
        end
        class RecordList < Base
          def target_class
            @cache ||= compute_something
          end
          def size = 3
        end
      RUBY

      candidates = run_over([path])

      expect(outcome(row(candidates, "Base", :target_class))).to eq(:overridden_by_unsigned_subclass)
      expect(outcome(row(candidates, "RecordList", :size))).to eq("def size: () -> 3")
    end

    it "takes the shell off again when the base's own superclass is unresolvable" do
      path = write_fixture("lib/base.rb", <<~RUBY)
        class Base < Nowhere::Known
          def name = raise(NotImplementedError)
        end
        class Sub < Base
          def size = 3
        end
      RUBY

      candidates = run_over([path])

      expect(outcome(row(candidates, "Sub", :size))).to eq(:unresolvable_superclass)
      expect(candidates.flat_map(&:class_shells)).not_to include("Base")
    end
  end

  describe "overrides the def tables alone do not show" do
    it "skips a base method a subclass redefines with define_method" do
      path = write_fixture("lib/base.rb", <<~RUBY)
        class Base
          def name = raise(ArgumentError, "unsupported")
        end
        class Sub < Base
          define_method(:name) { "sub" }
        end
      RUBY

      candidates = run_over([path])

      expect(outcome(row(candidates, "Base", :name))).to eq(:overridden_bot)
    end

    it "skips a module method that an extending class's own singleton method shadows" do
      path = write_fixture("lib/helpers.rb", <<~RUBY)
        module Helpers
          def label = raise(ArgumentError, "unsupported")
        end
        class Widget
          extend Helpers
          def self.label = "widget"
        end
      RUBY

      candidates = run_over([path])

      expect(outcome(row(candidates, "Helpers", :label))).to eq(:overridden_bot)
    end

    it "skips a class's own method that a prepended module shadows" do
      path = write_fixture("lib/widget.rb", <<~RUBY)
        module Loud
          def label = "LOUD"
        end
        class Widget
          prepend Loud
          def label = raise(ArgumentError, "unsupported")
        end
      RUBY

      candidates = run_over([path])

      expect(outcome(row(candidates, "Widget", :label))).to eq(:overridden_bot)
    end
  end

  describe "the order of the readings" do
    it "reports an unsigned override whose own proposal is withheld as overridden-bot, ahead of #744" do
      path = write_fixture("lib/base.rb", <<~RUBY)
        class Base
          def target = raise(ArgumentError, "unsupported")
        end
        class Sub < Base
          def target
            @cache ||= compute_something
          end
        end
      RUBY

      candidates = run_over([path])

      expect(outcome(row(candidates, "Base", :target))).to eq(:overridden_bot)
    end

    it "skips a template method whose hook is abstract and has no visible override" do
      path = write_fixture("lib/source.rb", <<~RUBY)
        class Source
          def get_info(code) = load_info(code)
          def load_info(code) = raise(NotImplementedError)
        end
      RUBY

      candidates = run_over([path])

      expect(outcome(row(candidates, "Source", :get_info))).to eq(:template_method)
    end

    it "does not read a call in a nested def as the method's own" do
      path = write_fixture("lib/setup.rb", <<~RUBY)
        class Setup
          def run
            def helper = load_info
            fail_now
          end
          def fail_now = raise(ArgumentError, "no")
          def load_info = raise(ArgumentError, "load_info")
        end
        class Custom < Setup
          def load_info = "info"
        end
      RUBY

      candidates = run_over([path])

      expect(outcome(row(candidates, "Setup", :run))).to eq("def run: () -> bot")
    end
  end

  describe "the abstract-message heuristic" do
    it "reads a message asking to define the method as abstract" do
      path = write_fixture("lib/plugin.rb", <<~RUBY)
        class Plugin
          def about = raise(ArgumentError, "Please define about")
        end
      RUBY

      expect(outcome(row(run_over([path]), "Plugin", :about))).to eq(:abstract_method)
    end

    it "keeps a message that only mentions a subclass or an override" do
      path = write_fixture("lib/check.rb", <<~RUBY)
        class Check
          def kind! = raise(TypeError, "subclass of Foo expected")
          def frozen! = raise(FrozenError, "cannot override frozen config")
        end
      RUBY

      candidates = run_over([path])

      expect(outcome(row(candidates, "Check", :kind!))).to eq("def kind!: () -> bot")
      expect(outcome(row(candidates, "Check", :frozen!))).to eq("def frozen!: () -> bot")
    end
  end

  describe "fix round 2 boundaries" do
    it "writes no shell for a class with a member it still emits" do
      path = write_fixture("lib/base.rb", <<~RUBY)
        class Base
          def name = raise(NotImplementedError)
          def size = 1
        end
        class Sub < Base
          def name = "x"
        end
      RUBY

      candidates = run_over([path])

      expect(outcome(row(candidates, "Base", :size))).to eq("def size: () -> 1")
      expect(candidates.flat_map(&:class_shells)).not_to include("Base")
    end

    it "keeps a module method an extending class only inherits" do
      path = write_fixture("lib/builder.rb", <<~RUBY)
        module Builder
          def build = raise(ArgumentError, "no")
        end
        class Factory
          extend Builder
        end
      RUBY

      candidates = run_over([path])

      expect(outcome(row(candidates, "Builder", :build))).to eq("def build: () -> bot")
    end

    it "keeps a final raise that asks for something other than a method" do
      path = write_fixture("lib/config.rb", <<~RUBY)
        class Config
          def block! = raise(ArgumentError, "you must define a block")
          def save! = raise(ArgumentError, "You need to define a name before saving")
          def env! = raise(KeyError, "please define FOO env var")
        end
      RUBY

      candidates = run_over([path])

      expect(%i[block! save! env!].map { |name| outcome(row(candidates, "Config", name)) })
        .to eq(["def block!: () -> bot", "def save!: () -> bot", "def env!: () -> bot"])
    end
  end
end
