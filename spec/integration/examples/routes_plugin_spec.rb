# frozen_string_literal: true

# Integration spec for `examples/rigor-routes/`. Reference
# coverage for the v0.1.0 slice 2 (`Plugin::IoBoundary`) and
# slice 6 (`Plugin::Base.producer` / `#cache_for`) surfaces.

require "spec_helper"
require "fileutils"
require "tmpdir"

ROUTES_PLUGIN_LIB = File.expand_path("../../../examples/rigor-routes/lib", __dir__)
$LOAD_PATH.unshift(ROUTES_PLUGIN_LIB) unless $LOAD_PATH.include?(ROUTES_PLUGIN_LIB)
require "rigor-routes"

DEFAULT_ROUTES_YAML = <<~YAML
  - name: users
    method: GET
    path: /users
  - name: user
    method: GET
    path: /users/:id
  - name: edit_user
    method: GET
    path: /users/:id/edit
  - name: post_comment
    method: GET
    path: /posts/:post_id/comments/:id
YAML

RSpec.describe "examples/rigor-routes" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Routes }

  def run_routes(source, routes_yaml: DEFAULT_ROUTES_YAML, plugin_config: nil, cache_store: nil)
    plugin_entry = plugin_config ? { "gem" => "rigor-routes", "config" => plugin_config } : nil
    run_plugin(
      source: source,
      plugin_entry: plugin_entry,
      cache_store: cache_store,
      files: { "config/routes.yml" => routes_yaml }
    )
  end

  describe "recognised helpers" do
    it "annotates each *_path call with the route's METHOD + path" do
      diags = plugin_diagnostics(run_routes("users_path\n"))
      expect(diags.size).to eq(1)
      expect(diags.first.severity).to eq(:info)
      expect(diags.first.message).to eq("users_path → GET /users")
      expect(diags.first.qualified_rule).to eq("plugin.routes.path-helper")
    end

    it "recognises *_url helpers as the same routes" do
      diags = plugin_diagnostics(run_routes("users_url\n"))
      expect(diags.first.message).to eq("users_url → GET /users")
    end

    it "accepts the correct positional argument count" do
      diags = plugin_diagnostics(run_routes("user_path(123)\n"))
      info = diags.find { |d| d.rule == "path-helper" }
      expect(info).not_to be_nil
      expect(info.message).to eq("user_path → GET /users/:id")
    end

    it "accepts multi-placeholder helpers when arity matches" do
      diags = plugin_diagnostics(run_routes("post_comment_path(7, 42)\n"))
      info = diags.find { |d| d.rule == "path-helper" }
      expect(info.message).to eq("post_comment_path → GET /posts/:post_id/comments/:id")
    end
  end

  describe "unknown-route diagnostics" do
    it "errors on a typo without a close match" do
      diags = plugin_diagnostics(run_routes("widget_factory_path\n"))
      err = diags.find { |d| d.rule == "unknown-route" }
      expect(err.severity).to eq(:error)
      expect(err.message).to eq("no route helper `widget_factory_path`")
    end

    it "appends a Levenshtein-suggested name when one is close enough" do
      diags = plugin_diagnostics(run_routes("useres_path\n"))
      err = diags.find { |d| d.rule == "unknown-route" }
      expect(err.message).to eq("no route helper `useres_path` (did you mean `users_path`?)")
    end
  end

  describe "wrong-arity diagnostics" do
    it "errors when a helper requiring args is called bare" do
      diags = plugin_diagnostics(run_routes("user_path\n"))
      err = diags.find { |d| d.rule == "wrong-arity" }
      expect(err.severity).to eq(:error)
      expect(err.message).to eq("`user_path` expects 1 argument (:id), got 0")
    end

    it "errors when too many args are passed" do
      diags = plugin_diagnostics(run_routes("user_path(1, 2)\n"))
      err = diags.find { |d| d.rule == "wrong-arity" }
      expect(err.message).to eq("`user_path` expects 1 argument (:id), got 2")
    end

    it "lists every required placeholder in the message" do
      diags = plugin_diagnostics(run_routes("post_comment_path(7)\n"))
      err = diags.find { |d| d.rule == "wrong-arity" }
      expect(err.message).to eq(
        "`post_comment_path` expects 2 arguments (:post_id, :id), got 1"
      )
    end
  end

  describe "trust + caching surface (slice 2 + slice 6)" do
    let(:cache_root) { Dir.mktmpdir("rigor-routes-cache-") }
    let(:cache_store) { Rigor::Cache::Store.new(root: cache_root) }

    after { FileUtils.rm_rf(cache_root) }

    it "reads `config/routes.yml` via IoBoundary on first run and caches the parsed table" do
      result = run_routes("users_path\n", cache_store: cache_store)
      expect(plugin_diagnostics(result).first.message).to eq("users_path → GET /users")

      stats = cache_store.stats
      expect(stats[:by_producer]).to include("plugin.routes.route_table")
      expect(stats[:by_producer]["plugin.routes.route_table"][:writes]).to eq(1)
    end

    # The runner-internal plugin loader diffs the global
    # `Rigor::Plugin.registered` set across `require_gem!` to
    # discover newly-registered plugins. Two consecutive
    # `Runner.run` calls in the same test must therefore drop
    # the registry between them, so the requirer's
    # re-registration looks like a fresh registration to the
    # loader. `run_plugin_in_dir` does NOT auto-unregister on
    # entry (unlike `run_plugin`), so this helper handles the
    # lifecycle explicitly.
    def run_routes_in_dir_twice(dir, source:, routes_yaml: DEFAULT_ROUTES_YAML)
      results = []
      2.times do
        Rigor::Plugin.unregister!
        results << run_plugin_in_dir(
          dir: dir,
          source: source,
          cache_store: cache_store,
          files: { "config/routes.yml" => routes_yaml }
        )
      end
      results
    end

    it "hits the cache on a second run with the same routes.yml" do
      Dir.mktmpdir do |dir|
        run_routes_in_dir_twice(dir, source: "users_path\n")
      end

      stats = cache_store.stats[:by_producer]["plugin.routes.route_table"]
      expect(stats[:hits]).to be >= 1
      expect(stats[:writes]).to eq(1)
    end

    it "invalidates the cache when routes.yml content changes" do
      plugin_diags_v2 = nil

      Dir.mktmpdir do |dir|
        Rigor::Plugin.unregister!
        run_plugin_in_dir(
          dir: dir,
          source: "users_path\n",
          cache_store: cache_store,
          files: { "config/routes.yml" => DEFAULT_ROUTES_YAML }
        )

        Rigor::Plugin.unregister!
        result = run_plugin_in_dir(
          dir: dir,
          source: "people_path\n",
          cache_store: cache_store,
          files: { "config/routes.yml" => "- name: people\n  method: GET\n  path: /people\n" }
        )
        plugin_diags_v2 = plugin_diagnostics(result)
      end

      expect(plugin_diags_v2.first.message).to eq("people_path → GET /people")
      stats = cache_store.stats[:by_producer]["plugin.routes.route_table"]
      expect(stats[:writes]).to eq(2) # one per distinct routes.yml content
    end
  end

  describe "graceful failure modes" do
    it "warns once when the configured routes file does not exist" do
      result = run_plugin(source: "users_path\n")
      warning = result.diagnostics.find { |d| d.rule == "load-error" }
      expect(warning.severity).to eq(:warning)
      expect(warning.message).to include("config/routes.yml")
      expect(warning.message).to include("not found")
    end
  end
end
