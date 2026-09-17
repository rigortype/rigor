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

    def maybe
      redirect_to "/" if @user.nil?
    end

    def rescued
      @user.reload
    rescue StandardError
      redirect_to "/"
    end

    def handler_suffix
      render template: "users/show.html.erb"
    end

    def bare_html_arm
      respond_to do |format|
        format.html
        format.json { render json: @user }
      end
    end

    def in_transaction
      User.transaction { redirect_to "/" }
    end

    def dispatched
      respond_to do |format|
        format.html { render :show }
      end
    end

    def json_suffix
      render "show.json"
    end

    private

    def card
      @user = User.find(1)
    end

    def reopened
      @user.touch
    end
    public :reopened

    def self.klass_helper
      1
    end

    public

    def klass_helper
      @user.touch
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

# Templates named after the units a unit rule must NOT fire on: a conditional responder still takes the
# implicit render (so `maybe` and `rescued` must reach theirs), and a private helper never does (so
# `card` must not reach its).
TEMPLATE_EDGE_MAYBE_ERB = <<~ERB
  <p><% @user.touch %></p>
ERB

TEMPLATE_EDGE_PRIVATE_ERB = <<~ERB
  <p><% @user.destroy %></p>
ERB

TEMPLATE_EDGE_JSON_ERB = <<~ERB
  <%= @user.name %>
ERB

# `{relative path => source}`. Every action that must KEEP an implicit-render edge gets a template
# doing `@user.touch`, so the assertion is a label arriving rather than a key existing.
TEMPLATE_EDGE_FILES = {
  "app/models/user.rb" => TEMPLATE_EDGE_MODELS,
  "app/controllers/users_controller.rb" => TEMPLATE_EDGE_CONTROLLER,
  "app/views/users/show.html.erb" => TEMPLATE_EDGE_SHOW_ERB,
  "app/views/users/_card.html.erb" => TEMPLATE_EDGE_CARD_ERB,
  "app/views/users/_row.html.erb" => TEMPLATE_EDGE_ROW_ERB,
  "app/views/users/card.html.erb" => TEMPLATE_EDGE_PRIVATE_ERB,
  "app/views/users/show.json.erb" => TEMPLATE_EDGE_JSON_ERB
}.merge(
  %w[maybe rescued bare_html_arm in_transaction reopened dispatched klass_helper]
    .to_h { |action| ["app/views/users/#{action}.html.erb", TEMPLATE_EDGE_MAYBE_ERB] }
).freeze

RSpec.describe "plugins/rigor-actionpack — the controller → template effect edge (#1048)" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  def build_project(dir, envelopes: nil, workers: 0)
    TEMPLATE_EDGE_FILES.each do |relative, source|
      path = File.join(dir, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source)
    end
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
        expect(unit(runner, "UsersController#show").declared.to_a).to include("io.db.write")
        expect(unit(runner, "UsersController#edit").declared.to_a).to include("io.db.write")
        expect(unit(runner, "view:users/show.html").declared.to_a).to include("io.db.write")
      end
    end

    it "is a superset of the template's own labels, which is the acceptance line" do
      in_project do |runner, _result|
        action = unit(runner, "UsersController#show")
        template = unit(runner, "view:users/show.html")

        expect(template.declared.to_a).not_to be_empty
        expect(action.declared.to_a).to include(*template.declared.to_a)
        expect(action.proven.to_a).to include(*template.proven.to_a)
      end
    end

    it "does not edge an action that answered for itself" do
      in_project do |runner, _result|
        # `redirect_to` renders no template, so the implicit-render rule must stand down: the
        # conventional `users/away` would be a view this action never runs.
        expect(unit(runner, "UsersController#away").edges).to be_empty
      end
    end

    it "keeps the implicit render for a CONDITIONAL responder, on the path that still takes it" do
      in_project do |runner, _result|
        # `redirect_to "/" if @user.nil?` answers on one path and not the other, so `users/maybe` is
        # still rendered. Dropping the edge here would lose the template's `io.db.write` AND leave the
        # action reading exhaustive — the one combination a summary may never produce.
        %w[maybe rescued].each do |action|
          entry = unit(runner, "UsersController##{action}")

          expect(entry.edges).to include("view:users/#{action}.html"), "expected ##{action} to keep the edge"
          expect(entry.declared.to_a).to include("io.db.write")
        end
      end
    end

    it "keeps the implicit render when the response is inside a block that may not run" do
      in_project do |runner, _result|
        # `respond_to { |f| f.html; f.json { render json: @user } }` is the shape that matters most:
        # the `render json:` is the JSON arm's answer and says nothing about the HTML arm, which takes
        # the implicit render. `User.transaction { redirect_to "/" }` is the same question with a
        # different block — a call the body may not make, recorded as if it always did.
        %w[bare_html_arm in_transaction].each do |action|
          entry = unit(runner, "UsersController##{action}")

          expect(entry.edges).to include("view:users/#{action}.html"), "expected ##{action} to keep the edge"
          expect(entry.declared.to_a).to include("io.db.write")
        end
      end
    end

    it "over-approximates a response inside a format arm, which costs labels and never a taint" do
      in_project do |runner, _result|
        # `format.html { render :show }` really does answer, but an arm is a block the body may not run,
        # so the conventional `users/dispatched` edge is emitted beside the one the `render` names. That
        # is the accepted direction: an edge contributes labels and never a taint, while the other way
        # round loses the template of an action that DID take the implicit render — and leaves it
        # reading exhaustive.
        entry = unit(runner, "UsersController#dispatched")

        expect(entry.edges).to include("view:users/show.html")
        expect(entry.edges).to include("view:users/dispatched.html")
      end
    end

    it "never renders a PRIVATE helper, however much a template shares its name" do
      in_project do |runner, _result|
        # Rails' `action_methods` is a controller's public instance methods. `app/views/users/card.html.erb`
        # exists and destroys a record; `private def card` must not be handed its effects.
        entry = unit(runner, "UsersController#card")

        expect(entry.edges).not_to include("view:users/card.html")
        expect(entry.declared.to_a).not_to include("io.db.destroy")
        expect(entry.proven.to_a).not_to include("io.db.write")
      end
    end

    it "lets `public :name` re-open a member the private region closed" do
      in_project do |runner, _result|
        # `private; def reopened; end; public :reopened` is a public action. An answer that only ever
        # grew would read it as private and drop its edge.
        expect(unit(runner, "UsersController#reopened").edges).to include("view:users/reopened.html")
      end
    end

    it "does not let a `def self.x` inside a private region mark the instance method of that name" do
      in_project do |runner, _result|
        # `private; def self.klass_helper; end; public; def klass_helper; end` — a `private` region hides
        # no singleton method, and the two are different methods that share a name. An answer keyed on
        # the name alone would mark the public action private and drop its edge.
        expect(unit(runner, "UsersController#klass_helper").edges).to include("view:users/klass_helper.html")
      end
    end

    it "strips a written handler and reads a written format off the name" do
      in_project do |runner, _result|
        # `render template: "users/show.html.erb"` and `render "show.json"` — a logical name carries no
        # handler, and a key of `view:users/show.html.erb.html` would answer nothing for ever.
        expect(unit(runner, "UsersController#handler_suffix").edges).to include("view:users/show.html")
        expect(unit(runner, "UsersController#json_suffix").edges).to include("view:users/show.json")
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

  # #1059 — `views: strict` and `views: lenient` still bound the same thing, because a first-party
  # plugin's `io.db.read` rides the DECLARED lane and `EnvelopeCheck` reads the proven one. ADR-103
  # WD17 ruled on that lane, so #1048 does not move it; what is pinned here is today's behaviour, which
  # is the premise the open question rests on.
  describe "the lane a plugin row lands in (ADR-103 WD17)" do
    it "keeps a first-party discharging row in the declared lane, so no envelope can judge it" do
      in_project do |runner, _result|
        entry = unit(runner, "UsersController#set_user")

        expect(entry.declared.to_a).to include("io.db.read")
        expect(entry.proven.to_a).not_to include("io.db.read")
      end
    end

    it "keeps a view's read declared too, which is why neither preset reports it" do
      in_project do |runner, _result|
        row = unit(runner, "view:users/_row.html")

        expect(row.declared.to_a).to include("io.db.read")
        expect(row.proven.to_a).not_to include("io.db.read")
      end
    end
  end
end
