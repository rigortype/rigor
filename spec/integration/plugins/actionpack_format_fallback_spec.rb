# frozen_string_literal: true

# #1065 — a `.js.erb` template rendering an HTML-only partial.
#
# #1048's `rails_render_partial` carries the format from the enclosing unit, so
# `render partial: "watchers/list"` inside `fallback.js.erb` names `view:watchers/_list.js`. Rails runs
# `_list.html.erb` there, because a `.js` template's lookup context is `[:js, :html]`; the edge used to
# resolve to nothing and the row's `template-not-analysed` taint was seeded back.
#
# The fallback is plugin DATA (`EffectAttribution#callee_fallbacks:`), copied onto the edge
# (`FileCollection::Edge#fallback_selectors`) and decided by the propagator, which is the only thing that
# can see whether `view:watchers/_list.js` exists.

require "spec_helper"
require "fileutils"
require "tmpdir"

FORMAT_FALLBACK_ACTIONPACK_LIB = File.expand_path("../../../plugins/rigor-actionpack/lib", __dir__)
FORMAT_FALLBACK_ACTIVERECORD_LIB = File.expand_path("../../../plugins/rigor-activerecord/lib", __dir__)
[FORMAT_FALLBACK_ACTIONPACK_LIB, FORMAT_FALLBACK_ACTIVERECORD_LIB].each do |lib|
  $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
end
require "rigor-actionpack"
require "rigor-activerecord"

FORMAT_FALLBACK_MODELS = <<~RUBY
  class ApplicationRecord < ActiveRecord::Base
  end

  class User < ApplicationRecord
  end
RUBY

FORMAT_FALLBACK_CONTROLLER = <<~RUBY
  class ApplicationController < ActionController::Base
  end

  class WatchersController < ApplicationController
    def toggle
      render :fallback, formats: [:js]
    end

    # Only `page.html.erb` exists. A controller-side render never falls back.
    def legacy
      render :page, formats: [:js]
    end
  end
RUBY

# The write the action has to inherit, through a `.js` template and an HTML-only partial.
FORMAT_FALLBACK_WRITE = <<~ERB
  <li><% User.create(name: "x") %></li>
ERB

FORMAT_FALLBACK_DESTROY = <<~ERB
  <li><% User.destroy_all %></li>
ERB

FORMAT_FALLBACK_READ = <<~ERB
  <li><%= User.count %></li>
ERB

FORMAT_FALLBACK_FILES = {
  "app/models/user.rb" => FORMAT_FALLBACK_MODELS,
  "app/controllers/watchers_controller.rb" => FORMAT_FALLBACK_CONTROLLER,
  "app/views/watchers/_list.html.erb" => FORMAT_FALLBACK_WRITE,
  "app/views/watchers/fallback.js.erb" =>
    %($('#w').html('<%= escape_javascript(render(partial: "watchers/list")) %>');\n),
  # Both formats exist: the `.js` partial is the one that runs, and the `.html` one must not join.
  "app/views/watchers/_shared.js.erb" => FORMAT_FALLBACK_READ,
  "app/views/watchers/_shared.html.erb" => FORMAT_FALLBACK_DESTROY,
  "app/views/watchers/both.js.erb" => %(<%= render "shared" %>\n),
  "app/views/watchers/missing.js.erb" => %(<%= render "nowhere" %>\n),
  "app/views/watchers/explicit.js.erb" => %(<%= render partial: "list", formats: [:js] %>\n),
  "app/views/watchers/spelled.js.erb" => %(<%= render "list.js" %>\n),
  # A `.json` template: its own partial wins, and no table entry sends it to `.html`.
  "app/views/watchers/_row.json.erb" => FORMAT_FALLBACK_READ,
  "app/views/watchers/_row.html.erb" => FORMAT_FALLBACK_DESTROY,
  "app/views/watchers/show.json.erb" => %(<%= render "row" %>\n),
  "app/views/watchers/index.json.erb" => %(<%= render "list" %>\n),
  "app/views/watchers/page.html.erb" => FORMAT_FALLBACK_WRITE
}.freeze

FORMAT_FALLBACK_VIEW_TAINT = ["template-not-analysed", "ActionView::Base#render"].freeze
FORMAT_FALLBACK_CONTROLLER_TAINT = ["template-not-analysed", "ActionController::Base#render"].freeze

RSpec.describe "plugins/rigor-actionpack — the `.js` → `.html` format fallback (#1065)" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  def in_project(workers: 0)
    Dir.mktmpdir("rigor-1065-") do |dir|
      FORMAT_FALLBACK_FILES.each do |relative, source|
        path = File.join(dir, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, source)
      end
      config = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          "paths" => ["app"], "plugins" => %w[rigor-activerecord rigor-actionpack], "effects" => {},
          "parallel" => { "workers" => workers }
        )
      )
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
    runner.effect_table.find { |row| row.key == key } or raise "no unit #{key}"
  end

  it "resolves a `.js` template's render of an HTML-only partial, and carries its labels up" do
    in_project do |runner, _result|
      template = unit(runner, "view:watchers/fallback.js")
      action = unit(runner, "WatchersController#toggle")

      aggregate_failures do
        expect(template.edges).to eq(["view:watchers/_list.html"])
        expect(template.causes).not_to include(FORMAT_FALLBACK_VIEW_TAINT)
        expect(template.declared.to_a).to include("io.db.write")
        expect(action.edges).to include("view:watchers/fallback.js")
        expect(action.declared.to_a).to include("io.db.write")
        expect(action.causes).not_to include(FORMAT_FALLBACK_VIEW_TAINT)
        expect(action.causes).not_to include(FORMAT_FALLBACK_CONTROLLER_TAINT)
      end
    end
  end

  it "prefers the partial in the template's own format, and joins only that one" do
    in_project do |runner, _result|
      entry = unit(runner, "view:watchers/both.js")

      aggregate_failures do
        expect(entry.edges).to eq(["view:watchers/_shared.js"])
        expect(entry.declared.to_a).not_to include("io.db.destroy")
      end
    end
  end

  it "keeps a `.json` template on its own `.json` partial where one exists" do
    in_project do |runner, _result|
      entry = unit(runner, "view:watchers/show.json")

      aggregate_failures do
        expect(entry.edges).to eq(["view:watchers/_row.json"])
        expect(entry.declared.to_a).not_to include("io.db.destroy")
        expect(entry.causes).not_to include(FORMAT_FALLBACK_VIEW_TAINT)
      end
    end
  end

  it "does not send a `.json` template to `.html`, which is a request's lookup rather than Action View's" do
    in_project do |runner, _result|
      entry = unit(runner, "view:watchers/index.json")

      aggregate_failures do
        expect(entry.edges).to be_empty
        expect(entry.causes).to include(FORMAT_FALLBACK_VIEW_TAINT)
      end
    end
  end

  it "keeps the taint when neither the requested nor the fallback format has a unit" do
    in_project do |runner, _result|
      entry = unit(runner, "view:watchers/missing.js")

      aggregate_failures do
        expect(entry.edges).to be_empty
        expect(entry.causes).to include(FORMAT_FALLBACK_VIEW_TAINT)
      end
    end
  end

  # One example each, so either guard regressing is independently red. Action View 8.1 would in fact
  # append `:html` to an explicit lone `formats: [:js]` too (`ActionView::Base#in_rendering_context`) —
  # unless the request already set `html_fallback_for_js`, in which case it ignores the option outright.
  # Which of the two runs is a request fact, so the rule keeps the taint rather than pick one.
  {
    "explicit" => "a `formats:` keyword",
    "spelled" => "a format spelled into the partial's name"
  }.each do |name, shape|
    it "stands down for #{shape}" do
      in_project do |runner, _result|
        entry = unit(runner, "view:watchers/#{name}.js")

        aggregate_failures do
          expect(entry.edges).to be_empty
          expect(entry.causes).to include(FORMAT_FALLBACK_VIEW_TAINT)
          expect(entry.declared.to_a).not_to include("io.db.write")
        end
      end
    end
  end

  it "never falls back on the controller side" do
    in_project do |runner, _result|
      entry = unit(runner, "WatchersController#legacy")

      aggregate_failures do
        expect(entry.edges).to be_empty
        expect(entry.causes).to include(FORMAT_FALLBACK_CONTROLLER_TAINT)
        expect(entry.declared.to_a).not_to include("io.db.write")
      end
    end
  end

  it "agrees pooled and sequential, edges and causes included" do
    rows = lambda do |runner|
      runner.effect_table.map { |row| [row.key, row.proven.to_a, row.declared.to_a, row.edges, row.causes] }
    end
    sequential = nil
    pooled = nil
    in_project(workers: 0) { |runner, _r| sequential = rows.call(runner) }
    in_project(workers: 2) { |runner, _r| pooled = rows.call(runner) }

    expect(sequential.map(&:first)).to include("view:watchers/fallback.js")
    expect(pooled).to eq(sequential)
  end
end
