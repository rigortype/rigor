# frozen_string_literal: true

# Integration spec for `examples/rigor-rails-routes/`.
# Tier 1A of the Rails plugins roadmap. Statically interprets
# `config/routes.rb`'s DSL via Prism and validates every
# `*_path` / `*_url` call site against the resulting helper
# table.

require "spec_helper"

RAILS_ROUTES_PLUGIN_LIB = File.expand_path("../../../examples/rigor-rails-routes/lib", __dir__)
$LOAD_PATH.unshift(RAILS_ROUTES_PLUGIN_LIB) unless $LOAD_PATH.include?(RAILS_ROUTES_PLUGIN_LIB)
require "rigor-rails-routes"

DEFAULT_ROUTES_RB = <<~RUBY
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

RSpec.describe "examples/rigor-rails-routes" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::RailsRoutes }

  describe "recognised helpers" do
    it "surfaces an info diagnostic for a top-level resources index helper" do
      result = run_plugin(
        source: "users_path\n",
        files: { "config/routes.rb" => DEFAULT_ROUTES_RB }
      )
      info = plugin_diagnostics(result).find { |d| d.message.include?("users_path") }
      expect(info).not_to be_nil
      expect(info.severity).to eq(:info)
      expect(info.message).to include("GET /users")
    end

    it "recognises nested resources helpers (`user_post_path`)" do
      result = run_plugin(
        source: "user_post_path(1, 2)\n",
        files: { "config/routes.rb" => DEFAULT_ROUTES_RB }
      )
      info = plugin_diagnostics(result).find { |d| d.message.include?("user_post_path") }
      expect(info).not_to be_nil
      expect(info.severity).to eq(:info)
    end

    it "recognises namespaced resources (`admin_widgets_path`)" do
      result = run_plugin(
        source: "admin_widgets_path\n",
        files: { "config/routes.rb" => DEFAULT_ROUTES_RB }
      )
      info = plugin_diagnostics(result).find { |d| d.message.include?("admin_widgets_path") }
      expect(info).not_to be_nil
    end

    it "recognises explicit `get '/about', as: :about` as `about_path`" do
      result = run_plugin(
        source: "about_path\n",
        files: { "config/routes.rb" => DEFAULT_ROUTES_RB }
      )
      info = plugin_diagnostics(result).find { |d| d.message.include?("about_path") }
      expect(info).not_to be_nil
      expect(info.message).to include("GET /about")
    end

    it "exposes both `_path` and `_url` forms" do
      result = run_plugin(
        source: "users_url\n",
        files: { "config/routes.rb" => DEFAULT_ROUTES_RB }
      )
      info = plugin_diagnostics(result).find { |d| d.message.include?("users_url") }
      expect(info).not_to be_nil
    end
  end

  describe "diagnostic errors" do
    it "flags a typo'd helper with a did-you-mean suggestion" do
      result = run_plugin(
        source: "usres_path\n",
        files: { "config/routes.rb" => DEFAULT_ROUTES_RB }
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "unknown-helper" }
      expect(err).not_to be_nil
      expect(err.severity).to eq(:error)
      expect(err.message).to include("usres_path")
      expect(err.message).to include("users_path")
    end

    it "flags a wrong-arity call (`user_path` expects 1 arg)" do
      result = run_plugin(
        source: "user_path(1, 2, 3)\n",
        files: { "config/routes.rb" => DEFAULT_ROUTES_RB }
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "wrong-arity" }
      expect(err).not_to be_nil
      expect(err.message).to include("user_path")
      expect(err.message).to include("1")
      expect(err.message).to include("3")
    end

    it "flags a missing-arg arity error (`user_path` called with no arg)" do
      result = run_plugin(
        source: "user_path\n",
        files: { "config/routes.rb" => DEFAULT_ROUTES_RB }
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "wrong-arity" }
      expect(err).not_to be_nil
      expect(err.message).to include("got 0")
    end
  end

  describe "edge cases" do
    it "skips calls with explicit receivers (`obj.users_path` is not a route helper)" do
      result = run_plugin(
        source: "obj = Object.new; obj.users_path\n",
        files: { "config/routes.rb" => DEFAULT_ROUTES_RB }
      )
      diags = plugin_diagnostics(result)
      expect(diags.find { |d| d.message.include?("users_path") }).to be_nil
    end

    it "stays silent when the routes file is missing (warns once, no per-call errors)" do
      result = run_plugin(source: "users_path\n")
      diags = plugin_diagnostics(result)
      load_error = diags.find { |d| d.rule == "load-error" }
      expect(load_error).not_to be_nil
      expect(load_error.severity).to eq(:warning)
      expect(diags.find { |d| d.rule == "unknown-helper" }).to be_nil
    end
  end

  describe "ADR-9 cross-plugin fact publication" do
    it "publishes the `:helper_table` fact during prepare" do
      # FactStore is constructed once per Services / per run;
      # capture it as the runner builds Services so we can
      # read the fact back after `prepare` has fired.
      captured_store = nil
      allow(Rigor::Plugin::Services).to receive(:new).and_wrap_original do |original, **kwargs|
        services = original.call(**kwargs)
        captured_store = services.fact_store
        services
      end

      run_plugin(source: "users_path\n", files: { "config/routes.rb" => DEFAULT_ROUTES_RB })

      table = captured_store.read(plugin_id: "rails-routes", name: :helper_table)
      expect(table).to be_a(Hash)
      expect(table).to have_key("users_path")
      expect(table["users_path"]).to include(arity: 0, action: :index)
    end
  end
end
