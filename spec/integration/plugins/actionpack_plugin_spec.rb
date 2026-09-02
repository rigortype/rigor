# frozen_string_literal: true

# Integration spec for `plugins/rigor-actionpack/` (Phase 4 — route-helper consumption). Tests the cross-plugin
# integration end to end: rigor-rails-routes parses `config/routes.rb` and publishes the helper table; the
# loader's ADR-9 topo sort runs `prepare` first; then rigor-actionpack reads the published helper table and
# validates `*_path` / `*_url` calls inside controller files.

require "spec_helper"
require "fileutils"
require "tmpdir"

RAILS_ROUTES_LIB = File.expand_path("../../../plugins/rigor-rails-routes/lib", __dir__)
ACTIONPACK_LIB = File.expand_path("../../../plugins/rigor-actionpack/lib", __dir__)
ACTIVERECORD_LIB = File.expand_path("../../../plugins/rigor-activerecord/lib", __dir__)
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

RSpec.describe "plugins/rigor-actionpack" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  def with_demo(controller_source, routes: DEFAULT_AP_ROUTES_RB)
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
            case File.basename(name, ".rb")
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

  describe "request-context reader typing (Phase 5 — typing-obstacle O3)" do
    it "types the implicit-self `params` reader as ActionController::Parameters" do
      source = "class C\n  def create\n    Rigor.dump_type(params)\n  end\nend\n"
      with_demo(source) do |result|
        dump = result.diagnostics.find { |d| d.rule == "dump.type" }
        expect(dump).not_to be_nil
        expect(dump.message).to include("ActionController::Parameters")
      end
    end

    it "types `session` and `request` as their ActionDispatch classes" do
      source = "class C\n  def create\n    Rigor.dump_type(session)\n    Rigor.dump_type(request)\n  end\nend\n"
      with_demo(source) do |result|
        dumps = result.diagnostics.select { |d| d.rule == "dump.type" }.map(&:message)
        expect(dumps).to include(a_string_including("ActionDispatch::Request::Session"))
        expect(dumps).to include(a_string_including("ActionDispatch::Request"))
      end
    end

    it "types `flash` and `cookies` as their ActionDispatch classes" do
      source = "class C\n  def create\n    Rigor.dump_type(flash)\n    Rigor.dump_type(cookies)\n  end\nend\n"
      with_demo(source) do |result|
        dumps = result.diagnostics.select { |d| d.rule == "dump.type" }.map(&:message)
        expect(dumps).to include(a_string_including("ActionDispatch::Flash::FlashHash"))
        expect(dumps).to include(a_string_including("ActionDispatch::Cookies::CookieJar"))
      end
    end

    it "keeps session/request surfaces FP-safe (no undefined-method on delete/xhr?/headers)" do
      source = <<~RUBY
        class C
          def create
            session[:x] = 1
            session.delete(:y)
            request.xhr?
            request.headers["X"]
          end
        end
      RUBY
      with_demo(source) do |result|
        undefined = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
        expect(undefined).to be_empty
      end
    end

    it "keeps the Parameters surface FP-safe (no undefined-method on require/permit/to_unsafe_h)" do
      source = "class C\n  def create\n    params.require(:user).permit(:name)\n    params.to_unsafe_h\n  end\nend\n"
      with_demo(source) do |result|
        undefined = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
        expect(undefined).to be_empty
      end
    end

    it "does not type an explicit-receiver `params` call (implicit-self only)" do
      source = "class C\n  def create\n    Rigor.dump_type(config.params)\n  end\nend\n"
      with_demo(source) do |result|
        dump = result.diagnostics.find { |d| d.rule == "dump.type" }
        expect(dump).not_to be_nil
        expect(dump.message).not_to include("ActionController::Parameters")
      end
    end

    it "keeps `require` / `permit` chained off `params` typed as Parameters (Phase 5b)" do
      # Pre-fix `params.require(:user)` returned Dynamic (Parameters ships no RBS), leaking the chained
      # `.permit` and every downstream site to unprotected. The chain now stays a concrete Parameters
      # receiver end-to-end.
      source = <<~RUBY
        class C
          def create
            Rigor.dump_type(params.require(:user))
            Rigor.dump_type(params.require(:user).permit(:name))
            Rigor.dump_type(params.permit(:q))
          end
        end
      RUBY
      with_demo(source) do |result|
        dumps = result.diagnostics.select { |d| d.rule == "dump.type" }.map(&:message)
        expect(dumps.size).to eq(3)
        expect(dumps).to all(include("ActionController::Parameters"))
      end
    end

    it "keeps `expect` / `slice` chained off `params` typed as Parameters (#534)" do
      # Both share `require`'s safety shape: they never return nil, so the non-nil lenient nominal
      # cannot fold a flow rule wrong. `[]` is deliberately absent — see the control below.
      source = <<~RUBY
        class C
          def create
            Rigor.dump_type(params.expect(user: [:name]))
            Rigor.dump_type(params.slice(:q, :page))
            Rigor.dump_type(params.expect(user: [:name]).slice(:name))
          end
        end
      RUBY
      with_demo(source) do |result|
        dumps = result.diagnostics.select { |d| d.rule == "dump.type" }.map(&:message)
        expect(dumps.size).to eq(3)
        expect(dumps).to all(include("ActionController::Parameters"))
      end
    end

    it "leaves `params[:key]` untyped — it returns nil at runtime, and a non-nil nominal folds flow rules (#534)" do
      # Measured before withdrawal: typing `[]` as the non-nil Parameters folded `url.nil?` /
      # `if params[:r]` conditions constant on five working redmine/mastodon controllers.
      source = <<~RUBY
        class C
          def create
            url = params[:back_url]
            if url.nil?
              Rigor.dump_type(url)
            end
          end
        end
      RUBY
      with_demo(source) do |result|
        folds = result.diagnostics.select { |d| d.rule == "flow.always-truthy-condition" }
        expect(folds).to be_empty
      end
    end

    it "types every never-nil Parameters chain link, and keeps the chain through them (#534)" do
      # The admission rule for `STRONG_PARAMS_CHAIN_METHODS`: the Rails implementation must return a
      # Parameters on EVERY path. Contracts read off rails v8.1.0.beta1's strong_parameters.rb.
      links = [
        "params.except(:page)", "params.without(:page)", "params.extract!(:a)", "params.slice!(:a)",
        "params.merge(x: 1)", "params.merge!(x: 1)", "params.reverse_merge(x: 1)",
        "params.reverse_merge!(x: 1)", "params.with_defaults(x: 1)", "params.with_defaults!(x: 1)",
        "params.compact", "params.compact_blank", "params.deep_dup"
      ]
      chains = [
        "params.except(:page).permit(:name)",
        "params.merge(x: 1).require(:user).permit(:name)",
        "params.deep_dup.slice(:a).except(:b)"
      ]
      body = (links + chains).map { |expr| "    Rigor.dump_type(#{expr})" }.join("\n")
      with_demo("class C\n  def create\n#{body}\n  end\nend\n") do |result|
        dumps = result.diagnostics.select { |d| d.rule == "dump.type" }.map(&:message)
        expect(dumps.size).to eq(links.size + chains.size)
        expect(dumps).to all(include("ActionController::Parameters"))
      end
    end

    it "keeps the Parameters-shaped-but-not-Parameters methods OUT of the table (#534)" do
      # The paired negative for the spec above. Each of these looks like a chain link and is not:
      # `compact!` returns nil when nothing changed; `select` without a block returns an Enumerator;
      # `dig` returns a leaf value or nil; `to_h` returns a HashWithIndifferentAccess. Admitting any of
      # them would put a wrong precise type on a value the flow rules then act on.
      source = <<~RUBY
        class C
          def create
            Rigor.dump_type(params.compact!)
            Rigor.dump_type(params.select { |_k, v| v })
            Rigor.dump_type(params.dig(:a, :b))
            Rigor.dump_type(params.to_h)
          end
        end
      RUBY
      with_demo(source) do |result|
        dumps = result.diagnostics.select { |d| d.rule == "dump.type" }.map(&:message)
        expect(dumps.size).to eq(4)
        dumps.each { |d| expect(d).not_to include("ActionController::Parameters") }
      end
    end

    it "does not hijack the same method names on Hash / Array / Kernel receivers (#534)" do
      # `merge` / `slice` / `except` / `compact` are hot core method names. The rule is receiver-gated
      # on the Parameters nominal, so the core answers must survive intact — this is the regression the
      # widened table could plausibly cause.
      source = <<~RUBY
        class C
          def create
            Rigor.dump_type({ a: 1 }.merge(b: 2))
            Rigor.dump_type([1, 2].slice(0))
            Rigor.dump_type(require("set"))
          end
        end
      RUBY
      with_demo(source) do |result|
        dumps = result.diagnostics.select { |d| d.rule == "dump.type" }.map(&:message)
        expect(dumps.size).to eq(3)
        dumps.each { |d| expect(d).not_to include("ActionController::Parameters") }
        expect(dumps[0]).to include("a: 1").and include("b: 2")
        expect(dumps[1]).to include("1")
      end
    end

    it "keeps the widened Parameters surface FP-safe (no undefined-method on the new links)" do
      source = <<~RUBY
        class C
          def create
            params.except(:page).each { |k, v| [k, v] }
            params.merge(x: 1).to_unsafe_h
            params.deep_dup.whatever_rails_adds
          end
        end
      RUBY
      with_demo(source) do |result|
        undefined = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
        expect(undefined).to be_empty
      end
    end

    # --- `Parameters#[]` adjudication controls (#534 item 1) -------------------------------------
    #
    # `#[]` is the largest pair on both survey apps and stays untyped anyway. The two specs below pin
    # the exact probe shapes that rejected each candidate typing, so a future attempt has to break a
    # named assertion rather than rediscover the hazard. They are paired with the must-fire control
    # below, so neither can pass because the rules are off or the fixture went unanalysed.
    it "keeps a `params[:key]` condition unfolded — the `[] -> Parameters` hazard (#534)" do
      # Both assertions discriminate: they pass on the shipped answer (`[]` -> Dynamic) and fail under
      # `#[] -> Parameters`, which is what makes them a pin rather than a decoration.
      #
      # 1. A non-nil nominal makes `params[:full]` always-truthy, so the ternary folds to its true arm,
      #    `mode` types `:full` instead of `:full | :short`, and `mode == :short` — live code — draws
      #    `flow.always-truthy-condition` ("condition is always falsey").
      # 2. The same fold proves the `if url.nil?` arm unreachable, so its body types `bot`.
      source = <<~RUBY
        class C
          def create
            mode = params[:full] ? :full : :short
            return "s" if mode == :short

            url = params[:back_url]
            if url.nil?
              Rigor.dump_type(url)
            end
            "f"
          end
        end
      RUBY
      with_demo(source) do |result|
        folds = result.diagnostics.select { |d| d.rule == "flow.always-truthy-condition" }
        expect(folds).to be_empty
        dump = result.diagnostics.find { |d| d.rule == "dump.type" }
        expect(dump).not_to be_nil
        expect(dump.message).not_to include("bot")
      end
    end

    it "draws no possible-nil-receiver on an assigned `params[:key]` — the `[] -> Parameters?` hazard (#534)" do
      # `#[] -> Parameters | nil` fixes every fold above and still carries the chain, but
      # `call.possible-nil-receiver` fires on `Prism::LocalVariableReadNode` receivers
      # (`CheckRules#nil_receiver_diagnostic`'s local-read restriction) — i.e. exactly the
      # `q = params[:q]; q.strip` shape Rails controllers use constantly — at error severity, once
      # per unguarded use.
      source = <<~RUBY
        class C
          def create
            q = params[:q]
            q.strip
            attrs = params[:user]
            attrs.permit(:name)
          end
        end
      RUBY
      with_demo(source) do |result|
        nil_receivers = result.diagnostics.select { |d| d.rule == "call.possible-nil-receiver" }
        expect(nil_receivers).to be_empty
      end
    end

    it "CONTROL: the harness fires undefined-method and possible-nil-receiver in this fixture shape" do
      # The must-fire sibling for the three `#[]` controls above.
      source = <<~RUBY
        class C
          def create
            "a string".no_such_method_on_string
            s = ["a", nil].sample
            s.upcase
          end
        end
      RUBY
      with_demo(source) do |result|
        rules = result.diagnostics.map(&:rule)
        expect(rules).to include("call.undefined-method")
        expect(rules).to include("call.possible-nil-receiver")
      end
    end

    it "CONTROL: the harness fires the truthiness fold in this fixture shape" do
      # The must-fire sibling for the Arm-A pin: three specs above assert
      # `flow.always-truthy-condition` empty, which a rule-id rename would vacuate silently.
      source = <<~RUBY
        class C
          def create
            flag = true
            "y" if flag
          end
        end
      RUBY
      with_demo(source) do |result|
        rules = result.diagnostics.map(&:rule)
        expect(rules).to include("flow.always-truthy-condition")
      end
    end

    it "does not re-type `require` / `permit` on a non-Parameters receiver" do
      # The receiver gate is `ActionController::Parameters` — a bare `require 'x'` (Kernel) or a `permit`
      # on some other object must not become Parameters.
      source = <<~RUBY
        class C
          def create
            Rigor.dump_type(require("set"))
          end
        end
      RUBY
      with_demo(source) do |result|
        dump = result.diagnostics.find { |d| d.rule == "dump.type" }
        expect(dump).not_to be_nil
        expect(dump.message).not_to include("ActionController::Parameters")
      end
    end
  end

  # Issue #534 "same lane" — the request predicates and the FlashHash chain. Each contract read off
  # Rails v8.0.2 / rack v3.1.8. Written as paired assertions for the same reason #578's block is: the
  # value of every answer here is that it is HONEST, and the negatives are what discriminate an honest
  # answer from a merely useful-looking one.
  #
  # `request.format` was withdrawn from this batch under review and is filed separately: a
  # `Mime::Type | Mime::NullType` union is nil-free, so unlike `true | false` it is NOT flow-inert, and
  # `Mime::NullType` carries an explicit `def nil?; true; end` that a nil-free union mismodels.
  describe "the request / flash surface (#534)" do
    def type_dumps(result)
      result.diagnostics.select { |d| d.rule == "dump.type" }.map(&:message)
    end

    def rule_ids(result)
      result.diagnostics.map(&:rule)
    end

    it "types every genuine-boolean request predicate as `bool`" do
      # The admission rule: a zero-argument predicate whose Rails/Rack body cannot return a non-boolean.
      # `request_method == POST` x10 from Rack::Request::Helpers, `/XMLHttpRequest/i.match?` for
      # xhr?/xml_http_request?, `scheme == "https" || scheme == "wss"` for ssl?, two `LOCALHOST.match?`
      # conjuncts for local?, `FORM_DATA_MEDIA_TYPES.include?(media_type)` for form_data?.
      names = Rigor::Plugin::Actionpack::REQUEST_PREDICATE_METHODS
      body = names.map { |n| "    Rigor.dump_type(request.#{n})" }.join("\n")
      with_demo("class C\n  def create\n#{body}\n  end\nend\n") do |result|
        expect(type_dumps(result).size).to eq(names.size)
        expect(type_dumps(result)).to all(eq("dump_type: bool"))
      end
    end

    it "leaves `request.format` untyped — withdrawn from this batch under review (#534)" do
      # The pin for the withdrawal, so re-adding the rule has to break a named assertion rather than
      # slip back in. `Mime::Type | Mime::NullType` is nil-free, hence not flow-inert the way the
      # predicates' `true | false` is, and `Mime::NullType` defines `nil?` as `true` — a
      # nil-masquerading object a nil-free union mismodels. Typing it needs its own adjudication.
      source = <<~RUBY
        class C
          def create
            Rigor.dump_type(request.format)
          end
        end
      RUBY
      with_demo(source) do |result|
        expect(type_dumps(result)).to eq(["dump_type: Dynamic[top]"])
      end
    end

    it "keeps a `request.format` condition unfolded — the withdrawn union's hazard (#534)" do
      # The shape review used to reject the union: no dump assertion, so what turns it red is the false
      # positive itself. Under `format -> Mime::Type | Mime::NullType` the ternary folds to `:f` and the
      # live `mode == :n` guard draws `flow.always-truthy-condition`.
      source = <<~RUBY
        class C
          def create
            mode = request.format ? :f : :n
            return "a" if mode == :n

            "b"
          end

          def nil_branch
            return "none" if request.format.nil?

            "some"
          end
        end
      RUBY
      with_demo(source) do |result|
        expect(rule_ids(result)).not_to include("flow.always-truthy-condition")
        expect(rule_ids(result)).not_to include("flow.unreachable-branch")
      end
    end

    it "types the FlashHash chain, and reads the arity of `keep` / `discard`" do
      # `now` is `@now ||= FlashNow.new(self)`. `keep` / `discard` are `k ? self[k] : self`, so only the
      # zero-argument spelling has an answer this plugin can name — given a key they are leaf reads and
      # must fall through to the untyped verdict below.
      source = <<~RUBY
        class C
          def create
            Rigor.dump_type(flash.now)
            Rigor.dump_type(flash.keep)
            Rigor.dump_type(flash.discard)
            Rigor.dump_type(flash.keep(:notice))
          end
        end
      RUBY
      with_demo(source) do |result|
        expect(type_dumps(result)).to eq(
          [
            "dump_type: ActionDispatch::Flash::FlashNow",
            "dump_type: ActionDispatch::Flash::FlashHash",
            "dump_type: ActionDispatch::Flash::FlashHash",
            "dump_type: Dynamic[top]"
          ]
        )
      end
    end

    it "does not hijack the predicate / flash names on other receivers" do
      # `post?`, `keep` and `now` are ordinary method names. Both rules are receiver-gated on the
      # request-context nominals, so a project's own object keeps its answers.
      source = <<~RUBY
        class Poll
          def post?
            true
          end

          def keep
            "kept"
          end
        end

        class C
          def create
            Rigor.dump_type(Poll.new.post?)
            Rigor.dump_type(Poll.new.keep)
            Rigor.dump_type(Time.now)
          end
        end
      RUBY
      with_demo(source) do |result|
        expect(type_dumps(result)).to eq(["dump_type: true", 'dump_type: "kept"', "dump_type: Time"])
      end
    end

    it "keeps the new surface FP-safe (no undefined-method on the chains)" do
      source = <<~RUBY
        class C
          def create
            flash.now[:alert] = "oops"
            flash.now.whatever_rails_adds
            flash.keep.discard
            flash.keep.sweep
          end
        end
      RUBY
      with_demo(source) do |result|
        expect(rule_ids(result)).not_to include("call.undefined-method")
      end
    end

    # --- the `bool` adjudication ------------------------------------------------------------------
    #
    # `flow.always-truthy-condition` fires when the flow proves a condition folds to ONE constant, and
    # `true | false` never does. Verified by construction: typing the predicates `Constant[true]`
    # instead turns the control-flow example below red with four firings, so `bool` — the union — is
    # precisely what makes them admissible. (The operator example stays green under that arm; it is a
    # plain regression pin for a shape nothing currently folds, and leans on the CONTROL below for its
    # liveness.) Contrast `Parameters#[]` (#578), where the candidate was a non-nil nominal standing in
    # for a value that is nil at runtime, and the fold it licensed was real.
    it "draws no fold on a predicate control-flow guard — the `bool` question (#534)" do
      # The ternary is the exact shape that rejected `Parameters#[] -> Parameters`: there `mode`
      # collapsed to one arm and the live `==` guard after it fired. Here `mode` keeps both arms.
      source = <<~RUBY
        class C
          def create
            return unless request.post?

            if request.xhr?
              1
            else
              2
            end
          end

          def ternary
            mode = request.get? ? :read : :write
            return "r" if mode == :read

            "w"
          end
        end
      RUBY
      with_demo(source) do |result|
        expect(rule_ids(result)).not_to include("flow.always-truthy-condition")
        expect(rule_ids(result)).not_to include("flow.unreachable-branch")
      end
    end

    it "draws no fold on predicate boolean operators (#534)" do
      source = <<~RUBY
        class C
          def boolean_ops
            request.post? && request.xhr?
            x = !request.get?
            y = request.ssl? || request.local?
            [x, y]
          end

          def raise_guard
            raise "not a post" unless request.post?

            request.xhr?
          end
        end
      RUBY
      with_demo(source) do |result|
        expect(rule_ids(result)).not_to include("flow.always-truthy-condition")
        expect(rule_ids(result)).not_to include("flow.unreachable-branch")
      end
    end

    # --- `[]=` needs nothing ----------------------------------------------------------------------
    it "already types a flash / session write as its RHS, with no rule for `[]=` (#534)" do
      # Ruby's assignment-expression semantics fix the value of `flash[:k] = v` at `v` whatever `[]=`
      # returns, and the engine already models that. This is the pin for NOT adding a `[]=` rule: a
      # contribution here could only agree with this answer or contradict it. The corpus's
      # "`FlashHash#[]=` 127 / 29" is a named-receiver *pair* count, which no return type can move.
      source = <<~RUBY
        class C
          def create
            Rigor.dump_type(flash[:notice] = "hi")
            Rigor.dump_type(session[:user_id] = 1)
            Rigor.dump_type(flash.now[:alert] = :bad)
          end
        end
      RUBY
      with_demo(source) do |result|
        expect(type_dumps(result)).to eq(['dump_type: "hi"', "dump_type: 1", "dump_type: :bad"])
      end
    end

    # --- the leaf-read adjudication ---------------------------------------------------------------
    it "keeps `flash[:key]` and `session[:key]` untyped (#534)" do
      source = <<~RUBY
        class C
          def leaf_reads
            Rigor.dump_type(flash[:notice])
            Rigor.dump_type(session[:user_id])
          end
        end
      RUBY
      with_demo(source) do |result|
        expect(type_dumps(result)).to eq(["dump_type: Dynamic[top]"] * 2)
      end
    end

    it "draws no possible-nil-receiver on an assigned leaf read — the `String?` arm (#534)" do
      # Deliberately carries NO dump assertion, so the thing that turns it red is the false positive
      # itself and not merely a changed type. Verified: under `flash[:k] -> String | nil`,
      # `note.upcase` fires `call.possible-nil-receiver` at ERROR severity. `uid.to_i` stays silent
      # under that arm because `NilClass` has `to_i`, which is what makes the noise unpredictable
      # rather than absent — and is why the fixture uses two different methods.
      source = <<~RUBY
        class C
          def assigned_use
            uid = session[:user_id]
            uid.to_i
            note = flash[:notice]
            note.upcase
          end
        end
      RUBY
      with_demo(source) do |result|
        expect(rule_ids(result)).not_to include("call.possible-nil-receiver")
      end
    end

    it "keeps a leaf-read condition unfolded — the non-nil `String` arm (#534)" do
      # The other arm, same construction: no dump assertion, so the false positive is the trigger.
      # Verified: under `flash[:k] -> String`, the ternary folds to `:flash` and the live
      # `mode == :plain` guard draws `flow.always-truthy-condition` — a diagnostic on a branch the
      # program takes. This is `Parameters#[]`'s Arm A (#578) reproduced on FlashHash.
      source = <<~RUBY
        class C
          def ternary
            mode = flash[:notice] ? :flash : :plain
            return "f" if mode == :plain

            "p"
          end

          def session_guard
            return unless session[:user_id]

            "in"
          end
        end
      RUBY
      with_demo(source) do |result|
        expect(rule_ids(result)).not_to include("flow.always-truthy-condition")
      end
    end

    it "CONTROL: the harness fires all three rules the negatives above assert absent" do
      # The must-fire sibling for this whole block — without it, a rule-id rename or an unanalysed
      # fixture would make every negative pass while reporting nothing.
      source = <<~RUBY
        class C
          def create
            "a string".no_such_method_on_string
            s = ["a", nil].sample
            s.upcase
            flag = true
            "y" if flag
          end
        end
      RUBY
      with_demo(source) do |result|
        expect(rule_ids(result)).to include("call.undefined-method")
        expect(rule_ids(result)).to include("call.possible-nil-receiver")
        expect(rule_ids(result)).to include("flow.always-truthy-condition")
      end
    end
  end

  describe "helper-call error diagnostics (canonically delegated to rigor-rails-routes)" do
    # rigor-actionpack and rigor-rails-routes both consume the same `:helper_table` fact. To avoid every
    # typo'd / wrong-arity helper call surfacing twice (once per plugin) on every Rails project, the actionpack
    # plugin emits only the info-level route-resolution (`helper-call`) and defers `unknown-helper` /
    # `wrong-helper-arity` to rigor-rails-routes. Mastodon pre-fix saw +301 duplicate errors from this overlap.
    # These specs assert the new contract: rails-routes still fires.
    it "rigor-rails-routes fires `unknown-helper` with a did-you-mean suggestion on a typo" do
      source = "class C\n  def show\n    usres_path\n  end\nend\n"
      with_demo(source) do |result|
        err = result.diagnostics.find do |d|
          d.source_family == "plugin.rails-routes" && d.rule == "unknown-helper"
        end
        expect(err).not_to be_nil
        expect(err.severity).to eq(:error)
        expect(err.message).to include("usres_path")
        expect(err.message).to include("users_path")
      end
    end

    it "actionpack stays silent on the unknown helper (no duplicate)" do
      source = "class C\n  def show\n    usres_path\n  end\nend\n"
      with_demo(source) do |result|
        ap_unknown = actionpack_diagnostics(result).select { |d| d.rule == "unknown-helper" }
        expect(ap_unknown).to be_empty
      end
    end

    it "rigor-rails-routes fires the arity-mismatch diagnostic on overflow" do
      # `about_path` is arity 0 — `accepts_arity?` allows `arity + 1` for the trailing-options-hash idiom, so
      # we pass 2 explicit args to overflow past the `0 + 1` tolerance. Underflow (passing 0 args to a
      # non-zero-arity helper) is silenced inside controller paths because of Rails' implicit-params-fill pattern.
      source = "class C\n  def show\n    about_path(1, 2)\n  end\nend\n"
      with_demo(source) do |result|
        err = result.diagnostics.find do |d|
          d.source_family == "plugin.rails-routes" && d.rule == "wrong-arity"
        end
        expect(err).not_to be_nil
        expect(err.severity).to eq(:error)
      end
    end

    it "actionpack stays silent on the arity mismatch (no duplicate)" do
      source = "class C\n  def show\n    about_path(1, 2)\n  end\nend\n"
      with_demo(source) do |result|
        ap_arity = actionpack_diagnostics(result).select { |d| d.rule == "wrong-helper-arity" }
        expect(ap_arity).to be_empty
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
              case File.basename(name, ".rb")
              when "rigor-rails-routes" then Rigor::Plugin.register(Rigor::Plugin::RailsRoutes)
              when "rigor-actionpack" then Rigor::Plugin.register(Rigor::Plugin::Actionpack)
              end
              true
            end
          )
          result = runner.run
          # The rails-routes plugin still validates the `usres_path` call (its own walker doesn't filter by
          # path), but actionpack's path filter must skip the lib/ file.
          ap_diags = result.diagnostics.select { |d| d.source_family == "plugin.actionpack" }
          expect(ap_diags).to be_empty
        end
      end
    end
  end

  describe "filter chains (Phase 2)" do
    def with_controllers(controllers:, routes: DEFAULT_AP_ROUTES_RB)
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
              case File.basename(name, ".rb")
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
        # `:show` and `:edit` are action names, NOT filter names — Phase 2 must NOT flag them as unknown
        # filters. (Phase 2.5 will validate the action-name arguments separately.)
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

    it "resolves filter methods transitively through `include` chains (Mastodon shape)" do
      # AccountsController includes SignatureAuthentication, SignatureAuthentication includes
      # SignatureVerification, SignatureVerification defines `require_account_signature!`. Pre-fix all 177
      # such Mastodon call sites surfaced as `unknown-filter-method`.
      with_controllers(controllers: {
                         "concerns/signature_verification.rb" => <<~RUBY,
                           module SignatureVerification
                             def require_account_signature!; end
                           end
                         RUBY
                         "concerns/signature_authentication.rb" => <<~RUBY,
                           module SignatureAuthentication
                             include SignatureVerification
                           end
                         RUBY
                         "accounts_controller.rb" => <<~RUBY
                           class AccountsController
                             include SignatureAuthentication

                             before_action :require_account_signature!
                           end
                         RUBY
                       }) do |result|
        diags = actionpack_diagnostics(result)
        expect(diags.select { |d| d.rule == "unknown-filter-method" }).to be_empty
        expect(diags.select { |d| d.rule == "filter-call" }).not_to be_empty
      end
    end

    # ──────────────────────────────────────────────────────
    # Mastodon shape: `module Admin; class AccountsController < BaseController; end; end` (nested-module form).
    # Pre-fix this registered the inner class as bare `AccountsController`, clobbering the top-level
    # `app/controllers/accounts_controller.rb` entry. The fix threads the enclosing module qualifier through
    # the AST walk so the entry's `class_name` is fully qualified.
    # ──────────────────────────────────────────────────────

    it "qualifies a nested-module class declaration with its enclosing scope" do
      with_controllers(controllers: {
                         "application_controller.rb" => "class ApplicationController\n  def require_user!; end\nend\n",
                         "admin/base_controller.rb" => <<~RUBY,
                           module Admin
                             class BaseController < ApplicationController
                               def admin_only!; end
                             end
                           end
                         RUBY
                         "admin/accounts_controller.rb" => <<~RUBY
                           module Admin
                             class AccountsController < BaseController
                               before_action :admin_only!
                               before_action :require_user!
                             end
                           end
                         RUBY
                       }) do |result|
        unknown = actionpack_diagnostics(result).select { |d| d.rule == "unknown-filter-method" }
        expect(unknown).to be_empty
      end
    end

    it "walks the full ancestor chain (multi-level inheritance)" do
      # `Admin::AccountsController < Admin::BaseController < ApplicationController` — `require_user!` is
      # defined on the GRANDPARENT. Pre-fix only the immediate parent was walked, so this case false-fired.
      with_controllers(controllers: {
                         "application_controller.rb" => <<~RUBY,
                           class ApplicationController
                             def require_user!; end
                           end
                         RUBY
                         "admin/base_controller.rb" => <<~RUBY,
                           module Admin
                             class BaseController < ApplicationController
                             end
                           end
                         RUBY
                         "admin/accounts_controller.rb" => <<~RUBY
                           module Admin
                             class AccountsController < BaseController
                               before_action :require_user!
                             end
                           end
                         RUBY
                       }) do |result|
        unknown = actionpack_diagnostics(result).select { |d| d.rule == "unknown-filter-method" }
        expect(unknown).to be_empty
      end
    end

    it "resolves a parent class name lexically (Admin::BaseController over top-level BaseController)" do
      with_controllers(controllers: {
                         "base_controller.rb" => <<~RUBY,
                           class BaseController
                             def top_level_only!; end
                           end
                         RUBY
                         "admin/base_controller.rb" => <<~RUBY,
                           module Admin
                             class BaseController
                               def admin_only!; end
                             end
                           end
                         RUBY
                         "admin/accounts_controller.rb" => <<~RUBY
                           module Admin
                             class AccountsController < BaseController
                               before_action :admin_only!
                             end
                           end
                         RUBY
                       }) do |result|
        unknown = actionpack_diagnostics(result).select { |d| d.rule == "unknown-filter-method" }
        expect(unknown).to be_empty
      end
    end

    it "resolves skip_before_action :name through the ancestor chain" do
      # The dominant Mastodon case (13 of 42 errors pre-fix): `skip_before_action :require_functional!`
      # references a filter declared on the parent.
      with_controllers(controllers: {
                         "application_controller.rb" => <<~RUBY,
                           class ApplicationController
                             before_action :require_functional!
                             def require_functional!; end
                           end
                         RUBY
                         "accounts_controller.rb" => <<~RUBY
                           class AccountsController < ApplicationController
                             skip_before_action :require_functional!
                           end
                         RUBY
                       }) do |result|
        unknown = actionpack_diagnostics(result).select { |d| d.rule == "unknown-filter-method" }
        expect(unknown).to be_empty
      end
    end

    it "suppresses unknown-filter-method when the controller includes a gem-shipped (unresolved) concern" do
      # Devise / Pundit-style: the controller `include`s a module whose source isn't in `app/controllers/`. We
      # can't see what methods that module provides, so an unrecognized `before_action :authenticate_user!`
      # MUST stay silent — the method could legitimately come from the unresolved include.
      with_controllers(controllers: {
                         "application_controller.rb" => <<~RUBY
                           class ApplicationController
                             include Devise::Controllers::Helpers

                             before_action :authenticate_user!
                           end
                         RUBY
                       }) do |result|
        diags = actionpack_diagnostics(result)
        expect(diags.select { |d| d.rule == "unknown-filter-method" }).to be_empty
      end
    end

    it "suppresses unknown-filter-method when the controller inherits from a gem-shipped (unresolved) parent" do
      # Devise/Doorkeeper-style:
      #   class Auth::ConfirmationsController < Devise::ConfirmationsController
      # The gem-shipped parent's own ancestor chain is invisible to us, so a `skip_before_action
      # :check_self_destruct!` against a filter that the parent's ancestors might legitimately define MUST
      # stay silent — same rationale as the unresolved-include case above.
      with_controllers(controllers: {
                         "auth/confirmations_controller.rb" => <<~RUBY
                           class Auth::ConfirmationsController < Devise::ConfirmationsController
                             skip_before_action :check_self_destruct!
                             skip_before_action :require_functional!
                           end
                         RUBY
                       }) do |result|
        diags = actionpack_diagnostics(result)
        expect(diags.select { |d| d.rule == "unknown-filter-method" }).to be_empty
      end
    end

    # #621 — `ControllerDiscoverer` ASSIGNED each declaration into the entry Hash, so a controller declared
    # in two files kept only the one that sorted later in the glob and every filter target the other file
    # defined surfaced as a false `unknown-filter-method`. The rooted spelling made it worse: `module Admin;
    # class ::UsersController` was keyed as the nonsense `"Admin::UsersController"`, which the analyzer's
    # own (identical) qualification could not name either.
    describe "rooted declarations and reopens (#621)" do
      it "keeps the earlier declaration's methods when a later file reopens the controller" do
        with_controllers(controllers: {
                           "a_users_controller.rb" => <<~RUBY,
                             class UsersController
                               before_action :authenticate!
                               def authenticate!; end
                             end
                           RUBY
                           "z_users_controller_ext.rb" => <<~RUBY
                             class UsersController
                               before_action :set_user
                               def set_user; end
                             end
                           RUBY
                         }) do |result|
          diags = actionpack_diagnostics(result)
          expect(diags.select { |d| d.rule == "unknown-filter-method" }.map(&:message)).to be_empty
          expect(diags.select { |d| d.rule == "filter-call" }.size).to eq(2)
        end
      end

      it "merges a ROOTED reopen into the same entry as the plain declaration" do
        with_controllers(controllers: {
                           "a_users_controller.rb" => <<~RUBY,
                             class ::UsersController
                               before_action :authenticate!
                               def authenticate!; end
                             end
                           RUBY
                           "z_users_controller_ext.rb" => <<~RUBY
                             class UsersController
                               before_action :set_user
                               def set_user; end
                             end
                           RUBY
                         }) do |result|
          diags = actionpack_diagnostics(result)
          expect(diags.select { |d| d.rule == "unknown-filter-method" }.map(&:message)).to be_empty
          expect(diags.select { |d| d.rule == "filter-call" }.size).to eq(2)
        end
      end

      it "keeps the parent class a rooted declaration spells when the reopen omits it" do
        with_controllers(controllers: {
                           "application_controller.rb" =>
                             "class ApplicationController\n  def authenticate!; end\nend\n",
                           "a_users_controller.rb" => "class ::UsersController < ApplicationController\nend\n",
                           "z_users_controller_ext.rb" => <<~RUBY
                             class UsersController
                               before_action :authenticate!
                             end
                           RUBY
                         }) do |result|
          diags = actionpack_diagnostics(result)
          expect(diags.select { |d| d.rule == "unknown-filter-method" }).to be_empty
          expect(diags.select { |d| d.rule == "filter-call" }).not_to be_empty
        end
      end

      it "keys a controller declared rooted INSIDE a module as the top-level constant it names" do
        with_controllers(controllers: {
                           "admin/users_controller.rb" => <<~RUBY
                             module Admin
                               class ::UsersController
                                 before_action :authenticate!
                                 def authenticate!; end
                               end
                             end
                           RUBY
                         }) do |result|
          diags = actionpack_diagnostics(result)
          expect(diags.select { |d| d.rule == "unknown-filter-method" }).to be_empty
          expect(diags.select { |d| d.rule == "filter-call" }).not_to be_empty
        end
      end

      it "still fires unknown-filter-method for a name neither declaration defines" do
        with_controllers(controllers: {
                           "a_users_controller.rb" => <<~RUBY,
                             class ::UsersController
                               def authenticate!; end
                             end
                           RUBY
                           "z_users_controller_ext.rb" => <<~RUBY
                             class UsersController
                               before_action :authenticat!
                               def set_user; end
                             end
                           RUBY
                         }) do |result|
          err = actionpack_diagnostics(result).find { |d| d.rule == "unknown-filter-method" }
          expect(err).not_to be_nil
          expect(err.severity).to eq(:error)
          expect(err.message).to include("authenticat!")
          # The merged method set is what the suggestion is drawn from — proof the union reached the rule.
          expect(err.message).to include("Did you mean `:authenticate!`?")
        end
      end
    end
  end

  describe "render targets (Phase 3)" do
    def with_render_demo(controller_source, views: {})
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
              case File.basename(name, ".rb")
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
    def with_strong_params(controller_source)
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
              case File.basename(name, ".rb")
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

    it "does not fire unknown-permit-key for a virtual (non-column, non-typo) attribute" do
      # Permitting a virtual attribute is ordinary Rails — Devise's `password` / `password_confirmation`,
      # a state-machine `*_event`, an `attr_accessor` setter. None is a column and none is a near-typo of
      # one, so the strong-params check (a typo detector) must stay silent.
      with_strong_params(<<~RUBY) do |result|
        class UsersController
          def create
            params.require(:user).permit(:name, :password, :password_confirmation, :remember_me)
          end
        end
      RUBY
        expect(actionpack_diagnostics(result).select { |d| d.rule == "unknown-permit-key" }).to be_empty
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

  describe "nested-module controllers — analyzer matches discoverer qualification" do
    # The `ControllerDiscoverer` (separate slice) qualifies a nested-module declaration as
    # `Admin::DomainBlocksController`. The analyzer's `diagnose_filters` / `diagnose_renders` MUST resolve the
    # same qualified name from the AST, or filter validation silently no-ops and render-target paths point at
    # the wrong directory (`domain_blocks/` vs `admin/domain_blocks/`).

    def with_nested_module_controller(path:, contents:, views: {})
      Dir.mktmpdir do |dir|
        materialise_nested_module_fixture(dir, path, contents, views)
        Dir.chdir(dir) do
          yield nested_module_runner(dir).run
        end
      end
    end

    def materialise_nested_module_fixture(dir, path, contents, views)
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "routes.rb"), DEFAULT_AP_ROUTES_RB)
      full = File.join(dir, "app", "controllers", path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, contents)
      views.each do |relative, body|
        view_full = File.join(dir, "app", "views", relative)
        FileUtils.mkdir_p(File.dirname(view_full))
        File.write(view_full, body)
      end
    end

    def nested_module_runner(dir)
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          "paths" => [File.join(dir, "app", "controllers")],
          "plugins" => %w[rigor-rails-routes rigor-actionpack]
        )
      )
      Rigor::Analysis::Runner.new(
        configuration: configuration, cache_store: nil,
        plugin_requirer: lambda { |name|
          case File.basename(name, ".rb")
          when "rigor-rails-routes" then Rigor::Plugin.register(Rigor::Plugin::RailsRoutes)
          when "rigor-actionpack" then Rigor::Plugin.register(Rigor::Plugin::Actionpack)
          end
          true
        }
      )
    end

    it "resolves `render :new` from a nested-module controller against the qualified view directory" do
      with_nested_module_controller(
        path: "admin/domain_blocks_controller.rb",
        contents: <<~RUBY,
          module Admin
            class DomainBlocksController
              def new
                render :new
              end
            end
          end
        RUBY
        views: { "admin/domain_blocks/new.html.erb" => "<h1>New</h1>\n" }
      ) do |result|
        info = actionpack_diagnostics(result).find { |d| d.rule == "render-target" }
        expect(info).not_to be_nil
        expect(info.message).to include("admin/domain_blocks/new")
        missing = actionpack_diagnostics(result).select { |d| d.rule == "missing-template" }
        expect(missing).to be_empty
      end
    end

    it "validates filter chains on a nested-module controller via the qualified ControllerIndex entry" do
      with_nested_module_controller(
        path: "admin/domain_blocks_controller.rb",
        contents: <<~RUBY
          module Admin
            class DomainBlocksController
              before_action :authenticate_admin!
              def authenticate_admin!; end
            end
          end
        RUBY
      ) do |result|
        unknown = actionpack_diagnostics(result).select { |d| d.rule == "unknown-filter-method" }
        expect(unknown).to be_empty
        info = actionpack_diagnostics(result).find { |d| d.rule == "filter-call" }
        expect(info).not_to be_nil
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
              Rigor::Plugin.register(Rigor::Plugin::Actionpack) if File.basename(name, ".rb") == "rigor-actionpack"
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
