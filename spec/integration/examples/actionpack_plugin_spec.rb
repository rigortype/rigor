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
ACTIVERECORD_LIB = File.expand_path("../../../examples/rigor-activerecord/lib", __dir__)
$LOAD_PATH.unshift(RAILS_ROUTES_LIB) unless $LOAD_PATH.include?(RAILS_ROUTES_LIB)
$LOAD_PATH.unshift(ACTIONPACK_LIB) unless $LOAD_PATH.include?(ACTIONPACK_LIB)
$LOAD_PATH.unshift(ACTIVERECORD_LIB) unless $LOAD_PATH.include?(ACTIVERECORD_LIB)
require "rigor-rails-routes"
require "rigor-actionpack"
require "rigor-activerecord"

SCHEMA_FOR_PHASE1 = <<~SCHEMA
  ActiveRecord::Schema.define do
    create_table :users do |t|
      t.string :name
      t.string :email
      t.string :role
    end
  end
SCHEMA

USER_MODEL_FOR_PHASE1 = <<~RUBY
  class User < ApplicationRecord
  end
RUBY

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

  describe "filter chains (Phase 2)" do
    def with_controllers(controllers:, routes: DEFAULT_AP_ROUTES_RB) # rubocop:disable Metrics/MethodLength
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.mkdir_p(File.join(dir, "app", "controllers"))
        File.write(File.join(dir, "config", "routes.rb"), routes)
        controllers.each do |relative, contents|
          full = File.join(dir, "app", "controllers", relative)
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, contents)
        end
        configuration = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge(
            "paths" => [File.join(dir, "app", "controllers")],
            "plugins" => %w[rigor-rails-routes rigor-actionpack]
          )
        )
        Dir.chdir(dir) do
          runner = Rigor::Analysis::Runner.new(
            configuration: configuration, cache_store: nil,
            plugin_requirer: lambda { |name|
              case name
              when "rigor-rails-routes" then Rigor::Plugin.register(Rigor::Plugin::RailsRoutes)
              when "rigor-actionpack" then Rigor::Plugin.register(Rigor::Plugin::Actionpack)
              end
              true
            }
          )
          yield runner.run
        end
      end
    end

    it "emits a `filter-call` info trace for a `before_action` referencing a defined method" do
      with_controllers(controllers: {
                         "users_controller.rb" => <<~RUBY
                           class UsersController
                             before_action :authenticate!
                             def authenticate!; end
                           end
                         RUBY
                       }) do |result|
        info = actionpack_diagnostics(result).find { |d| d.rule == "filter-call" }
        expect(info).not_to be_nil
        expect(info.severity).to eq(:info)
        expect(info.message).to include("before_action :authenticate!")
      end
    end

    it "fires `unknown-filter-method` with a did-you-mean for a typo'd filter name" do
      with_controllers(controllers: {
                         "users_controller.rb" => <<~RUBY
                           class UsersController
                             before_action :authenticat!
                             def authenticate!; end
                           end
                         RUBY
                       }) do |result|
        err = actionpack_diagnostics(result).find { |d| d.rule == "unknown-filter-method" }
        expect(err).not_to be_nil
        expect(err.severity).to eq(:error)
        expect(err.message).to include("authenticat!")
        expect(err.message).to include("Did you mean `:authenticate!`?")
      end
    end

    it "resolves filter methods inherited from a parent controller (one level)" do
      with_controllers(controllers: {
                         "application_controller.rb" => "class ApplicationController\n  def authenticate!; end\nend\n",
                         "users_controller.rb" => <<~RUBY
                           class UsersController < ApplicationController
                             before_action :authenticate!
                           end
                         RUBY
                       }) do |result|
        diags = actionpack_diagnostics(result)
        expect(diags.select { |d| d.rule == "unknown-filter-method" }).to be_empty
        expect(diags.select { |d| d.rule == "filter-call" }).not_to be_empty
      end
    end

    it "ignores the trailing `only:` / `except:` keyword hash when validating filter names" do
      with_controllers(controllers: {
                         "users_controller.rb" => <<~RUBY
                           class UsersController
                             before_action :set_user, only: %i[show edit]
                             def set_user; end
                             def show; end
                             def edit; end
                           end
                         RUBY
                       }) do |result|
        # `:show` and `:edit` are action names, NOT filter
        # names — Phase 2 must NOT flag them as unknown
        # filters. (Phase 2.5 will validate the action-name
        # arguments separately.)
        unknown = actionpack_diagnostics(result).select { |d| d.rule == "unknown-filter-method" }
        expect(unknown).to be_empty
      end
    end

    it "supports the full filter DSL family (skip_before_action, around_action, prepend_*)" do
      with_controllers(controllers: {
                         "users_controller.rb" => <<~RUBY
                           class UsersController
                             skip_before_action :authenticate!
                             around_action :log_request
                             prepend_before_action :setup
                             def authenticate!; end
                             def log_request; end
                             def setup; end
                           end
                         RUBY
                       }) do |result|
        infos = actionpack_diagnostics(result).select { |d| d.rule == "filter-call" }
        expect(infos.length).to eq(3)
      end
    end
  end

  describe "render targets (Phase 3)" do
    def with_render_demo(controller_source, views: {}) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.mkdir_p(File.join(dir, "app", "controllers"))
        File.write(File.join(dir, "config", "routes.rb"), DEFAULT_AP_ROUTES_RB)
        File.write(File.join(dir, "app", "controllers", "users_controller.rb"), controller_source)
        views.each do |relative, contents|
          full = File.join(dir, "app", "views", relative)
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, contents)
        end
        configuration = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge(
            "paths" => [File.join(dir, "app", "controllers")],
            "plugins" => %w[rigor-rails-routes rigor-actionpack]
          )
        )
        Dir.chdir(dir) do
          runner = Rigor::Analysis::Runner.new(
            configuration: configuration, cache_store: nil,
            plugin_requirer: lambda { |name|
              case name
              when "rigor-rails-routes" then Rigor::Plugin.register(Rigor::Plugin::RailsRoutes)
              when "rigor-actionpack" then Rigor::Plugin.register(Rigor::Plugin::Actionpack)
              end
              true
            }
          )
          yield runner.run
        end
      end
    end

    it "resolves `render :show` to `app/views/users/show.html.erb`" do
      with_render_demo(
        "class UsersController\n  def show\n    render :show\n  end\nend\n",
        views: { "users/show.html.erb" => "<h1>Show</h1>\n" }
      ) do |result|
        info = actionpack_diagnostics(result).find { |d| d.rule == "render-target" }
        expect(info).not_to be_nil
        expect(info.severity).to eq(:info)
        expect(info.message).to include("users/show")
        expect(info.message).to include(".html.erb")
      end
    end

    it "resolves `render \"shared/header\"` to `app/views/shared/header.html.erb`" do
      with_render_demo(
        "class UsersController\n  def show\n    render \"shared/header\"\n  end\nend\n",
        views: { "shared/header.html.erb" => "<header></header>\n" }
      ) do |result|
        info = actionpack_diagnostics(result).find { |d| d.rule == "render-target" }
        expect(info).not_to be_nil
        expect(info.message).to include("shared/header")
      end
    end

    it "resolves `render partial: \"user\"` to `app/views/users/_user.html.erb`" do
      with_render_demo(
        "class UsersController\n  def show\n    render partial: \"user\"\n  end\nend\n",
        views: { "users/_user.html.erb" => "<%= @user %>\n" }
      ) do |result|
        info = actionpack_diagnostics(result).find { |d| d.rule == "render-target" }
        expect(info).not_to be_nil
        expect(info.message).to include("users/_user")
      end
    end

    it "fires `missing-template` when the resolved view doesn't exist" do
      with_render_demo(
        "class UsersController\n  def show\n    render :missing\n  end\nend\n"
      ) do |result|
        err = actionpack_diagnostics(result).find { |d| d.rule == "missing-template" }
        expect(err).not_to be_nil
        expect(err.severity).to eq(:error)
        expect(err.message).to include("users/missing")
      end
    end

    it "checks `.text.erb` as a fallback extension" do
      with_render_demo(
        "class UsersController\n  def show\n    render :show\n  end\nend\n",
        views: { "users/show.text.erb" => "Show\n" }
      ) do |result|
        info = actionpack_diagnostics(result).find { |d| d.rule == "render-target" }
        expect(info).not_to be_nil
        expect(info.message).to include(".text.erb")
      end
    end

    it "ignores `render plain:` / `render json:` / `render layout:` and other non-template shapes" do
      with_render_demo(
        <<~RUBY
          class UsersController
            def show; render plain: "ok"; end
            def as_json; render json: { ok: true }; end
            def with_layout; render layout: "admin"; end
          end
        RUBY
      ) do |result|
        renders = actionpack_diagnostics(result).select do |d|
          %w[render-target missing-template].include?(d.rule)
        end
        expect(renders).to be_empty
      end
    end
  end

  describe "strong parameters (Phase 1)" do
    def with_strong_params(controller_source) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.mkdir_p(File.join(dir, "app", "controllers"))
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        FileUtils.mkdir_p(File.join(dir, "db"))
        File.write(File.join(dir, "config", "routes.rb"), DEFAULT_AP_ROUTES_RB)
        File.write(File.join(dir, "db", "schema.rb"), SCHEMA_FOR_PHASE1)
        File.write(File.join(dir, "app", "models", "user.rb"), USER_MODEL_FOR_PHASE1)
        File.write(File.join(dir, "app", "controllers", "users_controller.rb"), controller_source)
        configuration = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge(
            "paths" => [File.join(dir, "app", "controllers")],
            "plugins" => %w[rigor-rails-routes rigor-activerecord rigor-actionpack]
          )
        )
        Dir.chdir(dir) do
          runner = Rigor::Analysis::Runner.new(
            configuration: configuration, cache_store: nil,
            plugin_requirer: lambda { |name|
              case name
              when "rigor-rails-routes" then Rigor::Plugin.register(Rigor::Plugin::RailsRoutes)
              when "rigor-activerecord" then Rigor::Plugin.register(Rigor::Plugin::Activerecord)
              when "rigor-actionpack" then Rigor::Plugin.register(Rigor::Plugin::Actionpack)
              end
              true
            }
          )
          yield runner.run
        end
      end
    end

    it "emits a `permit-call` info trace for `params.require(:user).permit(:name)`" do
      with_strong_params(<<~RUBY) do |result|
        class UsersController
          def create
            params.require(:user).permit(:name, :email)
          end
        end
      RUBY
        info = actionpack_diagnostics(result).find { |d| d.rule == "permit-call" }
        expect(info).not_to be_nil
        expect(info.severity).to eq(:info)
        expect(info.message).to include("User")
      end
    end

    it "fires `unknown-permit-key` with did-you-mean for a non-column kwarg" do
      with_strong_params(<<~RUBY) do |result|
        class UsersController
          def create
            params.require(:user).permit(:name, :rol)
          end
        end
      RUBY
        err = actionpack_diagnostics(result).find { |d| d.rule == "unknown-permit-key" }
        expect(err).not_to be_nil
        expect(err.severity).to eq(:error)
        expect(err.message).to include("rol")
        expect(err.message).to include("Did you mean `:role`?")
      end
    end

    it "skips silently when the model isn't in the published index" do
      with_strong_params(<<~RUBY) do |result|
        class UsersController
          def create
            params.require(:ghost).permit(:any_key_at_all)
          end
        end
      RUBY
        diags = actionpack_diagnostics(result).select do |d|
          %w[permit-call unknown-permit-key].include?(d.rule)
        end
        expect(diags).to be_empty
      end
    end

    it "passes through non-literal `:permit` arguments without recognising them" do
      with_strong_params(<<~RUBY) do |result|
        class UsersController
          def create
            keys = [:name]
            params.require(:user).permit(*keys)
          end
        end
      RUBY
        diags = actionpack_diagnostics(result).select do |d|
          d.rule == "unknown-permit-key"
        end
        expect(diags).to be_empty
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
