# frozen_string_literal: true

# Integration spec for `plugins/rigor-rails-routes/`. Tier 1A of the Rails plugins roadmap. Statically
# interprets `config/routes.rb`'s DSL via Prism and validates every `*_path` / `*_url` call site against the
# resulting helper table.

require "spec_helper"

RAILS_ROUTES_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-rails-routes/lib", __dir__)
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

RSpec.describe "plugins/rigor-rails-routes" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::RailsRoutes }
  let(:default_run_plugin_cache_store) { :shared }

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

    it "generates `new_admin_widget_path` not `admin_new_widget_path` (prefix before new/edit)" do
      # Rails convention: new_ / edit_ prefix comes FIRST, then the namespace prefix. `namespace :admin {
      # resources :widgets }` → `new_admin_widget_path`, not `admin_new_widget_path`.
      result = run_plugin(
        source: "new_admin_widget_path\nedit_admin_widget_path(1)\n",
        files: { "config/routes.rb" => DEFAULT_ROUTES_RB }
      )
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "unknown-helper" }).to be_empty
      expect(diags.map(&:message).join).to include("new_admin_widget_path")
    end

    it "flags the wrong-order form `admin_new_widget_path` as unknown" do
      result = run_plugin(
        source: "admin_new_widget_path\n",
        files: { "config/routes.rb" => DEFAULT_ROUTES_RB }
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "unknown-helper" }
      expect(err).not_to be_nil
    end

    it "recognises an anonymous `get` route by path-derived name (`login_path`)" do
      # `get "/login", to: "sessions#new"` — no `as:` key; Rails derives the helper name from the path string.
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          get "/login", to: "sessions#new"
          get "/about/team", to: "static#team"
        end
      RUBY
      result = run_plugin(
        source: "login_path\nabout_team_path\n",
        files: { "config/routes.rb" => routes_rb }
      )
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "unknown-helper" }).to be_empty
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

    it "emits the load-error warning at most once across many analyzed files" do
      # Solidus / Mastodon scale: hundreds of files, but `routes.rb` absence is a single project-global root
      # cause. Pre-fix, the plugin emitted `load-error` per file (999× on Solidus).
      result = run_plugin(
        source: "users_path\n",
        files: { "extra1.rb" => "stuff\n", "extra2.rb" => "more\n", "extra3.rb" => "again\n" }
      )
      diags = plugin_diagnostics(result)
      load_errors = diags.select { |d| d.rule == "load-error" }
      expect(load_errors.size).to eq(1)
    end

    it "handles uncountable-noun resources (`resources :news`, _index_ on index helper)" do
      # `resources :news` with `singular == plural`: Rails generates `news_index_path` (collection / index,
      # arity 0) and `news_path(:id)` (show, arity 1). The `_index_` suffix on the index helper disambiguates
      # the two — it is added whenever `singular == plural`, INCLUDING for uncountable nouns. Redmine's
      # `app/controllers/news_controller.rb` calls `news_index_path` and `project_news_index_path(@project)`
      # for the index form; legitimate `news_path(@news)` calls the show.
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          resources :news, only: [:index, :show, :new, :edit]
        end
      RUBY
      result = run_plugin(
        source: "news_index_path\nnews_path(1)\nnew_news_path\nedit_news_path(1)\n",
        files: { "config/routes.rb" => routes_rb }
      )
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "wrong-arity" }).to be_empty
      expect(diags.select { |d| d.rule == "unknown-helper" }).to be_empty
    end

    it "still fires wrong-arity for an uncountable resource with too many args" do
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          resources :news, only: [:index, :show]
        end
      RUBY
      # news_path accepts 0 (index) or 1 (show), plus one trailing options hash. 3 args exceeds even the most
      # permissive interpretation.
      result = run_plugin(
        source: "news_path(1, 2, 3)\n",
        files: { "config/routes.rb" => routes_rb }
      )
      diags = plugin_diagnostics(result)
      expect(diags.find { |d| d.rule == "wrong-arity" }).not_to be_nil
    end

    it "registers the `as:` alias on root, both new and hash-rocket forms" do
      # Redmine uses `root :to => 'welcome#index', :as => 'home'` at line 26 of config/routes.rb — the
      # hash-rocket form is the legacy Ruby 1.8 idiom that still works in modern Rails. Pre-fix the parser
      # registered only `root_path`, so all 230 call sites to `home_path` / `home_url` across Redmine surfaced
      # as `unknown-helper`.
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          root :to => 'welcome#index', :as => 'home'
        end
      RUBY
      result = run_plugin(
        source: "home_path\nhome_url\nroot_path\nroot_url\n",
        files: { "config/routes.rb" => routes_rb }
      )
      diags = plugin_diagnostics(result)
      unknown = diags.select { |d| d.rule == "unknown-helper" }
      expect(unknown).to be_empty
    end

    it "accepts `only:` / `except:` as a single Symbol (not just Array)" do
      # Mastodon, Solidus and many other Rails apps use the shorthand `resources :foo, only: :show` (Symbol)
      # interchangeably with `only: [:show]` (Array). The parser must accept both — pre-fix, `Symbol#&` raised
      # `NoMethodError` and the entire routes file failed to parse, bubbling up as a load-error against every
      # analyzed file in the project.
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          resources :custom_css, only: :show
          resources :statuses,  except: :destroy
        end
      RUBY
      result = run_plugin(
        source: "custom_css_path\nstatuses_path\n",
        files: { "config/routes.rb" => routes_rb }
      )
      diags = plugin_diagnostics(result)
      expect(diags.find { |d| d.rule == "load-error" }).to be_nil
      # Both helpers should be recognised (info-level), proving the restrict_actions table built cleanly.
      helper_names = diags.map(&:message).join("\n")
      expect(helper_names).to include("custom_css_path")
      expect(helper_names).to include("statuses_path")
    end
  end

  describe "trailing options hash is not counted as a URL segment" do
    it "accepts users_path(page: 2) as arity 0 (hash is query params)" do
      result = run_plugin(
        source: "users_path(page: 2)\n",
        files: { "config/routes.rb" => DEFAULT_ROUTES_RB }
      )
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "wrong-arity" }).to be_empty
    end

    it "accepts user_path(1, 2) as valid (second arg can be options hash)" do
      # Rails: `user_path(@user, anchor: 'top')` is arity 1 + options. Since Rigor cannot tell an options hash
      # from a positional arg at the type level, it allows expected+1 args for every helper.
      result = run_plugin(
        source: "user_path(1, 2)\n",
        files: { "config/routes.rb" => DEFAULT_ROUTES_RB }
      )
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "wrong-arity" }).to be_empty
    end

    it "still catches a genuinely wrong arity (expected+2 args)" do
      # user_path expects 1 segment; user_path(1, 2, 3) has 3 args — even allowing one trailing options hash,
      # that is still one too many.
      result = run_plugin(
        source: "user_path(1, 2, 3)\n",
        files: { "config/routes.rb" => DEFAULT_ROUTES_RB }
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "wrong-arity" }
      expect(err).not_to be_nil
    end
  end

  describe "draw partials (config/routes/name.rb)" do
    let(:main_routes) do
      <<~RUBY
        Rails.application.routes.draw do
          root "home#index"
          draw(:admin)
          draw(:api)
        end
      RUBY
    end

    let(:admin_routes) do
      <<~RUBY
        namespace :admin do
          resources :users
          resources :reports, only: [:index, :show]
        end
      RUBY
    end

    let(:api_routes) do
      <<~RUBY
        namespace :api do
          namespace :v1 do
            resources :statuses, only: [:index, :show, :create]
          end
        end
      RUBY
    end

    it "includes helpers from drawn partials" do
      result = run_plugin(
        source: "admin_users_path\nnew_admin_user_path\n",
        files: {
          "config/routes.rb" => main_routes,
          "config/routes/admin.rb" => admin_routes,
          "config/routes/api.rb" => api_routes
        }
      )
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "unknown-helper" }).to be_empty
      expect(diags.map(&:message).join).to include("admin_users_path")
    end

    it "recognises helpers from both drawn partials" do
      result = run_plugin(
        source: "api_v1_statuses_path\n",
        files: {
          "config/routes.rb" => main_routes,
          "config/routes/admin.rb" => admin_routes,
          "config/routes/api.rb" => api_routes
        }
      )
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "unknown-helper" }).to be_empty
    end

    it "stays silent when a drawn partial is absent (no crash, no unknown-helper flood)" do
      result = run_plugin(
        source: "root_path\n",
        files: { "config/routes.rb" => main_routes }
        # config/routes/admin.rb and api.rb are intentionally absent
      )
      diags = plugin_diagnostics(result)
      expect(diags.find { |d| d.rule == "load-error" }).to be_nil
      expect(diags.select { |d| d.rule == "unknown-helper" }).to be_empty
    end
  end

  describe "scope routing" do
    it "generates prefixed helpers for `scope as:` blocks" do
      # `scope "/:event_slug", as: "event" do; resources :talks; end` is the conference-app kaigionrails
      # pattern. Without the fix the parser ignored the `as:` prefix and registered `talks_path` instead of
      # `event_talks_path`, producing unknown-helper FPs.
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          scope "/:event_slug", as: "event" do
            resources :talks, only: [:index, :show]
          end
        end
      RUBY
      result = run_plugin(
        source: "event_talks_path('slug')\nevent_talk_path('slug', 1)\n",
        files: { "config/routes.rb" => routes_rb }
      )
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "unknown-helper" }).to be_empty
    end

    it "does not register un-prefixed helpers for scope-body resources" do
      # Pre-fix the parser processed the scope block as a plain block, registering `talks_path` / `talk_path`
      # as if the resources were top-level — those helpers don't actually exist.
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          scope "/:event_slug", as: "event" do
            resources :talks, only: [:index, :show]
          end
        end
      RUBY
      result = run_plugin(
        source: "talks_path\n",
        files: { "config/routes.rb" => routes_rb }
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "unknown-helper" }
      expect(err).not_to be_nil
    end

    it "counts dynamic scope segments in helper arity" do
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          scope "/:event_slug", as: "event" do
            resources :talks, only: [:index]
          end
        end
      RUBY
      # event_talks_path requires 1 arg (the event_slug segment)
      result = run_plugin(
        source: "event_talks_path\n",
        files: { "config/routes.rb" => routes_rb }
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "wrong-arity" }
      expect(err).not_to be_nil
      expect(err.message).to include("event_talks_path")
    end

    it "exposes `_url` form for scope helpers" do
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          scope "/:event_slug", as: "event" do
            resources :talks, only: [:index]
          end
        end
      RUBY
      result = run_plugin(
        source: "event_talks_url('slug')\n",
        files: { "config/routes.rb" => routes_rb }
      )
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "unknown-helper" }).to be_empty
    end

    it "places new_/edit_ prefix before the scope name (`new_event_talk_path`)" do
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          scope "/:event_slug", as: "event" do
            resources :talks
          end
        end
      RUBY
      result = run_plugin(
        source: "new_event_talk_path('slug')\nedit_event_talk_path('slug', 1)\n",
        files: { "config/routes.rb" => routes_rb }
      )
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "unknown-helper" }).to be_empty
    end

    it "applies scope prefix to explicit `get` routes with `as:`" do
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          scope "/:event_slug", as: "event" do
            get "/live", to: "live_streams#index", as: "live_streams"
          end
        end
      RUBY
      result = run_plugin(
        source: "event_live_streams_path('slug')\n",
        files: { "config/routes.rb" => routes_rb }
      )
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "unknown-helper" }).to be_empty
    end

    it "skips `get '/'` inside a scope (would produce an empty path-derived name)" do
      # `get "/"` inside a scope derives as_name "" which, combined with a scope prefix, would produce a
      # `event__path` double-underscore entry. The parser now returns early on empty derived names.
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          scope "/:event_slug", as: "event" do
            get "/", to: "events#show"
          end
        end
      RUBY
      result = run_plugin(source: "x\n", files: { "config/routes.rb" => routes_rb })
      helper_names = plugin_diagnostics(result).map(&:message).join
      expect(helper_names).not_to include("__path")
    end
  end

  describe "only: with non-show actions still registers the path helper" do
    # Mastodon shape: `resource :inbox, only: [:create]` — Rails registers POST /inbox under the same
    # `inbox_path` helper Rails uses for show forms; the plugin must too, otherwise the caller's `inbox_path`
    # reads as unknown.
    it "registers the path helper for a singular resource with `only: [:create]`" do
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          resource :inbox, only: [:create]
        end
      RUBY
      result = run_plugin(source: "inbox_path\n", files: { "config/routes.rb" => routes_rb })
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end

    it "registers the show-shape path helper for plural resources with `except: [:show]`" do
      # Mastodon `resources :roles, except: [:show]` — Rails generates PATCH / PUT / DELETE under
      # `admin_role_path(id)` even though :show is excluded.
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          namespace :admin do
            resources :roles, except: [:show]
          end
        end
      RUBY
      result = run_plugin(source: "admin_role_path(@role)\n", files: { "config/routes.rb" => routes_rb })
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end

    it "registers the collection path helper for plural resources with `only: [:create]`" do
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          resources :widgets, only: [:create]
        end
      RUBY
      result = run_plugin(source: "widgets_path\n", files: { "config/routes.rb" => routes_rb })
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end
  end

  describe "singular resource with plural-looking name keeps the as-given name" do
    # Mastodon shape: `resource :relationships, only: [:show, :update]` — singular DSL with a plural-looking
    # name. Rails generates `relationships_path` (no singularising); the parser used to mangle this to
    # `relationship_path`.
    it "does not singularise a singular-resource's helper" do
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          resource :relationships, only: [:show, :update]
        end
      RUBY
      result = run_plugin(source: "relationships_path\n", files: { "config/routes.rb" => routes_rb })
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end

    it "still derives the singular form from a plural-resources declaration" do
      # Make sure the Bug B fix does not break the normal `resources :foos` → `foo_path(id)` derivation.
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          resources :widgets
        end
      RUBY
      result = run_plugin(source: "widget_path(1)\nwidgets_path\n", files: { "config/routes.rb" => routes_rb })
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end
  end

  describe "helper discovery walks the whole app/ tree by default" do
    let(:controller_with_private_helper) do
      <<~RUBY
        class FollowerAccountsController < ApplicationController
          private

          # Visibility-agnostic discovery (see HelperDiscoverer
          # docstring): this private method IS registered so
          # the paired view's `link_to "Next", page_url(2)`
          # does not false-fire `unknown-helper`.
          def page_url(page)
            page
          end
        end
      RUBY
    end

    let(:lib_helper) do
      <<~RUBY
        module TranslationService
          class DeepL
            def base_url
              "https://api.deepl.com"
            end
          end
        end
      RUBY
    end

    it "finds a `private _url` method declared in a controller" do
      # Mastodon's exact shape: `app/controllers/follower_accounts_controller.rb` has `private; def
      # page_url(page) ... end`.
      result = run_plugin(
        source: "page_url(1)\n",
        files: {
          "config/routes.rb" => DEFAULT_ROUTES_RB,
          "app/controllers/follower_accounts_controller.rb" => controller_with_private_helper
        }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end

    it "finds a `_url` method declared under `app/lib/`" do
      result = run_plugin(
        source: "base_url\n",
        files: {
          "config/routes.rb" => DEFAULT_ROUTES_RB,
          "app/lib/translation_service/deepl.rb" => lib_helper
        }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end
  end

  describe "custom helper discovery (app/helpers/)" do
    let(:helper_module) do
      <<~RUBY
        module RoutingHelper
          def full_asset_url(source)
            source
          end

          def host_to_url(host)
            host
          end

          private

          def internal_path(arg)
            arg
          end
        end
      RUBY
    end

    it "suppresses unknown-helper for a project-defined `_url` helper" do
      result = run_plugin(
        source: "full_asset_url('foo.png')\n",
        files: {
          "config/routes.rb" => DEFAULT_ROUTES_RB,
          "app/helpers/routing_helper.rb" => helper_module
        }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end

    it "still flags a misspelt helper that is neither in routes nor in app/helpers/" do
      # Name MUST end in `_path` / `_url` to reach the rule at all — pick a name not present in either source.
      result = run_plugin(
        source: "definitely_not_real_url('foo.png')\n",
        files: {
          "config/routes.rb" => DEFAULT_ROUTES_RB,
          "app/helpers/routing_helper.rb" => helper_module
        }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns.size).to eq(1)
      expect(unknowns.first.message).to include("definitely_not_real_url")
    end

    it "includes `_path` / `_url` methods marked private (visibility-agnostic by design)" do
      # Visibility-agnostic discovery: a `private def internal_path(arg)` IS registered so a paired view or
      # cross-controller call site does not false-fire `unknown-helper`. The core engine's
      # `call.undefined-method` rule still catches the case where the call's receiver genuinely cannot see the
      # method.
      result = run_plugin(
        source: "internal_path('x')\n",
        files: {
          "config/routes.rb" => DEFAULT_ROUTES_RB,
          "app/helpers/routing_helper.rb" => helper_module
        }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end

    it "ignores singleton-method `_url` definitions (def self.x)" do
      module_with_singleton = <<~RUBY
        module Helpers
          def self.class_side_url(s)
            s
          end
        end
      RUBY
      result = run_plugin(
        source: "class_side_url('x')\n",
        files: {
          "config/routes.rb" => DEFAULT_ROUTES_RB,
          "app/helpers/helpers.rb" => module_with_singleton
        }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns.size).to eq(1)
    end

    it "walks nested modules / classes for helper definitions" do
      nested = <<~RUBY
        module Outer
          module Inner
            def deeply_nested_url(s)
              s
            end
          end
        end
      RUBY
      result = run_plugin(
        source: "deeply_nested_url('x')\n",
        files: {
          "config/routes.rb" => DEFAULT_ROUTES_RB,
          "app/helpers/nested.rb" => nested
        }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end
  end

  describe "devise_for route generation" do
    let(:routes_with_devise) do
      <<~RUBY
        Rails.application.routes.draw do
          devise_for :users
        end
      RUBY
    end

    it "recognises the standard Devise session helper" do
      result = run_plugin(
        source: "new_user_session_path\n",
        files: { "config/routes.rb" => routes_with_devise }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end

    it "recognises every helper in the standard six-controller catalogue" do
      helpers = %w[
        new_user_session_path user_session_path destroy_user_session_path
        new_user_password_path edit_user_password_path user_password_path
        new_user_confirmation_path user_confirmation_path
        new_user_unlock_path user_unlock_path
        new_user_registration_path edit_user_registration_path
        user_registration_path cancel_user_registration_path
      ]
      result = run_plugin(
        source: "#{helpers.join("\n")}\n",
        files: { "config/routes.rb" => routes_with_devise }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end

    it "honours `skip:` to omit controllers the project disables" do
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          devise_for :users, skip: [:registrations]
        end
      RUBY
      result = run_plugin(
        source: "new_user_session_path\nnew_user_registration_path\n",
        files: { "config/routes.rb" => routes_rb }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns.size).to eq(1)
      expect(unknowns.first.message).to include("new_user_registration_path")
    end

    it "recognises dynamic OmniAuth helpers (`<resource>_<provider>_omniauth_*`)" do
      result = run_plugin(
        source: "user_facebook_omniauth_authorize_path\nuser_github_omniauth_callback_url\n",
        files: { "config/routes.rb" => routes_with_devise }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end

    it "does NOT recognise an OmniAuth-shaped helper for an undeclared resource" do
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          devise_for :users
        end
      RUBY
      result = run_plugin(
        source: "admin_facebook_omniauth_authorize_path\n",
        files: { "config/routes.rb" => routes_rb }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns.size).to eq(1)
    end
  end

  describe "with_options applies defaults to inner resources" do
    # Mastodon's `with_options only: [:index], concerns: :batch do resources :links; resources :tags; ... end`
    # — inner declarations inherit `only:` + `concerns:`.

    it "applies `only:` to a bare `resources :foo` inside the block" do
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          with_options only: [:index] do
            resources :links
            resources :tags
          end
        end
      RUBY
      result = run_plugin(
        source: "links_path\ntags_path\n",
        files: { "config/routes.rb" => routes_rb }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end

    it "applies `concerns:` defaults so concern bodies replay for inner resources" do
      # The Mastodon shape: `concern :batch do collection { post :batch }; end` + `with_options only: [:index],
      # concerns: :batch do resources :links; ... end` → `batch_links_path` registers.
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          namespace :admin do
            concern :batch do
              collection { post :batch }
            end

            namespace :trends do
              with_options only: [:index], concerns: :batch do
                resources :links
                resources :tags
                resources :statuses
              end
            end
          end
        end
      RUBY
      result = run_plugin(
        source: "batch_admin_trends_links_path\nbatch_admin_trends_tags_path\nbatch_admin_trends_statuses_path\n",
        files: { "config/routes.rb" => routes_rb }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end

    it "lets the inner call's own options override with_options defaults" do
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          with_options only: [:index] do
            resources :books, only: [:show, :index]
          end
        end
      RUBY
      result = run_plugin(
        source: "book_path(1)\nbooks_path\n",
        files: { "config/routes.rb" => routes_rb }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end
  end

  describe "extended singularize rules (sh / ch / x / z + es)" do
    it "singularises `async_refreshes` to `async_refresh`" do
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          resources :async_refreshes, only: :show
        end
      RUBY
      result = run_plugin(
        source: "async_refresh_path(1)\n",
        files: { "config/routes.rb" => routes_rb }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end

    it "singularises `boxes` to `box` (xes rule)" do
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          resources :boxes, only: :show
        end
      RUBY
      result = run_plugin(source: "box_path(1)\n", files: { "config/routes.rb" => routes_rb })
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end
  end

  describe "resources `as:` overrides the helper name root" do
    it "uses :as for the show helper when `only: [:show]`" do
      # `resources :collections, only: [:show], as: :actor_collections` — Rails' show helper becomes
      # `actor_collection_path(id)` (the URL stays `/collections/:id`).
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          resources :collections, only: [:show], as: :actor_collections
        end
      RUBY
      result = run_plugin(
        source: "actor_collection_path(1)\n",
        files: { "config/routes.rb" => routes_rb }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end

    it "uses :as for both index and show when all actions are present" do
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          resources :collections, as: :actor_collections
        end
      RUBY
      result = run_plugin(
        source: "actor_collections_path\nactor_collection_path(1)\n",
        files: { "config/routes.rb" => routes_rb }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end
  end

  describe "mounted engines register the `<as>_path` helper" do
    it "registers `sidekiq_path` for `mount Sidekiq::Web, at: 'sidekiq', as: :sidekiq`" do
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          mount Sidekiq::Web, at: 'sidekiq', as: :sidekiq
        end
      RUBY
      result = run_plugin(
        source: "sidekiq_path\nsidekiq_url\n",
        files: { "config/routes.rb" => routes_rb }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end

    it "silently skips a `mount` without `as:`" do
      # `mount LetterOpenerWeb::Engine, at: 'letter_opener'` — no `as:`, so we don't fabricate a helper name.
      # Include `resources :users` so the helper table isn't empty (the plugin silences all diagnostics on an
      # empty table to avoid noise on routes-less files).
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          resources :users
          mount LetterOpenerWeb::Engine, at: 'letter_opener'
        end
      RUBY
      result = run_plugin(
        source: "missing_mount_helper_path\n",
        files: { "config/routes.rb" => routes_rb }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns.size).to eq(1)
    end
  end

  describe "use_doorkeeper recognises the standard OAuth helpers" do
    let(:routes_with_doorkeeper) do
      <<~RUBY
        Rails.application.routes.draw do
          use_doorkeeper
        end
      RUBY
    end

    it "registers oauth_token_path / oauth_revoke_path / oauth_authorization_path" do
      result = run_plugin(
        source: "oauth_token_path\noauth_revoke_path\noauth_authorization_path\n",
        files: { "config/routes.rb" => routes_with_doorkeeper }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end

    it "registers oauth_application_path with arity 1" do
      result = run_plugin(
        source: "oauth_application_path(1)\noauth_applications_path\n",
        files: { "config/routes.rb" => routes_with_doorkeeper }
      )
      diags = plugin_diagnostics(result).select { |d| %w[unknown-helper wrong-arity].include?(d.rule) }
      expect(diags).to be_empty
    end

    it "honours `skip_controllers :name` inside the block" do
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          use_doorkeeper do
            skip_controllers :applications
          end
        end
      RUBY
      result = run_plugin(
        source: "oauth_application_path(1)\noauth_token_path\n",
        files: { "config/routes.rb" => routes_rb }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns.size).to eq(1)
      expect(unknowns.first.message).to include("oauth_application_path")
    end
  end

  describe "irregular singulars (Latin / Greek plurals)" do
    it "singularises `media` to `medium` for `resources :media`" do
      # Mastodon's `resources :media, only: [:show]` → `medium_path(id)` (arity 1). Pre-fix `media` was in
      # UNCOUNTABLE and the helper resolved as `media_path`.
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          resources :media, only: [:show]
        end
      RUBY
      result = run_plugin(
        source: "medium_path(id: 1)\n",
        files: { "config/routes.rb" => routes_rb }
      )
      diags = plugin_diagnostics(result).select { |d| %w[unknown-helper wrong-arity].include?(d.rule) }
      expect(diags).to be_empty
    end
  end

  describe "concern-injected route bodies" do
    # Mastodon shape: `concern :account_resources do ... end` then `resources :accounts, concerns:
    # :account_resources do ... end` injects the concern body inside the accounts resource block. Pre-fix the
    # parser silently skipped concern bodies (per v0.1.11's `:concern` no-op) — so every helper defined ONLY
    # inside a concern surfaced as `unknown-helper` at the call site.

    it "replays a single concern's body inside `concerns: :name`" do
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          concern :account_resources do
            resources :followers, only: [:index]
          end

          resources :accounts, concerns: :account_resources
        end
      RUBY
      result = run_plugin(
        source: "account_followers_path(1)\n",
        files: { "config/routes.rb" => routes_rb }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end

    it "supports an array of concerns" do
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          concern :followable do
            resources :followers, only: [:index]
          end
          concern :commentable do
            resources :comments, only: [:index]
          end

          resources :accounts, concerns: [:followable, :commentable]
        end
      RUBY
      result = run_plugin(
        source: "account_followers_path(1)\naccount_comments_path(1)\n",
        files: { "config/routes.rb" => routes_rb }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end

    it "replays the concern body with the resource's arity context" do
      # `resources :accounts do concern body { resource :inbox } end` → `account_inbox_path(account_id)`
      # arity 1 (the concern's resource picks up the outer `:account_id`).
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          concern :inbox_target do
            resource :inbox, only: [:create]
          end

          resources :accounts, concerns: :inbox_target
        end
      RUBY
      result = run_plugin(
        source: "account_inbox_path(1)\n",
        files: { "config/routes.rb" => routes_rb }
      )
      diags = plugin_diagnostics(result).select { |d| %w[unknown-helper wrong-arity].include?(d.rule) }
      expect(diags).to be_empty
    end

    it "still fires unknown-helper for a misspelt concern reference (precision floor)" do
      # Concern not declared → bodies aren't replayed → call to a helper that would have come from a missing
      # concern still surfaces as unknown-helper.
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          resources :accounts, concerns: :nonexistent
        end
      RUBY
      result = run_plugin(
        source: "account_imaginary_path(1)\n",
        files: { "config/routes.rb" => routes_rb }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns.size).to eq(1)
    end
  end

  describe "singular `resource` adds the name to helper prefix for nested declarations" do
    # Mastodon shape: `resource :instance, only: [:show] do scope module: :instances do resources
    # :domain_blocks only: [:index]; end; end` — generates `api_v1_instance_domain_blocks_path` (NOT
    # `api_v1_domain_blocks_path`).

    it "prefixes nested resources helpers with the singular resource's name" do
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          resource :instance, only: [:show] do
            resources :domain_blocks, only: [:index]
          end
        end
      RUBY
      result = run_plugin(
        source: "instance_domain_blocks_path\n",
        files: { "config/routes.rb" => routes_rb }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end

    it "works through a `scope module:` inside the singular resource block" do
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          namespace :api do
            namespace :v1 do
              resource :instance, only: [:show] do
                scope module: :instances do
                  resources :domain_blocks, only: [:index]
                end
              end
            end
          end
        end
      RUBY
      result = run_plugin(
        source: "api_v1_instance_domain_blocks_path\n",
        files: { "config/routes.rb" => routes_rb }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end

    it "does NOT contribute a `:id` arity segment for the singular parent" do
      # `resource :instance do resources :domain_blocks end` → index helper takes 0 args (instance has no :id,
      # domain_blocks index has no :id either). Precision floor against accidentally adding 1 to arity.
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          resource :instance, only: [:show] do
            resources :domain_blocks, only: [:index]
          end
        end
      RUBY
      result = run_plugin(
        source: "instance_domain_blocks_path\n",
        files: { "config/routes.rb" => routes_rb }
      )
      arity_diags = plugin_diagnostics(result).select { |d| d.rule == "wrong-arity" }
      expect(arity_diags).to be_empty
    end
  end

  describe "same-singular-plural names get the `_index_` suffix" do
    # Rails appends `_index_` to the index helper when the singular form equals the plural form AND the name
    # is not in the canonical UNCOUNTABLE list. The disambiguation exists because show/index would otherwise collide.

    it "registers `<name>_index_path` for `resources :reblogged_by`" do
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          resources :reblogged_by, controller: :reblogged_by_accounts, only: :index
        end
      RUBY
      result = run_plugin(
        source: "reblogged_by_index_path\n",
        files: { "config/routes.rb" => routes_rb }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end

    it "registers `terms_of_service_index_path` for `resources :terms_of_service`" do
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          namespace :admin do
            resources :terms_of_service, only: [:index]
          end
        end
      RUBY
      result = run_plugin(
        source: "admin_terms_of_service_index_path\n",
        files: { "config/routes.rb" => routes_rb }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end

    it "keeps UNCOUNTABLE-noun index under the bare name (no `_index_` suffix)" do
      # `resources :news` → `news_path` for both index AND show (Rails-compatible). Precision floor against
      # over-eager `_index_` suffixing.
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          resources :news
        end
      RUBY
      result = run_plugin(
        source: "news_path\nnews_path(1)\n",
        files: { "config/routes.rb" => routes_rb }
      )
      diags = plugin_diagnostics(result).select { |d| %w[unknown-helper wrong-arity].include?(d.rule) }
      expect(diags).to be_empty
    end
  end

  describe "member/collection block shorthand routes" do
    # Mastodon shape: `resources :accounts do; member { post :memorialize }; end` inside a namespace. Rails
    # generates `memorialize_admin_account_path(id)` (member) and `memorialize_admin_accounts_path`
    # (collection). Pre-fix the parser silently skipped these because `handle_explicit_route` rejected the
    # symbol-only call shape (`post :memorialize` with no path arg).

    it "registers a member action helper inside `resources do member { post :action } end`" do
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          namespace :admin do
            resources :accounts do
              member do
                post :memorialize
              end
            end
          end
        end
      RUBY
      result = run_plugin(
        source: "memorialize_admin_account_path(1)\n",
        files: { "config/routes.rb" => routes_rb }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end

    it "registers a collection action helper inside `resources do collection { post :action } end`" do
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          namespace :admin do
            resources :accounts do
              collection do
                post :batch
              end
            end
          end
        end
      RUBY
      result = run_plugin(
        source: "batch_admin_accounts_path\n",
        files: { "config/routes.rb" => routes_rb }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end

    it "registers multiple member actions in the same `member do` block" do
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          resources :accounts do
            member do
              post :enable
              post :memorialize
              post :reject
            end
          end
        end
      RUBY
      result = run_plugin(
        source: "enable_account_path(1)\nmemorialize_account_path(1)\nreject_account_path(1)\n",
        files: { "config/routes.rb" => routes_rb }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end

    it "applies the correct arity to member actions (parent resource segments only)" do
      # `resources :users do; resources :accounts do; member { post :memorialize }; end; end` →
      # `memorialize_user_account_path(user_id, id)` arity 2.
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          resources :users do
            resources :accounts do
              member do
                post :memorialize
              end
            end
          end
        end
      RUBY
      result = run_plugin(
        source: "memorialize_user_account_path(1, 2)\n",
        files: { "config/routes.rb" => routes_rb }
      )
      diags = plugin_diagnostics(result).select { |d| %w[unknown-helper wrong-arity].include?(d.rule) }
      expect(diags).to be_empty
    end

    it "names a multi-segment string collection action via `normalize_name` (slashes → underscores)" do
      # GitLab shape (`config/routes/user_settings.rb`): a multi-segment static string path inside a
      # `collection do` block. Rails' `Mapper.normalize_name` turns `granular/new` into `granular_new`, and
      # the `:collection` action-name ordering is `[prefix, name_prefix, collection_name]` →
      # `granular_new_user_settings_personal_access_tokens_path`. Pre-fix the parser fell through to the
      # generic explicit-route handler, producing the wrong singular / mis-ordered name and firing a false
      # `unknown-helper`.
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          namespace :user_settings do
            resources :personal_access_tokens do
              collection do
                get 'granular/new'
                get 'legacy/new'
              end
            end
          end
        end
      RUBY
      result = run_plugin(
        source: "granular_new_user_settings_personal_access_tokens_path\n" \
                "legacy_new_user_settings_personal_access_tokens_path\n",
        files: { "config/routes.rb" => routes_rb }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end

    it "does not turn a bare `get '/'` collection root into an empty-named action helper" do
      # GitLab shape (`config/routes/organizations.rb`): `collection { get '/', action: :index }`. The `'/'`
      # is the collection root, NOT an action shorthand — it must not register a malformed
      # `_organizations_path` (empty action name + plural prefix), which would both mask the site and pollute
      # did-you-mean suggestions. Rails names this after the resource; the plugin's generic handler keeps its
      # prior name. The guard: no route helper name may begin with an underscore.
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          resources :organizations, only: [:new] do
            collection do
              get '/', action: :index
            end
          end
        end
      RUBY
      result = run_plugin(
        # `organization_path` is what the generic handler names this collection-root route (the plugin's
        # prior behaviour) — it must stay recognised, and the malformed `_organizations_path` must never be
        # registered (so calling it reads as unknown, not a silent hit).
        source: "organization_path\n_organizations_path\n",
        files: { "config/routes.rb" => routes_rb }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      unknown_names = unknowns.map { |d| d.message[/no route helper `([^`]+)`/, 1] }
      # The old, recognised name still resolves; only the (never-registered) malformed name is unknown.
      expect(unknown_names).to include("_organizations_path")
      expect(unknown_names).not_to include("organization_path")
      # No did-you-mean suggestion offers an underscore-leading name (the malformed entry is gone).
      suggestions = plugin_diagnostics(result).map(&:message).join.scan(/did you mean `([^`]+)`/).flatten
      expect(suggestions).to all(satisfy { |s| !s.start_with?("_") })
    end
  end

  describe "bare symbol routes inside a named scope" do
    it "composes `<scope_as>_<action>_path` for `get :activity` in `scope(as: :user)`" do
      # GitLab shape (`config/routes/user.rb`): `scope(path: 'users/:username', as: :user) do get :activity
      # end`. Rails uses the symbol as both the `/activity` path segment and the action name, composing
      # `user_activity_path(username)` (arity 1 from the `:username` scope segment). Pre-fix the parser saw
      # a symbol first-arg with no `:as` outside any resource / member / collection block and registered
      # nothing, so `user_activity_path` read as `unknown-helper`.
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          scope(path: 'users/:username', as: :user) do
            get :activity
            get :calendar
          end
        end
      RUBY
      result = run_plugin(
        source: "user_activity_path(1)\nuser_calendar_path(1)\n",
        files: { "config/routes.rb" => routes_rb }
      )
      diags = plugin_diagnostics(result).select { |d| %w[unknown-helper wrong-arity].include?(d.rule) }
      expect(diags).to be_empty
    end

    it "composes `<action>_path` for a top-level `get :status`" do
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          get :status
        end
      RUBY
      result = run_plugin(
        source: "status_path\n",
        files: { "config/routes.rb" => routes_rb }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end
  end

  describe "shadowing locals suppress diagnostics" do
    # When a file declares a local that shadows a route helper name (`let(:foo_url)`, `def foo_path`, `foo_url
    # = ...`), the analyzer MUST treat the call as the local, not the registered helper. Mastodon's `spec/` has
    # 200+ such patterns that pre-fix surfaced as bogus `unknown-helper` / `wrong-arity` against route helpers
    # that happen to share the name.

    it "skips unknown-helper for a `let(:foo_url)`-shadowed call" do
      result = run_plugin(
        source: <<~RUBY,
          RSpec.describe "x" do
            let(:collection_url) { 'https://example.com/x' }
            it { collection_url }
          end
        RUBY
        files: { "config/routes.rb" => DEFAULT_ROUTES_RB }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns).to be_empty
    end

    it "skips wrong-arity for a `let(:helper_path)` that shadows a known route helper" do
      # `resources :users` registers `user_path(id)` with arity 1; a `let(:user_path) { ... }` followed by
      # `user_path` (no args) used to fire `wrong-arity`.
      result = run_plugin(
        source: <<~RUBY,
          RSpec.describe "x" do
            let(:user_path) { 'https://example.com/users/1' }
            it { user_path }
          end
        RUBY
        files: { "config/routes.rb" => DEFAULT_ROUTES_RB }
      )
      diags = plugin_diagnostics(result).select { |d| %w[unknown-helper wrong-arity].include?(d.rule) }
      expect(diags).to be_empty
    end

    it "skips diagnostics for `subject(:foo_url)` declarations" do
      result = run_plugin(
        source: <<~RUBY,
          RSpec.describe "x" do
            subject(:fancy_path) { 'x' }
            it { fancy_path }
          end
        RUBY
        files: { "config/routes.rb" => DEFAULT_ROUTES_RB }
      )
      expect(plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }).to be_empty
    end

    it "skips diagnostics for `def foo_url` (a method shadowing the helper)" do
      result = run_plugin(
        source: <<~RUBY,
          class Helper
            def something_url
              "x"
            end

            def caller_method
              something_url
            end
          end
        RUBY
        files: { "config/routes.rb" => DEFAULT_ROUTES_RB }
      )
      expect(plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }).to be_empty
    end

    it "still fires unknown-helper for a non-shadowed unknown name" do
      # Precision floor — make sure the shadow check doesn't silently swallow real typos.
      result = run_plugin(
        source: "definitely_not_a_real_path\n",
        files: { "config/routes.rb" => DEFAULT_ROUTES_RB }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns.size).to eq(1)
    end
  end

  describe "arity check accepts kwargs-only call shapes" do
    # Mastodon shape: a multi-segment route called via keyword args carrying every segment name —
    # `short_account_status_url(account_username: u, id: i)` for `/@:account_username/:id`. Rails accepts this
    # form; our strict positional-arity check used to false-fire.

    let(:routes_with_kwargs_helper) do
      <<~RUBY
        Rails.application.routes.draw do
          get '/@:account_username/:id', to: 'statuses#show', as: :short_account_status
        end
      RUBY
    end

    it "does NOT fire wrong-arity on a call that supplies all segments via kwargs" do
      result = run_plugin(
        source: "short_account_status_url(account_username: 'alice', id: 1)\n",
        files: { "config/routes.rb" => routes_with_kwargs_helper }
      )
      diags = plugin_diagnostics(result).select { |d| d.rule == "wrong-arity" }
      expect(diags).to be_empty
    end

    it "does NOT fire wrong-arity on a call mixing positional + trailing kwargs" do
      result = run_plugin(
        source: "short_account_status_url('alice', id: 1)\n",
        files: { "config/routes.rb" => routes_with_kwargs_helper }
      )
      diags = plugin_diagnostics(result).select { |d| d.rule == "wrong-arity" }
      expect(diags).to be_empty
    end

    it "still fires wrong-arity when actual positional exceeds expected even with kwargs" do
      # Precision floor: 3 positionals (over expected 2) plus trailing kwargs is still wrong.
      result = run_plugin(
        source: "short_account_status_url('a', 'b', 'c', id: 1)\n",
        files: { "config/routes.rb" => routes_with_kwargs_helper }
      )
      diags = plugin_diagnostics(result).select { |d| d.rule == "wrong-arity" }
      expect(diags).not_to be_empty
    end
  end

  # `grape-path-helpers` names each helper after its route's path segments, which grape builds at runtime.
  # Only the leading `prefix` / `version` segments are static, so the namespace beyond them is open.
  describe "grape-path-helpers open namespace" do
    let(:grape_files) do
      {
        "config/routes.rb" => DEFAULT_ROUTES_RB,
        "lib/api/base.rb" => <<~RUBY,
          module API
            class Base < Grape::API::Instance
            end
          end
        RUBY
        "lib/api/api.rb" => <<~RUBY
          module API
            class API < ::API::Base
              prefix :api

              version 'v3', using: :path do
              end

              version 'v4', using: :path
            end
          end
        RUBY
      }
    end

    def grape_unknown_helper_diagnostics(source, files)
      result = run_plugin(source: source, files: files)
      plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
    end

    it "recognises a generated `_path` helper under a declared prefix and version" do
      diags = grape_unknown_helper_diagnostics("api_v4_groups_badges_path\n", grape_files)
      expect(diags).to be_empty
    end

    it "recognises every declared version, and the namespace root" do
      diags = grape_unknown_helper_diagnostics("api_v3_projects_path\napi_v4_path\n", grape_files)
      expect(diags).to be_empty
    end

    # The gem's `method_missing` returns `super` unless the name ends with `_path`, so it defines no `_url`
    # helper and an `api_v4_*_url` call is a genuine unknown helper.
    it "still fires on the `_url` form, which the gem never defines" do
      diags = grape_unknown_helper_diagnostics("api_v4_groups_badges_url\n", grape_files)
      expect(diags.map(&:message)).to include(a_string_including("api_v4_groups_badges_url"))
    end

    it "still fires on a name outside every declared prefix" do
      diags = grape_unknown_helper_diagnostics("api_v9_groups_path\n", grape_files)
      expect(diags.map(&:message)).to include(a_string_including("api_v9_groups_path"))
    end

    # A class that never reaches `Grape::API` declares no namespace, however grape-shaped its body looks.
    it "ignores `prefix` / `version` calls in a non-grape class" do
      files = grape_files.merge(
        "lib/api/base.rb" => "module API\n  class Base\n  end\nend\n"
      )
      diags = grape_unknown_helper_diagnostics("api_v4_groups_badges_path\n", files)
      expect(diags.map(&:message)).to include(a_string_including("api_v4_groups_badges_path"))
    end

    # `using: :header` keeps the version out of the URL, so it contributes no helper-name segment and the
    # open namespace widens to the bare prefix. `api_v4_groups_path` stays recognised under it — a route
    # could be declared `namespace :v4`, and nothing in the source distinguishes that from a typo.
    it "widens the namespace to the bare prefix when the version strategy is not `:path`" do
      files = grape_files.merge(
        "lib/api/api.rb" => <<~RUBY
          module API
            class API < ::API::Base
              prefix :api
              version 'v4', using: :header
            end
          end
        RUBY
      )
      expect(grape_unknown_helper_diagnostics("api_groups_path\n", files)).to be_empty
      expect(grape_unknown_helper_diagnostics("api_v4_groups_path\n", files)).to be_empty
      diags = grape_unknown_helper_diagnostics("apiary_groups_path\n", files)
      expect(diags.map(&:message)).to include(a_string_including("apiary_groups_path"))
    end
  end

  describe "ADR-9 cross-plugin fact publication" do
    it "publishes the `:helper_table` fact during prepare" do
      # FactStore is constructed once per Services / per run; capture it as the runner builds Services so we
      # can read the fact back after `prepare` has fired.
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
