# frozen_string_literal: true

# Integration spec for `plugins/rigor-rails-routes/`.
# Tier 1A of the Rails plugins roadmap. Statically interprets
# `config/routes.rb`'s DSL via Prism and validates every
# `*_path` / `*_url` call site against the resulting helper
# table.

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
      # Rails convention: new_ / edit_ prefix comes FIRST, then the namespace prefix.
      # `namespace :admin { resources :widgets }` → `new_admin_widget_path`,
      # not `admin_new_widget_path`.
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
      # `get "/login", to: "sessions#new"` — no `as:` key; Rails derives
      # the helper name from the path string.
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
      # Solidus / Mastodon scale: hundreds of files, but `routes.rb`
      # absence is a single project-global root cause. Pre-fix, the
      # plugin emitted `load-error` per file (999× on Solidus).
      result = run_plugin(
        source: "users_path\n",
        files: { "extra1.rb" => "stuff\n", "extra2.rb" => "more\n", "extra3.rb" => "again\n" }
      )
      diags = plugin_diagnostics(result)
      load_errors = diags.select { |d| d.rule == "load-error" }
      expect(load_errors.size).to eq(1)
    end

    it "handles uncountable-noun resources (`resources :news`, index + show share `news_path`)" do
      # Redmine's `config/routes.rb` declares `resources :news`
      # with the full action set. ActiveSupport's inflector
      # knows `news` is uncountable, so both the index helper
      # AND the show helper are named `news_path` — index takes
      # 0 args, show takes 1. Pre-fix the parser stripped the
      # 's', registering `news_path` (index, arity 0) +
      # `new_path` (show, arity 1) + `new_news_path` (new) —
      # so legitimate `news_path(@news)` calls (81× across
      # Redmine) surfaced as wrong-arity.
      routes_rb = <<~RUBY
        Rails.application.routes.draw do
          resources :news, only: [:index, :show, :new, :edit]
        end
      RUBY
      result = run_plugin(
        source: "news_path\nnews_path(1)\nnew_news_path\nedit_news_path(1)\n",
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
      # news_path accepts 0 (index) or 1 (show), plus one trailing options hash.
      # 3 args exceeds even the most permissive interpretation.
      result = run_plugin(
        source: "news_path(1, 2, 3)\n",
        files: { "config/routes.rb" => routes_rb }
      )
      diags = plugin_diagnostics(result)
      expect(diags.find { |d| d.rule == "wrong-arity" }).not_to be_nil
    end

    it "registers the `as:` alias on root, both new and hash-rocket forms" do
      # Redmine uses `root :to => 'welcome#index', :as => 'home'`
      # at line 26 of config/routes.rb — the hash-rocket form is
      # the legacy Ruby 1.8 idiom that still works in modern
      # Rails. Pre-fix the parser registered only `root_path`,
      # so all 230 call sites to `home_path` / `home_url` across
      # Redmine surfaced as `unknown-helper`.
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
      # Mastodon, Solidus and many other Rails apps use the shorthand
      # `resources :foo, only: :show` (Symbol) interchangeably with
      # `only: [:show]` (Array). The parser must accept both — pre-fix,
      # `Symbol#&` raised `NoMethodError` and the entire routes file
      # failed to parse, bubbling up as a load-error against every
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
      # Both helpers should be recognised (info-level), proving the
      # restrict_actions table built cleanly.
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
      # Rails: `user_path(@user, anchor: 'top')` is arity 1 + options.
      # Since Rigor cannot tell an options hash from a positional arg at
      # the type level, it allows expected+1 args for every helper.
      result = run_plugin(
        source: "user_path(1, 2)\n",
        files: { "config/routes.rb" => DEFAULT_ROUTES_RB }
      )
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "wrong-arity" }).to be_empty
    end

    it "still catches a genuinely wrong arity (expected+2 args)" do
      # user_path expects 1 segment; user_path(1, 2, 3) has 3 args —
      # even allowing one trailing options hash, that is still one too many.
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
      # `scope "/:event_slug", as: "event" do; resources :talks; end`
      # is the conference-app kaigionrails pattern. Without the fix
      # the parser ignored the `as:` prefix and registered `talks_path`
      # instead of `event_talks_path`, producing unknown-helper FPs.
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
      # Pre-fix the parser processed the scope block as a plain block,
      # registering `talks_path` / `talk_path` as if the resources were
      # top-level — those helpers don't actually exist.
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
      # `get "/"` inside a scope derives as_name "" which, combined with
      # a scope prefix, would produce a `event__path` double-underscore entry.
      # The parser now returns early on empty derived names.
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
    # Mastodon shape: `resource :inbox, only: [:create]` —
    # Rails registers POST /inbox under the same `inbox_path`
    # helper Rails uses for show forms; the plugin must too,
    # otherwise the caller's `inbox_path` reads as unknown.
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
      # Mastodon `resources :roles, except: [:show]` — Rails
      # generates PATCH / PUT / DELETE under `admin_role_path(id)`
      # even though :show is excluded.
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
    # Mastodon shape: `resource :relationships, only: [:show, :update]`
    # — singular DSL with a plural-looking name. Rails generates
    # `relationships_path` (no singularising); the parser used
    # to mangle this to `relationship_path`.
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
      # Make sure the Bug B fix does not break the normal
      # `resources :foos` → `foo_path(id)` derivation.
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
      # Mastodon's exact shape:
      # `app/controllers/follower_accounts_controller.rb` has
      # `private; def page_url(page) ... end`.
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
      # Name MUST end in `_path` / `_url` to reach the rule
      # at all — pick a name not present in either source.
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
      # Visibility-agnostic discovery: a `private def
      # internal_path(arg)` IS registered so a paired view or
      # cross-controller call site does not false-fire
      # `unknown-helper`. The core engine's
      # `call.undefined-method` rule still catches the case
      # where the call's receiver genuinely cannot see the
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

  describe "shadowing locals suppress diagnostics" do
    # When a file declares a local that shadows a route helper
    # name (`let(:foo_url)`, `def foo_path`, `foo_url = ...`),
    # the analyzer MUST treat the call as the local, not the
    # registered helper. Mastodon's `spec/` has 200+ such
    # patterns that pre-fix surfaced as bogus `unknown-helper`
    # / `wrong-arity` against route helpers that happen to
    # share the name.

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
      # `resources :users` registers `user_path(id)` with
      # arity 1; a `let(:user_path) { ... }` followed by
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
      # Precision floor — make sure the shadow check doesn't
      # silently swallow real typos.
      result = run_plugin(
        source: "definitely_not_a_real_path\n",
        files: { "config/routes.rb" => DEFAULT_ROUTES_RB }
      )
      unknowns = plugin_diagnostics(result).select { |d| d.rule == "unknown-helper" }
      expect(unknowns.size).to eq(1)
    end
  end

  describe "arity check accepts kwargs-only call shapes" do
    # Mastodon shape: a multi-segment route called via
    # keyword args carrying every segment name —
    # `short_account_status_url(account_username: u, id: i)`
    # for `/@:account_username/:id`. Rails accepts this form;
    # our strict positional-arity check used to false-fire.

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
      # Precision floor: 3 positionals (over expected 2) plus
      # trailing kwargs is still wrong.
      result = run_plugin(
        source: "short_account_status_url('a', 'b', 'c', id: 1)\n",
        files: { "config/routes.rb" => routes_with_kwargs_helper }
      )
      diags = plugin_diagnostics(result).select { |d| d.rule == "wrong-arity" }
      expect(diags).not_to be_empty
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
