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
  def mismatches(files, plugins: %w[rigor-actionpack], signature_paths: nil)
    Dir.mktmpdir do |dir|
      files.each do |relative, source|
        path = File.join(dir, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, source)
      end
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          "paths" => [File.join(dir, "app")], "plugins" => plugins,
          "signature_paths" => signature_paths&.map { |path| File.join(dir, path) }
        )
      )
      Dir.chdir(dir) do
        runner = Rigor::Analysis::Runner.new(
          configuration: configuration, cache_store: nil,
          plugin_requirer: lambda do |_name|
            Rigor::Plugin.register(Rigor::Plugin::Actionpack)
            true
          end
        )
        rows = guarded_run(runner).diagnostics.select { |d| d.rule == "def.ivar-write-mismatch" }
        rows.map { |d| [File.basename(d.path), d.line] }
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

  it "still reports a public helper_method whose write diverges from an action's" do
    files = controller(<<~RUBY)
      helper_method :current_roles

      def index
        @roles = [1, 2]
        current_roles
      end

      def current_roles
        @roles = { a: 1 }
      end
    RUBY
    expect(mismatches(files)).to eq([["roles.rb", 10]])
  end

  it "still reports a public before_action target whose write diverges from an action's" do
    files = controller(<<~RUBY)
      before_action :load_roles

      def index
        @roles = [1, 2]
      end

      def load_roles
        @roles = { a: 1 }
      end
    RUBY
    expect(mismatches(files)).to eq([["roles.rb", 9]])
  end

  it "still reports a helper_method declared inline around its def" do
    files = controller(<<~RUBY)
      def index
        @roles = [1, 2]
        current_roles
      end

      helper_method def current_roles
        @roles = { a: 1 }
      end
    RUBY
    expect(mismatches(files)).to eq([["roles.rb", 8]])
  end

  it "still reports a helper_method declared through a self. receiver" do
    files = controller(<<~RUBY)
      self.helper_method :current_roles

      def index
        @roles = [1, 2]
      end

      def current_roles
        @roles = { a: 1 }
      end
    RUBY
    expect(mismatches(files)).to eq([["roles.rb", 9]])
  end

  it "still reports a before_action target named by a String" do
    files = controller(<<~RUBY)
      before_action "load_roles"

      def index
        @roles = [1, 2]
      end

      def load_roles
        @roles = { a: 1 }
      end
    RUBY
    expect(mismatches(files)).to eq([["roles.rb", 9]])
  end

  it "is silent when a macro the plugin does not declare names an action" do
    files = controller(<<~RUBY)
      track_usage :permissions

      def index
        @roles = [1, 2]
      end

      def permissions
        @roles = { a: 1 }
      end
    RUBY
    expect(mismatches(files)).to eq([])
  end

  # Issue #1821's shape: a literal no Symbol can hold names no method, and must not crash the collector.
  it "does not raise on a macro argument with invalid bytes, with or without the plugin" do
    body = <<~RUBY
      before_action "\\xff"

      def index
        @roles = [1, 2]
      end

      def show
        @roles = { a: 1 }
      end
    RUBY
    expect(mismatches(controller(body))).to eq([])
    expect(mismatches(controller(body), plugins: [])).to eq([["roles.rb", 9]])
  end

  it "still reports an action whose visibility a conditional define_method leaves unsettled" do
    files = controller(<<~RUBY)
      def index
        @roles = [1, 2]
      end

      def show
        @roles = { a: 1 }
      end
      define_method(:show) { nil } if ENV["X"]
    RUBY
    expect(mismatches(files)).to eq([["roles.rb", 7]])
  end

  it "still reports a controller whose superclass spelling names a project-declared class" do
    files = { "app/controllers/roles.rb" => <<~RUBY }
      module MyApp
        module ActionController
          class Base
          end
        end

        class RolesController < ActionController::Base
          def index
            @roles = [1, 2]
          end

          def permissions
            @roles = { a: 1 }
          end
        end
      end
    RUBY
    expect(mismatches(files)).to eq([["roles.rb", 13]])
  end

  context "when the project's RBS declares the controller hierarchy" do
    let(:signature) do
      { "sig/action_controller.rbs" => <<~RBS }
        module ActionController
          class Metal
          end

          class Base < Metal
          end
        end

        class AdminBase < ActionController::Base
        end
      RBS
    end

    it "is silent on a controller whose RBS-known superclass is a declared class" do
      files = controller(<<~RUBY, superclass: "ActionController::Base").merge(signature)
        def index
          @roles = [1, 2]
        end

        def show
          @roles = { a: 1 }
        end
      RUBY
      expect(mismatches(files, signature_paths: ["sig"])).to eq([])
    end

    it "is silent on a controller whose RBS-known superclass is a subclass of a declared class" do
      files = controller(<<~RUBY, superclass: "AdminBase").merge(signature)
        def index
          @roles = [1, 2]
        end

        def show
          @roles = { a: 1 }
        end
      RUBY
      expect(mismatches(files, signature_paths: ["sig"])).to eq([])
    end

    it "still reports a controller on ActionController::Metal, which is not declared per-invocation" do
      files = controller(<<~RUBY, superclass: "ActionController::Metal").merge(signature)
        def index
          @roles = [1, 2]
        end

        def show
          @roles = { a: 1 }
        end
      RUBY
      expect(mismatches(files, signature_paths: ["sig"])).to eq([["roles.rb", 7]])
    end
  end
end
