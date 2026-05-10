# frozen_string_literal: true

# Integration spec for `examples/rigor-actionpack/` (Phase 4
# — route-helper consumption). Tests the cross-plugin
# integration end to end: rigor-rails-routes parses
# `config/routes.rb` and publishes the helper table; the
# loader's ADR-9 topo sort runs `prepare` first; then
# rigor-actionpack reads the published helper table and
# validates `*_path` / `*_url` calls inside controller files.

require "spec_helper"
require "fileutils"
require "tmpdir"

RAILS_ROUTES_LIB = File.expand_path("../../../examples/rigor-rails-routes/lib", __dir__)
ACTIONPACK_LIB = File.expand_path("../../../examples/rigor-actionpack/lib", __dir__)
$LOAD_PATH.unshift(RAILS_ROUTES_LIB) unless $LOAD_PATH.include?(RAILS_ROUTES_LIB)
$LOAD_PATH.unshift(ACTIONPACK_LIB) unless $LOAD_PATH.include?(ACTIONPACK_LIB)
require "rigor-rails-routes"
require "rigor-actionpack"

DEFAULT_AP_ROUTES_RB = <<~RUBY
  Rails.application.routes.draw do
    root to: "home#index"
    resources :users do
      resources :posts
    end
    resource :profile
    namespace :admin do
      resources :widgets
    end
    get "/about", to: "static#about", as: :about
  end
RUBY

RSpec.describe "examples/rigor-actionpack" do # rubocop:disable RSpec/DescribeClass
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  def with_demo(controller_source, routes: DEFAULT_AP_ROUTES_RB) # rubocop:disable Metrics/MethodLength
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      FileUtils.mkdir_p(File.join(dir, "app", "controllers"))
      File.write(File.join(dir, "config", "routes.rb"), routes)
      File.write(File.join(dir, "app", "controllers", "demo_controller.rb"), controller_source)

      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          "paths" => [File.join(dir, "app", "controllers")],
          "plugins" => %w[rigor-rails-routes rigor-actionpack]
        )
      )

      Dir.chdir(dir) do
        runner = Rigor::Analysis::Runner.new(
          configuration: configuration,
          cache_store: nil,
          plugin_requirer: lambda do |name|
            case name
            when "rigor-rails-routes" then Rigor::Plugin.register(Rigor::Plugin::RailsRoutes)
            when "rigor-actionpack" then Rigor::Plugin.register(Rigor::Plugin::Actionpack)
            end
            true
          end
        )
        yield runner.run
      end
    end
  end

  def actionpack_diagnostics(result)
    result.diagnostics.select { |d| d.source_family == "plugin.actionpack" }
  end

  describe "recognised helper calls" do
    it "emits an info trace for a bare resources index helper (`users_path`)" do
      with_demo("class C\n  def show\n    users_path\n  end\nend\n") do |result|
        info = actionpack_diagnostics(result).find { |d| d.message.include?("users_path") }
        expect(info).not_to be_nil
        expect(info.severity).to eq(:info)
        expect(info.message).to include("GET /users")
        expect(info.rule).to eq("helper-call")
      end
    end

    it "recognises a positional-arg helper with a trailing keyword hash" do
      source = "class C\n  def show\n    user_path(@user, format: :json)\n  end\nend\n"
      with_demo(source) do |result|
        diags = actionpack_diagnostics(result).select { |d| d.message.include?("user_path") }
        expect(diags.map(&:severity)).to contain_exactly(:info)
      end
    end

    it "recognises nested-resource helpers with the right arity" do
      source = "class C\n  def show\n    user_post_path(@u, @p)\n  end\nend\n"
      with_demo(source) do |result|
        info = actionpack_diagnostics(result).find { |d| d.message.include?("user_post_path") }
        expect(info).not_to be_nil
        expect(info.severity).to eq(:info)
      end
    end

    it "recognises namespaced helpers" do
      source = "class C\n  def show\n    admin_widget_path(@w)\n  end\nend\n"
      with_demo(source) do |result|
        info = actionpack_diagnostics(result).find { |d| d.message.include?("admin_widget_path") }
        expect(info).not_to be_nil
      end
    end

    it "recognises the `_url` form identically to `_path`" do
      source = "class C\n  def show\n    user_url(@user)\n  end\nend\n"
      with_demo(source) do |result|
        info = actionpack_diagnostics(result).find { |d| d.message.include?("user_url") }
        expect(info).not_to be_nil
      end
    end
  end

  describe "error diagnostics" do
    it "fires `unknown-helper` with a did-you-mean suggestion on a typo" do
      source = "class C\n  def show\n    usres_path\n  end\nend\n"
      with_demo(source) do |result|
        err = actionpack_diagnostics(result).find { |d| d.rule == "unknown-helper" }
        expect(err).not_to be_nil
        expect(err.severity).to eq(:error)
        expect(err.message).to include("usres_path")
        expect(err.message).to include("Did you mean `users_path`?")
      end
    end

    it "fires `wrong-helper-arity` when a positional arg is missing" do
      source = "class C\n  def show\n    user_path\n  end\nend\n"
      with_demo(source) do |result|
        err = actionpack_diagnostics(result).find { |d| d.rule == "wrong-helper-arity" }
        expect(err).not_to be_nil
        expect(err.severity).to eq(:error)
        expect(err.message).to include("expects 1 positional argument")
        expect(err.message).to include("but the call passes 0")
      end
    end

    it "fires `wrong-helper-arity` when a nested helper is under-supplied" do
      source = "class C\n  def show\n    user_post_path(@user)\n  end\nend\n"
      with_demo(source) do |result|
        err = actionpack_diagnostics(result).find { |d| d.rule == "wrong-helper-arity" }
        expect(err).not_to be_nil
        expect(err.message).to include("expects 2")
        expect(err.message).to include("passes 1")
      end
    end
  end

  describe "scope filtering" do
    it "skips files outside `controller_search_paths`" do # rubocop:disable RSpec/ExampleLength
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "config", "routes.rb"), DEFAULT_AP_ROUTES_RB)
        File.write(File.join(dir, "lib", "noncontroller.rb"), "usres_path\n")

        configuration = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge(
            "paths" => [File.join(dir, "lib")],
            "plugins" => %w[rigor-rails-routes rigor-actionpack]
          )
        )

        Dir.chdir(dir) do
          runner = Rigor::Analysis::Runner.new(
            configuration: configuration,
            cache_store: nil,
            plugin_requirer: lambda do |name|
              case name
              when "rigor-rails-routes" then Rigor::Plugin.register(Rigor::Plugin::RailsRoutes)
              when "rigor-actionpack" then Rigor::Plugin.register(Rigor::Plugin::Actionpack)
              end
              true
            end
          )
          result = runner.run
          # The rails-routes plugin still validates the `usres_path`
          # call (its own walker doesn't filter by path), but
          # actionpack's path filter must skip the lib/ file.
          ap_diags = result.diagnostics.select { |d| d.source_family == "plugin.actionpack" }
          expect(ap_diags).to be_empty
        end
      end
    end
  end

  describe "graceful degradation" do
    it "runs as a no-op when rigor-rails-routes isn't loaded (helper table absent)" do # rubocop:disable RSpec/ExampleLength
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers"))
        File.write(
          File.join(dir, "app", "controllers", "demo_controller.rb"),
          "class C\n  def show\n    users_path\n  end\nend\n"
        )

        configuration = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge(
            "paths" => [File.join(dir, "app", "controllers")],
            "plugins" => %w[rigor-actionpack]
          )
        )

        Dir.chdir(dir) do
          runner = Rigor::Analysis::Runner.new(
            configuration: configuration,
            cache_store: nil,
            plugin_requirer: lambda do |name|
              Rigor::Plugin.register(Rigor::Plugin::Actionpack) if name == "rigor-actionpack"
              true
            end
          )
          result = runner.run
          ap_diags = result.diagnostics.select { |d| d.source_family == "plugin.actionpack" }
          # Without the helper table, Phase 4 silently no-ops.
          expect(ap_diags).to be_empty
        end
      end
    end
  end
end
