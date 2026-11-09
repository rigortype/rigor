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
end
