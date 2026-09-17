# frozen_string_literal: true

# #1048 — the controller action → template effect edge, and discharging the `render` taint.
#
# #393 made a template an effect unit (`view:users/show.html`); nothing connected a controller action to
# the template it renders, so `UsersController#show` reported its own effects plus the
# `template-not-analysed` taint even when the template's unit was sitting in the same table.
#
# The seam is `Plugin::EffectAttribution#callee:` — a row naming one of the engine's own
# `Effects::CalleeRule` rules, which reads the call's argument literals and answers a callee key. The
# taint travels ON the resulting edge (`FileCollection::Edge#taint_if_unresolved`), so a render that
# reaches a real unit clears it and one that reaches nothing keeps it — a question only the merged table
# can answer.

require "spec_helper"
require "fileutils"
require "tmpdir"

TEMPLATE_EDGE_ACTIONPACK_LIB = File.expand_path("../../../plugins/rigor-actionpack/lib", __dir__)
TEMPLATE_EDGE_ACTIVERECORD_LIB = File.expand_path("../../../plugins/rigor-activerecord/lib", __dir__)
$LOAD_PATH.unshift(TEMPLATE_EDGE_ACTIONPACK_LIB) unless $LOAD_PATH.include?(TEMPLATE_EDGE_ACTIONPACK_LIB)
$LOAD_PATH.unshift(TEMPLATE_EDGE_ACTIVERECORD_LIB) unless $LOAD_PATH.include?(TEMPLATE_EDGE_ACTIVERECORD_LIB)
require "rigor-actionpack"
require "rigor-activerecord"

TEMPLATE_EDGE_MODELS = <<~RUBY
  class ApplicationRecord < ActiveRecord::Base
  end

  class User < ApplicationRecord
    has_many :posts
  end

  class Post < ApplicationRecord
  end
RUBY

# One action per render spelling the rule claims, plus the two it must decline.
TEMPLATE_EDGE_CONTROLLER = <<~RUBY
  class ApplicationController < ActionController::Base
  end

  class UsersController < ApplicationController
    before_action :set_user

    def show; end

    def edit
      render :show
    end

    def new
      render "show"
    end

    def create
      render template: "users/show"
    end

    def update
      render action: :show
    end

    def index
      render partial: "row", collection: [1, 2]
    end

    def destroy
      render params[:view]
    end

    def missing
      render :nope
    end

    def away
      redirect_to "/"
    end

    private

    def set_user
      @user = User.find(1)
    end
  end
RUBY

TEMPLATE_EDGE_SHOW_ERB = <<~ERB
  <h1>Show</h1>
  <%= render partial: "card" %>
  <%= render "row" %>
  <%= render layout: "wrapper" do %>
    <p>body</p>
  <% end %>
ERB

# The write the action has to inherit, two hops up.
TEMPLATE_EDGE_CARD_ERB = <<~ERB
  <div><% @user.update(last_seen_at: 1) %></div>
ERB

# A lazy read in a view — the `views: strict` / `views: lenient` pair's subject.
TEMPLATE_EDGE_ROW_ERB = <<~ERB
  <span><%= @user.posts.count %></span>
ERB

RSpec.describe "plugins/rigor-actionpack — the controller → template effect edge (#1048)" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  def build_project(dir, envelopes: nil, workers: 0)
    FileUtils.mkdir_p(File.join(dir, "app", "models"))
    FileUtils.mkdir_p(File.join(dir, "app", "controllers"))
    FileUtils.mkdir_p(File.join(dir, "app", "views", "users"))
    File.write(File.join(dir, "app", "models", "user.rb"), TEMPLATE_EDGE_MODELS)
    File.write(File.join(dir, "app", "controllers", "users_controller.rb"), TEMPLATE_EDGE_CONTROLLER)
    File.write(File.join(dir, "app", "views", "users", "show.html.erb"), TEMPLATE_EDGE_SHOW_ERB)
    File.write(File.join(dir, "app", "views", "users", "_card.html.erb"), TEMPLATE_EDGE_CARD_ERB)
    File.write(File.join(dir, "app", "views", "users", "_row.html.erb"), TEMPLATE_EDGE_ROW_ERB)
    effects = {}
    effects["envelopes"] = envelopes if envelopes
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => ["app"], "plugins" => %w[rigor-activerecord rigor-actionpack], "effects" => effects,
        "parallel" => { "workers" => workers }
      )
    )
  end

  def in_project(**)
    Dir.mktmpdir("rigor-1048-") do |dir|
      config = build_project(dir, **)
      Dir.chdir(dir) do
        runner = Rigor::Analysis::Runner.new(
          configuration: config, cache_store: nil,
          plugin_requirer: lambda do |name|
            case File.basename(name, ".rb")
            when "rigor-actionpack" then Rigor::Plugin.register(Rigor::Plugin::Actionpack)
            when "rigor-activerecord" then Rigor::Plugin.register(Rigor::Plugin::Activerecord)
            end
            true
          end
        )
        yield runner, guarded_run(runner, ["app"])
      end
    end
  end

  def unit(runner, key)
    runner.effect_table.find { |row| row.key == key }
  end

  def causes_of(runner, key)
    unit(runner, key)&.causes || []
  end

  describe "the edge itself" do
    it "reaches the template from every render spelling the rule claims" do
      in_project do |runner, _result|
        %w[show edit new create update].each do |action|
          expect(unit(runner, "UsersController##{action}")&.edges)
            .to include("view:users/show.html"), "expected ##{action} to edge to the show template"
        end
        expect(unit(runner, "UsersController#index").edges).to include("view:users/_row.html")
      end
    end

    it "carries the template's effects into the action's closure, implicit render included" do
      in_project do |runner, _result|
        # `show` renders nothing explicitly — Rails renders `users/show`, which renders `_card`, which
        # writes. Two hops, and the second one is a template → partial edge.
        expect(unit(runner, "UsersController#show").proven.to_a).to include("io.db.write")
        expect(unit(runner, "UsersController#edit").proven.to_a).to include("io.db.write")
        expect(unit(runner, "view:users/show.html").proven.to_a).to include("io.db.write")
      end
    end

    it "is a superset of the template's own labels, which is the acceptance line" do
      in_project do |runner, _result|
        action = unit(runner, "UsersController#show")
        template = unit(runner, "view:users/show.html")

        expect(template.proven.to_a).not_to be_empty
        expect(action.proven.to_a).to include(*template.proven.to_a)
        expect(action.declared.to_a).to include(*template.declared.to_a)
      end
    end

    it "does not edge an action that answered for itself" do
      in_project do |runner, _result|
        # `redirect_to` renders no template, so the implicit-render rule must stand down: the
        # conventional `users/away` would be a view this action never runs.
        expect(unit(runner, "UsersController#away").edges).to be_empty
      end
    end

    it "edges a template to the partials it renders, positionally and by keyword" do
      in_project do |runner, _result|
        edges = unit(runner, "view:users/show.html").edges

        expect(edges).to include("view:users/_card.html")
        expect(edges).to include("view:users/_row.html")
      end
    end
  end

  describe "the `template-not-analysed` taint" do
    it "clears on a render whose template produced a unit" do
      in_project do |runner, _result|
        # The action's OWN render taint is gone. What it still carries is the taint the template it
        # reached carries about ITS unresolved layout — a cause that travels the edge like any other, and
        # the honest reading of "and possibly more, one hop further down".
        %w[show edit new create update index].each do |action|
          expect(causes_of(runner, "UsersController##{action}"))
            .not_to include(["template-not-analysed", "ActionController::Base#render"]),
                    "expected ##{action} to discharge its own render taint"
        end
      end
    end

    it "stays on a render whose target the rule cannot settle" do
      in_project do |runner, _result|
        expect(causes_of(runner, "UsersController#destroy"))
          .to include(["template-not-analysed", "ActionController::Base#render"])
      end
    end

    it "stays on a render whose named template no unit answers" do
      in_project do |runner, _result|
        # `render :nope` resolves to `view:users/nope.html`, which is not in the table. The cause is
        # seeded by the propagator from the edge rather than by the scan, and it is never silently lost.
        expect(causes_of(runner, "UsersController#missing"))
          .to include(["template-not-analysed", "ActionController::Base#render"])
      end
    end

    it "stays on a layout, which is a declined unit today (#1047)" do
      in_project do |runner, _result|
        expect(causes_of(runner, "view:users/show.html"))
          .to include(["template-not-analysed", "ActionView::Base#render"])
      end
    end
  end

  describe "pooled versus sequential" do
    it "agrees on the effect table, edges included" do
      sequential = nil
      pooled = nil
      in_project(workers: 0) do |runner, _r|
        sequential = runner.effect_table.map { |row| [row.key, row.proven.to_a, row.declared.to_a, row.edges] }
      end
      in_project(workers: 2) do |runner, _r|
        pooled = runner.effect_table.map { |row| [row.key, row.proven.to_a, row.declared.to_a, row.edges] }
      end

      expect(pooled).to eq(sequential)
    end
  end

  describe "`views: strict` against `views: lenient`" do
    LENIENT = [{ "match" => "app/views/**/*",
                 "effect" => ["mutate.local", "mutate.self", "io.db.read"] }].freeze
    STRICT = [{ "match" => "app/views/**/*", "effect" => ["mutate.local", "mutate.self"] }].freeze

    # The `_row` partial is the one whose only effect is the lazy `@user.posts.count`. `_card` writes,
    # and a write is a finding under BOTH presets, which is what the manual already says.
    def row_findings(result)
      result.diagnostics.select do |diagnostic|
        diagnostic.rule.to_s.include?("envelope") && diagnostic.path.to_s.end_with?("_row.html.erb")
      end
    end

    it "reports a lazy relation read in a view under `strict` and not under `lenient`" do
      in_project(envelopes: STRICT) do |_runner, result|
        expect(row_findings(result).map(&:message).join("\n")).to include("io.db.read")
      end
      in_project(envelopes: LENIENT) do |_runner, result|
        expect(row_findings(result)).to be_empty
      end
    end

    # The paired arm, both halves.
    #
    # What moved into the proven lane is a FIRST-PARTY BUNDLED plugin's DISCHARGING row — the engine's own
    # audited statement about a framework method, which ADR-103 WD6 already trusts enough to declare the
    # call site exhaustive. That move is deliberately Rails-layer-wide rather than scoped to templates:
    # `UsersController#set_user` calls `User.find` and now proves `io.db.read` for exactly the same
    # reason the view does, and a rule that answered differently on the two would be a coincidence
    # dressed as a principle.
    it "moves a non-template method's first-party claim into the same lane, deliberately" do
      in_project do |runner, _result|
        expect(unit(runner, "UsersController#set_user").proven.to_a).to include("io.db.read")
      end
    end

    it "leaves an unaudited claim declared, so it can still never manufacture a finding" do
      row = Rigor::Effects::PluginFacts::Row.new(
        key: "Vendor::Client#call", labels: Rigor::Effects::LabelSet.new(["io.net.http"]), narrow: nil,
        discharge: false, within: nil, taint: nil, plugin_id: "third-party"
      )

      # A third-party plugin's `discharge: true` is demoted at load ({PluginFacts#discharge_granted?}),
      # and the project's own `effects.attribution:` table never discharged at all — both keep the
      # declared lane, and `EnvelopeCheck` still reads proven only.
      expect(row.discharge?).to be(false)
    end
  end
end
