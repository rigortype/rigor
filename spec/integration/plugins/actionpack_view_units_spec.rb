# frozen_string_literal: true

# #393 — ERB templates as effect units in rigor-actionpack. The plugin claims `app/views/**/*.erb`,
# compiles each match into Ruby with a line map (Erubi when it resolves in the analysed project's bundle,
# stdlib `ERB` otherwise), and hands the engine a `Plugin::TemplateUnit` with the view context as `self`,
# the strict-locals names as locals, and the rendering action's assigns as ivar seeds.
#
# The fixture project is the one the issue describes: `UsersController#show` assigns `@user` through a
# `before_action`, `show.html.erb` renders a `_card.html.erb` partial, and the partial calls
# `@user.update` — which is what has to reach `io.db.write` at the partial's own line.

require "spec_helper"
require "fileutils"
require "tmpdir"

VIEW_UNITS_ACTIONPACK_LIB = File.expand_path("../../../plugins/rigor-actionpack/lib", __dir__)
VIEW_UNITS_ACTIVERECORD_LIB = File.expand_path("../../../plugins/rigor-activerecord/lib", __dir__)
$LOAD_PATH.unshift(VIEW_UNITS_ACTIONPACK_LIB) unless $LOAD_PATH.include?(VIEW_UNITS_ACTIONPACK_LIB)
$LOAD_PATH.unshift(VIEW_UNITS_ACTIVERECORD_LIB) unless $LOAD_PATH.include?(VIEW_UNITS_ACTIVERECORD_LIB)
require "rigor-actionpack"
require "rigor-activerecord"

VIEW_UNITS_MODELS = <<~RUBY
  class ApplicationRecord < ActiveRecord::Base
  end

  class User < ApplicationRecord
    has_many :posts
  end

  class Post < ApplicationRecord
  end
RUBY

VIEW_UNITS_CONTROLLER = <<~RUBY
  class ApplicationController < ActionController::Base
  end

  class UsersController < ApplicationController
    before_action :set_user, only: %i[show]

    def show; end

    def maybe
      @maybe = User.find_by(id: 1)
    end

    private

    def set_user
      @user = User.find(params[:id])
    end
  end
RUBY

VIEW_UNITS_SHOW_ERB = <<~ERB
  <h1>Show</h1>
  <p><%= @user.name %></p>
  <%= render partial: "card", locals: { user: @user } %>
  <p><%= "literal".upcasee %></p>
ERB

VIEW_UNITS_CARD_ERB = <<~ERB
  <%# locals: (user:, admin: false) %>
  <div class="card">
    <span><%= user %></span>
    <% @user.update(last_seen_at: Time.now) %>
  </div>
ERB

# The two calls {ViewAssigns::Builder} makes on the plugin IO boundary. A real boundary needs the
# service container; this needs a directory and a file.
VIEW_ASSIGNS_BOUNDARY = Struct.new(:root) do
  def directory?(path) = File.directory?(path)
  def read_file(path) = File.read(path)
end

RSpec.describe "plugins/rigor-actionpack — ERB template units (#393)" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  def build_project(dir, envelopes: nil, view_type_checks: false, workers: 0)
    FileUtils.mkdir_p(File.join(dir, "app", "models"))
    FileUtils.mkdir_p(File.join(dir, "app", "controllers"))
    FileUtils.mkdir_p(File.join(dir, "app", "views", "users"))
    File.write(File.join(dir, "app", "models", "user.rb"), VIEW_UNITS_MODELS)
    File.write(File.join(dir, "app", "controllers", "users_controller.rb"), VIEW_UNITS_CONTROLLER)
    File.write(File.join(dir, "app", "views", "users", "show.html.erb"), VIEW_UNITS_SHOW_ERB)
    File.write(File.join(dir, "app", "views", "users", "_card.html.erb"), VIEW_UNITS_CARD_ERB)
    configuration(envelopes: envelopes, view_type_checks: view_type_checks, workers: workers)
  end

  def configuration(envelopes:, view_type_checks:, workers:)
    effects = {}
    effects["envelopes"] = envelopes if envelopes
    plugins = ["rigor-activerecord"]
    plugins << if view_type_checks
                 { "gem" => "rigor-actionpack", "config" => { "view_type_checks" => true } }
               else
                 "rigor-actionpack"
               end
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => ["app"], "plugins" => plugins, "effects" => effects,
        "parallel" => { "workers" => workers }
      )
    )
  end

  def in_project(**)
    Dir.mktmpdir("rigor-393-") do |dir|
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

  # A bare, initialised plugin instance for the unit-level hooks. `Plugin::Base#initialize` takes the
  # service container, and nothing exercised here reaches it.
  def view_plugin
    plugin = Rigor::Plugin::Actionpack.new(services: nil, config: {})
    plugin.init(nil)
    plugin
  end

  # Runs the assigns builder over one controller source in a throwaway tree, and answers what it seeded
  # for `widgets/<template>`.
  def build_assigns(controller_source, template: "show")
    Dir.mktmpdir("rigor-393-assigns-") do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "controllers"))
      File.write(File.join(dir, "app", "controllers", "widgets_controller.rb"), controller_source)
      Dir.chdir(dir) do
        index = Rigor::Plugin::Actionpack::ViewAssigns::Builder.new(
          io_boundary: VIEW_ASSIGNS_BOUNDARY.new(dir), search_paths: ["app/controllers"]
        ).build
        index.seeds_for("widgets/#{template}.html")
      end
    end
  end

  def unit(runner, key)
    runner.effect_table.find { |row| row.key == key }
  end

  describe "the compiler" do
    subject(:compiler) { Rigor::Plugin::Actionpack::ErbCompiler }

    it "maps every template line onto the compiled line that carries it" do
      compiled, map, transform = compiler.compile(VIEW_UNITS_SHOW_ERB)

      expect(map.values).to eq((1..VIEW_UNITS_SHOW_ERB.lines.length).to_a)
      expect(map.keys).to eq(map.keys.sort)
      expect(transform).to match(/\A(erubi|erb)-/)
      expect(Prism.parse(compiled).errors).to be_empty
    end

    it "keeps a multi-line tag's own lines aligned" do
      source = "<p><%= a %></p>\n<%= b(\n  1) %>\n<span><%= c %></span>\n"
      compiled, map = compiler.compile(source)

      expect(map.length).to eq(4)
      # `c` sits on template line 4, and only lands there if the tag spanning lines 2-3 really consumed
      # two compiled lines of its own.
      compiled_line = compiled.lines.index { |line| line.include?(" c ") } + 1
      expect(map[compiled_line]).to eq(4)
    end

    it "scrubs invalid bytes once, for every reader of the template" do
      # A single invalid byte used to raise out of `ViewUnits.strict_locals`' Regexp — the compiler
      # scrubbed and the locals reader did not — which the seam turns into an `error`-severity
      # `:plugin_loader` row, so one mis-encoded view failed the whole run.
      raw = +"<%# locals: (user:) %>\n<p>caf\xE9 <%= user %></p>\n"
      raw.force_encoding(Encoding::UTF_8)

      units = view_plugin.template_units_for_file(path: "app/views/users/_card.html.erb", source: raw)

      expect(units.length).to eq(1)
      expect(units.first.locals.keys).to eq(["user"])
      expect(units.first.ruby_source).to be_valid_encoding
    end

    it "measures the prologue rather than assuming it, for a compiler CI cannot install" do
      # Erubi resolves only out of an analysed project's bundle (ADR-90), so the Erubi leg never runs
      # here — and its prologue is a DIFFERENT height from stdlib ERB's (0 against 1), which is the whole
      # reason the offset is probed. Standing in an Erubi-shaped output pins the measurement itself.
      markers = (1..3).map { |n| " RIGOR_ERB_PROBE_#{n} ;" }
      erubi_shaped = "_buf = ::String.new;#{markers.join("\n")}\n_buf.to_s\n"
      allow(compiler).to receive(:compile_source).and_return(erubi_shaped)
      compiler.reset!

      expect(compiler.line_offset).to eq(0)
    ensure
      compiler.reset!
    end

    it "declines a compiler whose output does not step line for line" do
      allow(compiler).to receive(:compile_source).and_return("RIGOR_ERB_PROBE_1 RIGOR_ERB_PROBE_2\n")
      compiler.reset!

      expect(compiler.line_offset).to be_nil
    ensure
      compiler.reset!
    end

    it "never claims the empty (identity) map, so the compiled columns cannot leak" do
      _compiled, map = compiler.compile("<%= a %>\n")

      expect(map).not_to be_empty
    end
  end

  describe "naming and bindings" do
    subject(:views) { Rigor::Plugin::Actionpack::ViewUnits }

    it "drops the handler and keeps the format" do
      expect(views.logical_name("app/views/users/show.html.erb", ["app/views"])).to eq("users/show.html")
      expect(views.logical_name("app/views/users/_card.html.erb", ["app/views"])).to eq("users/_card.html")
      expect(views.logical_name("app/views/users/show.erb", ["app/views"])).to eq("users/show")
    end

    it "reads the Rails 7.1 strict-locals comment for the parameter names" do
      expect(views.strict_locals(VIEW_UNITS_CARD_ERB).keys).to eq(%w[user admin])
    end

    it "reads no locals from a template that declares none" do
      expect(views.strict_locals(VIEW_UNITS_SHOW_ERB)).to be_empty
    end
  end

  describe "the units reach the effect table" do
    it "keys each template as `view:<logical_name>` and traces it to the file the user wrote" do
      in_project do |runner, _result|
        expect(unit(runner, "view:users/show.html")).not_to be_nil
        expect(runner.effect_sources["view:users/_card.html"]).to eq(["app/views/users/_card.html.erb"])
      end
    end

    it "carries the partial's `@user.update` as `io.db.write`" do
      in_project do |runner, _result|
        entry = unit(runner, "view:users/_card.html")

        expect(entry.declared.to_a + entry.proven.to_a).to include("io.db.write")
      end
    end

    it "agrees between the fork pool and the sequential path" do
      sequential = nil
      pooled = nil
      in_project(workers: 0) { |runner, _r| sequential = runner.effect_table.map { |row| [row.key, row.proven.to_a] } }
      in_project(workers: 2) { |runner, _r| pooled = runner.effect_table.map { |row| [row.key, row.proven.to_a] } }

      expect(pooled).to eq(sequential)
    end
  end

  describe "the ivar seeds" do
    it "reaches a partial through its directory, because an ivar is not a local" do
      in_project do |runner, _result|
        # `@user` is assigned in a `before_action`, and the partial is not rendered by any action of its
        # own — if either half were missing the receiver would be `Dynamic` and no row would attribute.
        entry = unit(runner, "view:users/_card.html")

        expect(entry.declared.to_a + entry.proven.to_a).to include("io.db.write")
      end
    end

    it "refuses a nil-able producer, so no fold is licensed on a value that is nil at runtime" do
      expect(Rigor::Plugin::Actionpack::ViewAssigns::NON_NIL_PRODUCERS).not_to include(:find_by)
    end

    it "refuses a `find` or `create` that may return several records, which a class-name seed cannot spell" do
      # rigor-activerecord types `Widget.find(a, b)` as `Array[Widget]` in the controller (#1321); seeding
      # `"Widget"` would hand the template the element type for what is an Array at runtime. `@control`
      # proves the source parsed and the controller was recognised, so the refusals are not vacuous.
      seeds = build_assigns(<<~RUBY)
        class WidgetsController < ApplicationController
          def show(...)
            @control = Widget.find(params[:id])
            @two_ids = Widget.find(params[:a], params[:b])
            @id_list = Widget.find([1, 2])
            @splatted = Widget.find(*params[:ids])
            @forwarded = Widget.find(...)
            @keywords = Widget.find(id: 1)
            @keyword_splat = Widget.find(**opts)
            @blocked = Widget.find { |w| w.id == 1 }
            @id_and_block = Widget.find(params[:id]) { |w| w }
            @block_pass = Widget.find(params[:id], &blk)
            @no_id = Widget.find
            @created_list = Widget.create([{ name: "a" }, { name: "b" }])
            @created_splat = Widget.create!(*rows)
          end
        end
      RUBY

      expect(seeds).to eq("@control" => "Widget")
    end

    it "still seeds a `find` of one id and a `create` of one attribute hash as the model" do
      seeds = build_assigns(<<~RUBY)
        class WidgetsController < ApplicationController
          def show
            @by_param = Widget.find(params[:id])
            @by_literal = Widget.find(1)
            @created = Widget.create(name: "a")
            @created_bang = Widget.create!({ name: "b" })
            @built = Widget.new
          end
        end
      RUBY

      expect(seeds).to eq(
        "@by_param" => "Widget", "@by_literal" => "Widget", "@created" => "Widget",
        "@created_bang" => "Widget", "@built" => "Widget"
      )
    end

    it "refuses a conditional assignment and a conditional filter, for the same reason" do
      seeds = build_assigns(<<~RUBY)
        class WidgetsController < ApplicationController
          before_action :maybe_set, if: :signed_in?

          def show
            @definite = Widget.find(1)
            (@parenthesised = Widget.find(5))
            @branchy = Widget.find(2) if params[:pick]
            Widget.all.each { |w| @in_block = Widget.find(w.id) }
            begin
              @guarded = Widget.find(6)
            rescue StandardError
              nil
            end
          end

          def maybe_set
            @filtered = Widget.find(4)
          end
        end
      RUBY

      expect(seeds.keys).to eq(["@definite", "@parenthesised"])
    end

    it "refuses everything in an action a `rescue` can cut short" do
      # The assignment really is the first statement, and it really does run first — but if it RAISES
      # the rescue may render, and the template then reads an ivar that was never set. Both spellings
      # of the rescue are the same node.
      seeds = build_assigns(<<~RUBY)
        class WidgetsController < ApplicationController
          def show
            @rescued = Widget.find(1)
          rescue StandardError
            flash[:error] = 1
          end
        end
      RUBY

      expect(seeds).to be_empty
    end

    it "refuses the modifier-rescue form, including the template its fallback renders" do
      source = <<~RUBY
        class WidgetsController < ApplicationController
          def show
            @modifier = Widget.find(1) rescue render :missing
          end
        end
      RUBY

      expect(build_assigns(source)).to be_empty
      expect(build_assigns(source, template: "missing")).to be_empty
    end
  end

  describe "the per-unit rule posture" do
    it "reports no `call.*` inside a template by default" do
      in_project do |_runner, result|
        expect(result.diagnostics.select { |d| d.path.end_with?(".erb") }).to be_empty
      end
    end

    it "reports them at the template's own line, column 1, when the project opts in" do
      in_project(view_type_checks: true) do |_runner, result|
        finding = result.diagnostics.find { |d| d.rule == "call.undefined-method" && d.path.end_with?(".erb") }

        expect(finding).not_to be_nil
        expect([finding.path, finding.line, finding.column]).to eq(["app/views/users/show.html.erb", 4, 1])
      end
    end
  end

  describe "the effect-unit key" do
    it "spells the prefix the effects layer tests for" do
      # `Effects::MethodKey` repeats the prefix rather than requiring the plugin layer; the two have to
      # stay equal or a `view:` key stops being an `effects.envelopes:` subject, silently.
      expect(Rigor::Effects::MethodKey::TEMPLATE_UNIT_PREFIX).to eq(Rigor::Plugin::TemplateUnit::KEY_PREFIX)
    end

    it "is an envelope subject in its own right, not the class name its dot would split out" do
      expect(Rigor::Effects::MethodKey.owner("view:users/show.html")).to eq("view:users/show")
      expect(Rigor::Effects::MethodKey.envelope_owner("view:users/show.html")).to eq("view:users/show.html")
      expect(Rigor::Effects::MethodKey.envelope_owner("User#save")).to eq("User")
    end
  end

  describe "a `views:` envelope written against `effects.envelopes`" do
    it "holds a view unit to its bound and positions the finding in the template" do
      envelopes = [{ "match" => "app/views/**/*", "effect" => ["mutate.local"] }]
      in_project(envelopes: envelopes) do |_runner, result|
        finding = result.diagnostics.find { |d| d.rule == "effect.envelope-exceeded" && d.path.end_with?(".erb") }

        expect(finding).not_to be_nil
        expect(finding.path).to eq("app/views/users/_card.html.erb")
      end
    end
  end
end
