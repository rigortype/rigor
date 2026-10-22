# frozen_string_literal: true

# ADR-125 (#575) — rigor-actionpack declares `ActionController::Base` / `ActionController::API` in
# `per_invocation_classes:`, so `def.ivar-write-mismatch` stops comparing ivar writes that sit in two different
# public actions of a controller: Rails runs one action per controller instance. Every other shape keeps firing.

require "spec_helper"
require "fileutils"
require "tmpdir"

ACTIONPACK_PER_INVOCATION_LIB = File.expand_path("../../../plugins/rigor-actionpack/lib", __dir__)
$LOAD_PATH.unshift(ACTIONPACK_PER_INVOCATION_LIB) unless $LOAD_PATH.include?(ACTIONPACK_PER_INVOCATION_LIB)
require "rigor-actionpack"

PER_INVOCATION_APPLICATION_CONTROLLER = <<~RUBY
  class ApplicationController < ActionController::Base
  end
RUBY

RSpec.describe "def.ivar-write-mismatch on per-invocation classes (ADR-125)" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  # The `def.ivar-write-mismatch` rows of a run over `files` (relative path => source), as `[file basename, line]`.
  def mismatches(files, plugins: %w[rigor-actionpack])
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
            Rigor::Plugin.register(Rigor::Plugin::Actionpack)
            true
          end
        )
        runner.run.diagnostics.select { |d| d.rule == "def.ivar-write-mismatch" }
              .map { |d| [File.basename(d.path), d.line] }
      end
    end
  end

  def controller(body, superclass: "ApplicationController", name: "RolesController")
    { "app/controllers/application_controller.rb" => PER_INVOCATION_APPLICATION_CONTROLLER,
      "app/controllers/roles.rb" => "class #{name} < #{superclass}\n#{body}end\n" }
  end

  it "is silent on divergent writes in two public actions, through an ApplicationController superclass" do
    files = controller(<<~RUBY)
      def index
        @roles = [1, 2]
      end

      def permissions
        @roles = { a: 1 }
      end
    RUBY
    expect(mismatches(files)).to eq([])
  end

  it "is silent on a controller that inherits ActionController::API directly" do
    files = controller(<<~RUBY, superclass: "ActionController::API")
      def index
        @roles = [1, 2]
      end

      def show
        @roles = { a: 1 }
      end
    RUBY
    expect(mismatches(files)).to eq([])
  end

  it "still reports the controller when rigor-actionpack is not loaded" do
    files = controller(<<~RUBY)
      def index
        @roles = [1, 2]
      end

      def permissions
        @roles = { a: 1 }
      end
    RUBY
    expect(mismatches(files, plugins: [])).to eq([["roles.rb", 7]])
  end

  it "still reports a class that is not a controller" do
    files = { "app/models/report.rb" => <<~RUBY }
      class Report
        def index
          @roles = [1, 2]
        end

        def permissions
          @roles = { a: 1 }
        end
      end
    RUBY
    expect(mismatches(files)).to eq([["report.rb", 7]])
  end

  it "still reports two divergent writes inside one action" do
    files = controller(<<~RUBY)
      def index
        @roles = [1, 2]
        @roles = { a: 1 }
      end
    RUBY
    expect(mismatches(files)).to eq([["roles.rb", 4]])
  end

  it "still reports an action whose write diverges from a before_action target's" do
    files = controller(<<~RUBY)
      before_action :load_roles

      def load_roles
        @roles = { a: 1 }
      end
      private :load_roles

      def index
        @roles = [1, 2]
      end
    RUBY
    expect(mismatches(files)).to eq([["roles.rb", 10]])
  end

  it "still reports a private helper whose write diverges from an action's" do
    files = controller(<<~RUBY)
      def index
        @roles = [1, 2]
      end

      def show
        build_roles
      end

      private

      def build_roles
        @roles = { a: 1 }
      end
    RUBY
    expect(mismatches(files)).to eq([["roles.rb", 13]])
  end

  it "still reports an action whose write diverges from initialize's" do
    files = controller(<<~RUBY)
      def initialize
        super
        @roles = { a: 1 }
      end

      def index
        @roles = [1, 2]
      end
    RUBY
    expect(mismatches(files)).to eq([["roles.rb", 8]])
  end
end
