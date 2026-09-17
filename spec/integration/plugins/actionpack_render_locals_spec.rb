# frozen_string_literal: true

# #1047 — the two bindings #393 and #1048 left out, which are one piece of work seen from two sides.
#
# **Render-site `locals:`.** A partial's parameters are bound by whoever renders it, and until now only
# the Rails 7.1 strict-locals comment said so. The measured cost was three `flow.always-truthy-condition`
# false positives on redmine's `app/views/common/_other.html.erb`, whose optional-local preamble
# (`<% path = nil unless defined? path %>`) really does assign nil in the compiled Ruby — so `flow.` sat
# in the plugin's default suppressed set for that reason alone. `RenderLocals` reads every render site,
# on both sides of the render, and the suppression goes with it.
#
# **Layouts.** `<%= yield %>` is legal ERB and illegal Ruby outside a method, so every layout's compiled
# body failed to parse and the file was declined. `ErbCompiler` rewrites the keyword into a call on the
# synthesised view context, which is a rewrite of the TEMPLATE rather than of the seam (the seam
# deliberately does not wrap a body in a method — `macro-substrate.md` § Positions).

require "spec_helper"
require "fileutils"
require "tmpdir"

RENDER_LOCALS_ACTIONPACK_LIB = File.expand_path("../../../plugins/rigor-actionpack/lib", __dir__)
RENDER_LOCALS_ACTIVERECORD_LIB = File.expand_path("../../../plugins/rigor-activerecord/lib", __dir__)
$LOAD_PATH.unshift(RENDER_LOCALS_ACTIONPACK_LIB) unless $LOAD_PATH.include?(RENDER_LOCALS_ACTIONPACK_LIB)
$LOAD_PATH.unshift(RENDER_LOCALS_ACTIVERECORD_LIB) unless $LOAD_PATH.include?(RENDER_LOCALS_ACTIVERECORD_LIB)
require "rigor-actionpack"
require "rigor-activerecord"

# The two calls the parent-side builders make on the plugin IO boundary.
RENDER_LOCALS_BOUNDARY = Struct.new(:root) do
  def directory?(path) = File.directory?(path)
  def read_file(path) = File.read(path)
end

RENDER_LOCALS_MODELS = <<~RUBY
  class ApplicationRecord < ActiveRecord::Base
  end

  class User < ApplicationRecord
  end

  class Post < ApplicationRecord
  end
RUBY

RSpec.describe "plugins/rigor-actionpack — render-site locals and layouts (#1047)" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  # Builds the `RenderLocals` index over an ad-hoc tree of controllers and views, and answers what it
  # seeded for one template. `files` is `{ "app/views/users/show.html.erb" => "…" }`.
  def index_for(files)
    Dir.mktmpdir("rigor-1047-") do |dir|
      files.each do |relative, contents|
        FileUtils.mkdir_p(File.join(dir, File.dirname(relative)))
        File.write(File.join(dir, relative), contents)
      end
      Dir.chdir(dir) do
        boundary = RENDER_LOCALS_BOUNDARY.new(dir)
        assigns = Rigor::Plugin::Actionpack::ViewAssigns::Builder.new(
          io_boundary: boundary, search_paths: ["app/controllers"]
        ).build
        yield Rigor::Plugin::Actionpack::RenderLocals::Builder.new(
          io_boundary: boundary, controller_search_paths: ["app/controllers"],
          view_search_paths: ["app/views"], view_assigns: assigns
        ).build
      end
    end
  end

  def seeds(files, template)
    index_for(files) { |index| return index.seeds_for(template) }
  end

  def dynamic
    Rigor::Plugin::Actionpack::ViewUnits::UNKNOWN_LOCAL
  end

  describe "a render site names the partial's locals" do
    it "reads the keyword form, and types a name the site could settle" do
      result = seeds(
        {
          "app/views/users/show.html.erb" =>
            %(<%= render partial: "card", locals: { user: User.find(1), tone: params[:tone] } %>\n),
          "app/views/users/_card.html.erb" => "<p><%= user %><%= tone %></p>\n"
        }, "users/_card.html"
      )

      expect(result).to eq("user" => "User", "tone" => dynamic)
    end

    it "reads the hashrocket spelling, which is what the corpus actually writes" do
      result = seeds(
        {
          "app/views/repositories/entry.html.erb" =>
            %(<%= render :partial => 'common/other', :locals => { :path => @raw_url, :kind => kind } %>\n),
          "app/views/common/_other.html.erb" => "<% if path.present? %><%= kind %><% end %>\n"
        }, "common/_other.html"
      )

      expect(result.keys).to contain_exactly("path", "kind")
    end

    it "reads the positional-hash form, which is locals in a view" do
      result = seeds(
        {
          "app/views/users/show.html.erb" => %(<%= render "card", user: @user, size: :md %>\n),
          "app/views/users/_card.html.erb" => "<p><%= user %><%= size %></p>\n"
        }, "users/_card.html"
      )

      expect(result.keys).to contain_exactly("user", "size")
    end

    it "does NOT read the same shape in a controller, where a trailing hash is options" do
      # `render :show, status: :ok` passes no locals at all. Reading the controller's hash as a view's
      # would seed a `status` local for every one of them in the corpus.
      result = seeds(
        {
          "app/controllers/users_controller.rb" => <<~RUBY,
            class UsersController < ApplicationController
              def show
                render :show, status: :ok
              end
            end
          RUBY
          "app/views/users/show.html.erb" => "<p>hi</p>\n"
        }, "users/show.html"
      )

      expect(result).to eq({})
    end

    it "reads a controller-side `partial:` render, which does pass locals" do
      result = seeds(
        {
          "app/controllers/users_controller.rb" => <<~RUBY,
            class UsersController < ApplicationController
              def show
                @user = User.find(params[:id])
                render partial: "card", locals: { user: @user }
              end
            end
          RUBY
          "app/views/users/_card.html.erb" => "<p><%= user %></p>\n"
        }, "users/_card.html"
      )

      expect(result).to eq("user" => "User")
    end
  end

  describe "the union across render sites" do
    # This is the redmine `common/_other.html.erb` shape reduced: three sites, one of which passes
    # nothing. A name absent from the union is what produced the false positives.
    let(:three_sites) do
      {
        "app/views/repositories/entry.html.erb" =>
          %(<%= render :partial => 'common/other', :locals => { :path => @raw_url, :kind => k } %>\n),
        "app/views/attachments/other.html.erb" =>
          %(<%= render :partial => "common/other", :locals => { :kind => k } %>\n),
        "app/views/common/_pdf.html.erb" => %(<%= render :partial => 'common/other' %>\n),
        "app/views/common/_other.html.erb" => "<% path = nil unless defined? path %>\n"
      }
    end

    it "seeds a name bound at only some sites, rather than leaving it absent" do
      expect(seeds(three_sites, "common/_other.html").keys).to contain_exactly("path", "kind")
    end

    it "types such a name `Dynamic`, because the site that skipped it settled nothing" do
      expect(seeds(three_sites, "common/_other.html")).to eq("path" => dynamic, "kind" => dynamic)
    end

    it "drops a type two sites disagree about" do
      result = seeds(
        {
          "app/views/users/show.html.erb" => %(<%= render partial: "card", locals: { it: User.find(1) } %>\n),
          "app/views/users/edit.html.erb" => %(<%= render partial: "card", locals: { it: Post.new } %>\n),
          "app/views/users/_card.html.erb" => "<p><%= it %></p>\n"
        }, "users/_card.html"
      )

      expect(result).to eq("it" => dynamic)
    end

    it "keeps a type every site agrees on" do
      result = seeds(
        {
          "app/views/users/show.html.erb" => %(<%= render partial: "card", locals: { it: User.find(1) } %>\n),
          "app/views/users/edit.html.erb" => %(<%= render partial: "card", locals: { it: User.new } %>\n),
          "app/views/users/_card.html.erb" => "<p><%= it %></p>\n"
        }, "users/_card.html"
      )

      expect(result).to eq("it" => "User")
    end
  end

  describe "`collection:`, `object:` and `as:`" do
    it "binds the partial's own name plus the counter and iteration companions" do
      result = seeds(
        {
          "app/views/users/index.html.erb" => %(<%= render partial: "card", collection: @users %>\n),
          "app/views/users/_card.html.erb" => "<p><%= card %> <%= card_counter %></p>\n"
        }, "users/_card.html"
      )

      expect(result.keys).to contain_exactly("card", "card_counter", "card_iteration")
    end

    it "never types a collection's element, which nothing at the site names" do
      result = seeds(
        {
          "app/views/users/index.html.erb" => %(<%= render partial: "card", collection: User.find(1) %>\n),
          "app/views/users/_card.html.erb" => "<p><%= card %></p>\n"
        }, "users/_card.html"
      )

      expect(result["card"]).to eq(dynamic)
    end

    it "renames the local when `as:` says so" do
      result = seeds(
        {
          "app/views/users/index.html.erb" => %(<%= render partial: "card", collection: @users, as: :row %>\n),
          "app/views/users/_card.html.erb" => "<p><%= row %></p>\n"
        }, "users/_card.html"
      )

      expect(result.keys).to contain_exactly("row", "row_counter", "row_iteration")
    end

    it "types an `object:` the site could settle" do
      result = seeds(
        {
          "app/views/users/show.html.erb" => %(<%= render partial: "card", object: User.find(1) %>\n),
          "app/views/users/_card.html.erb" => "<p><%= card %></p>\n"
        }, "users/_card.html"
      )

      expect(result).to eq("card" => "User")
    end
  end

  describe "the false positive the suppression stood in for" do
    it "reports no `flow.` finding on the optional-local preamble, with `flow.` reporting by default" do
      diagnostics = run_project(
        {
          "app/views/repositories/entry.html.erb" =>
            %(<%= render :partial => 'common/other', :locals => { :path => @raw_url, :kind => k } %>\n),
          "app/views/common/_other.html.erb" => <<~ERB
            <% kind = nil unless defined? kind %>
            <% path = nil unless defined? path %>
            <% if path.present? %>
              <p><%= kind %></p>
            <% end %>
          ERB
        }
      )

      expect(diagnostics.map(&:rule).grep(/\Aflow\./)).to be_empty
    end

    it "no longer suppresses the family at all" do
      expect(Rigor::Plugin::Actionpack::SUPPRESSED_VIEW_RULES).to eq(["call."])
    end

    it "still reports a `flow.` finding a template really earns" do
      diagnostics = run_project(
        {
          "app/views/users/show.html.erb" => <<~ERB
            <% seen = nil %>
            <% if seen %>
              <p>never</p>
            <% end %>
          ERB
        }
      )

      expect(diagnostics.map(&:rule).grep(/\Aflow\./)).not_to be_empty
    end
  end

  describe "the layout `yield` rewrite" do
    subject(:compiler) { Rigor::Plugin::Actionpack::ErbCompiler }

    it "compiles a layout that used to be declined outright" do
      source = "<html><body>\n<%= yield %>\n<%= yield :sidebar %>\n</body></html>\n"
      compiled, map = compiler.compile(source)

      expect(Prism.parse(compiled).errors).to be_empty
      expect(map.values).to eq((1..4).to_a)
    end

    it "leaves the keyword alone outside an ERB tag" do
      compiled, = compiler.compile("<p>the yield of this crop</p>\n")

      expect(compiled).to include("the yield of this crop")
      expect(compiled).not_to include(Rigor::Plugin::Actionpack::ErbCompiler::YIELD_METHOD)
    end

    it "leaves an identifier that merely contains the keyword alone" do
      compiled, = compiler.compile("<%= yielding %><%= x.yield_value %>\n")

      expect(compiled).not_to include(Rigor::Plugin::Actionpack::ErbCompiler::YIELD_METHOD)
    end

    it "declares the rewritten call on the view context, returning a lenient String" do
      rbs = File.read(File.expand_path("../../../plugins/rigor-actionpack/sig/action_view.rbs", __dir__))

      expect(rbs).to include("def #{Rigor::Plugin::Actionpack::ErbCompiler::YIELD_METHOD}: (*untyped) -> String")
    end
  end

  describe "a layout is a unit, and the edge reaches it" do
    let(:layout_project) do
      {
        "app/controllers/users_controller.rb" => <<~RUBY,
          class UsersController < ApplicationController
            def show
              @user = User.find(params[:id])
            end
          end
        RUBY
        "app/views/layouts/application.html.erb" => <<~ERB,
          <html><body>
          <% User.find(1).update(seen_at: Time.now) %>
          <%= yield %>
          </body></html>
        ERB
        "app/views/users/show.html.erb" => %(<%= render layout: "layouts/wrapper" do %><p>hi</p><% end %>\n),
        "app/views/layouts/_wrapper.html.erb" => "<div><%= yield %></div>\n"
      }
    end

    it "puts `view:layouts/application.html` in the effect table" do
      in_project(layout_project) do |runner, _diagnostics|
        expect(unit(runner, "view:layouts/application.html")).not_to be_nil
      end
    end

    it "carries the layout's own effects, which used to reach nothing" do
      in_project(layout_project) do |runner, _diagnostics|
        entry = unit(runner, "view:layouts/application.html")

        expect(entry.declared.to_a + entry.proven.to_a).to include("io.db.write")
      end
    end

    it "discharges the `template-not-analysed` taint on a view-side `render layout:`" do
      in_project(layout_project) do |runner, _diagnostics|
        causes = unit(runner, "view:users/show.html")&.causes || []

        expect(causes.map(&:first)).not_to include("template-not-analysed")
      end
    end

    it "seeds nothing of its own for what `yield` returned" do
      # The rewrite's whole restraint: the call is declared `-> String` in the bundled RBS and nothing
      # about the inner template's buffer is claimed, so the layout unit carries no local and no ivar
      # seed standing in for the rendered body.
      plugin = Rigor::Plugin::Actionpack.new(services: nil, config: {})
      plugin.init(nil)
      units = plugin.template_units_for_file(
        path: "app/views/layouts/application.html.erb", source: "<html><%= yield %></html>\n"
      )

      expect(units.length).to eq(1)
      expect(units.first.locals).to be_empty
      expect(units.first.ivar_seeds).to be_empty
    end
  end

  describe "determinism" do
    it "agrees between the fork pool and the sequential path" do
      files = {
        "app/views/users/show.html.erb" => %(<%= render partial: "card", locals: { user: User.find(1) } %>\n),
        "app/views/users/_card.html.erb" => "<% user.update(seen_at: Time.now) %>\n",
        "app/views/layouts/application.html.erb" => "<html><%= yield %></html>\n"
      }
      sequential = nil
      pooled = nil
      in_project(files, workers: 0) { |runner, _d| sequential = runner.effect_table.map { |r| [r.key, r.proven.to_a] } }
      in_project(files, workers: 2) { |runner, _d| pooled = runner.effect_table.map { |r| [r.key, r.proven.to_a] } }

      expect(pooled).to eq(sequential)
    end
  end

  # ---- harness -------------------------------------------------------------------------------------

  def unit(runner, key)
    runner.effect_table.find { |row| row.key == key }
  end

  def run_project(files, workers: 0)
    in_project(files, workers: workers) { |_runner, result| return result.diagnostics }
  end

  def in_project(files, workers: 0)
    Dir.mktmpdir("rigor-1047-run-") do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      File.write(File.join(dir, "app", "models", "user.rb"), RENDER_LOCALS_MODELS)
      files.each do |relative, contents|
        FileUtils.mkdir_p(File.join(dir, File.dirname(relative)))
        File.write(File.join(dir, relative), contents)
      end
      Dir.chdir(dir) do
        runner = build_runner(workers)
        yield runner, guarded_run(runner, ["app"])
      end
    end
  end

  def build_runner(workers)
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => ["app"], "plugins" => %w[rigor-activerecord rigor-actionpack],
        "effects" => { "enabled" => true }, "parallel" => { "workers" => workers }
      )
    )
    Rigor::Analysis::Runner.new(
      configuration: configuration, cache_store: nil,
      plugin_requirer: lambda do |name|
        case File.basename(name, ".rb")
        when "rigor-actionpack" then Rigor::Plugin.register(Rigor::Plugin::Actionpack)
        when "rigor-activerecord" then Rigor::Plugin.register(Rigor::Plugin::Activerecord)
        end
        true
      end
    )
  end
end
