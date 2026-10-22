# frozen_string_literal: true

# ADR-125 (#575, #2308) — rigor-actionmailer declares `ActionMailer::Base` in `per_invocation_classes:`, so
# `def.ivar-write-mismatch` stops comparing ivar writes that sit in two different public actions of a mailer: a
# mailer instance serves one action. Every other shape keeps firing.

require "spec_helper"
require "fileutils"
require "tmpdir"

ACTIONMAILER_PER_INVOCATION_LIB = File.expand_path("../../../plugins/rigor-actionmailer/lib", __dir__)
$LOAD_PATH.unshift(ACTIONMAILER_PER_INVOCATION_LIB) unless $LOAD_PATH.include?(ACTIONMAILER_PER_INVOCATION_LIB)
require "rigor-actionmailer"

PER_INVOCATION_APPLICATION_MAILER = <<~RUBY
  class ApplicationMailer < ActionMailer::Base
  end
RUBY

RSpec.describe "def.ivar-write-mismatch on mailers (ADR-125)" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  # The `def.ivar-write-mismatch` rows of a run over `files` (relative path => source), as `[file basename, line]`.
  def mismatches(files, plugins: %w[rigor-actionmailer])
    Dir.mktmpdir do |dir|
      files.each do |relative, source|
        path = File.join(dir, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, source)
      end
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => [File.join(dir, "app")], "plugins" => plugins)
      )
      Dir.chdir(dir) do
        runner = Rigor::Analysis::Runner.new(
          configuration: configuration, cache_store: nil,
          plugin_requirer: lambda do |_name|
            Rigor::Plugin.register(Rigor::Plugin::Actionmailer)
            true
          end
        )
        rows = guarded_run(runner).diagnostics.select { |d| d.rule == "def.ivar-write-mismatch" }
        rows.map { |d| [File.basename(d.path), d.line] }
      end
    end
  end

  def mailer(body, superclass: "ApplicationMailer")
    { "app/mailers/application_mailer.rb" => PER_INVOCATION_APPLICATION_MAILER,
      "app/mailers/user_mailer.rb" => "class UserMailer < #{superclass}\n#{body}end\n" }
  end

  it "is silent on divergent writes in two public actions, through an ApplicationMailer superclass" do
    files = mailer(<<~RUBY)
      def welcome
        @items = [1, 2]
      end

      def digest
        @items = { a: 1 }
      end
    RUBY
    expect(mismatches(files)).to eq([])
  end

  it "is silent on a mailer that inherits ActionMailer::Base directly" do
    files = mailer(<<~RUBY, superclass: "ActionMailer::Base")
      def welcome
        @items = [1, 2]
      end

      def digest
        @items = { a: 1 }
      end
    RUBY
    expect(mismatches(files)).to eq([])
  end

  it "still reports the mailer when rigor-actionmailer is not loaded" do
    files = mailer(<<~RUBY)
      def welcome
        @items = [1, 2]
      end

      def digest
        @items = { a: 1 }
      end
    RUBY
    expect(mismatches(files, plugins: [])).to eq([["user_mailer.rb", 7]])
  end

  it "still reports a non-mailer class with the same two-method shape" do
    files = { "app/models/report.rb" => <<~RUBY }
      class Report
        def welcome
          @items = [1, 2]
        end

        def digest
          @items = { a: 1 }
        end
      end
    RUBY
    expect(mismatches(files)).to eq([["report.rb", 7]])
  end

  it "still reports two divergent writes inside one mailer action" do
    files = mailer(<<~RUBY)
      def welcome
        @items = [1, 2]
        @items = { a: 1 }
      end
    RUBY
    expect(mismatches(files)).to eq([["user_mailer.rb", 4]])
  end

  it "still reports a private helper whose write diverges from an action's" do
    files = mailer(<<~RUBY)
      def welcome
        @items = [1, 2]
      end

      def digest
        build_items
      end

      private

      def build_items
        @items = { a: 1 }
      end
    RUBY
    expect(mismatches(files)).to eq([["user_mailer.rb", 13]])
  end

  it "still reports a protected helper whose write diverges from an action's" do
    files = mailer(<<~RUBY)
      def welcome
        @items = [1, 2]
      end

      protected

      def build_items
        @items = { a: 1 }
      end
    RUBY
    expect(mismatches(files)).to eq([["user_mailer.rb", 9]])
  end

  it "still reports a public before_action target whose write diverges from an action's" do
    files = mailer(<<~RUBY)
      before_action :load_items

      def welcome
        @items = [1, 2]
      end

      def load_items
        @items = { a: 1 }
      end
    RUBY
    expect(mismatches(files)).to eq([["user_mailer.rb", 9]])
  end

  it "still reports a public after_action target declared with a prepend_ form" do
    files = mailer(<<~RUBY)
      prepend_after_action :load_items

      def welcome
        @items = [1, 2]
      end

      def load_items
        @items = { a: 1 }
      end
    RUBY
    expect(mismatches(files)).to eq([["user_mailer.rb", 9]])
  end

  it "still reports a public helper_method whose write diverges from an action's" do
    files = mailer(<<~RUBY)
      helper_method :current_items

      def welcome
        @items = [1, 2]
        current_items
      end

      def current_items
        @items = { a: 1 }
      end
    RUBY
    expect(mismatches(files)).to eq([["user_mailer.rb", 10]])
  end

  it "still reports a mailer action whose write diverges from initialize's" do
    files = mailer(<<~RUBY)
      def initialize
        super
        @items = { a: 1 }
      end

      def welcome
        @items = [1, 2]
      end
    RUBY
    expect(mismatches(files)).to eq([["user_mailer.rb", 8]])
  end
end
