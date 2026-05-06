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

RSpec.describe "examples/rigor-routes" do # rubocop:disable RSpec/DescribeClass
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Routes }
  let(:requirer) do
    lambda do |_name|
      Rigor::Plugin.register(plugin_class)
      true
    end
  end

  def materialize_project(dir, source:, routes_yaml: DEFAULT_ROUTES_YAML, plugin_config: nil)
    FileUtils.mkdir_p(File.join(dir, "config"))
    File.write(File.join(dir, "config", "routes.yml"), routes_yaml)
    File.write(File.join(dir, "demo.rb"), source)
    plugin_entry = plugin_config ? { "gem" => "rigor-routes", "config" => plugin_config } : "rigor-routes"
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => [File.join(dir, "demo.rb")],
        "plugins" => [plugin_entry]
      )
    )
  end

  def run_plugin(source, cache_store: nil, **)
    Dir.mktmpdir do |dir|
      configuration = materialize_project(dir, source: source, **)
      Dir.chdir(dir) do
        Rigor::Analysis::Runner.new(
          configuration: configuration,
          cache_store: cache_store,
          plugin_requirer: requirer
        ).run
      end
    end
  end

  def plugin_diagnostics(result)
    result.diagnostics.select { |d| d.source_family == "plugin.routes" }
  end

  describe "recognised helpers" do
    it "annotates each *_path call with the route's METHOD + path" do
      diags = plugin_diagnostics(run_plugin("users_path\n"))
      expect(diags.size).to eq(1)
      expect(diags.first.severity).to eq(:info)
      expect(diags.first.message).to eq("users_path → GET /users")
      expect(diags.first.qualified_rule).to eq("plugin.routes.path-helper")
    end

    it "recognises *_url helpers as the same routes" do
      diags = plugin_diagnostics(run_plugin("users_url\n"))
      expect(diags.first.message).to eq("users_url → GET /users")
    end

    it "accepts the correct positional argument count" do
      diags = plugin_diagnostics(run_plugin("user_path(123)\n"))
      info = diags.find { |d| d.rule == "path-helper" }
      expect(info).not_to be_nil
      expect(info.message).to eq("user_path → GET /users/:id")
    end

    it "accepts multi-placeholder helpers when arity matches" do
      diags = plugin_diagnostics(run_plugin("post_comment_path(7, 42)\n"))
      info = diags.find { |d| d.rule == "path-helper" }
      expect(info.message).to eq("post_comment_path → GET /posts/:post_id/comments/:id")
    end
  end

  describe "unknown-route diagnostics" do
    it "errors on a typo without a close match" do
      diags = plugin_diagnostics(run_plugin("widget_factory_path\n"))
      err = diags.find { |d| d.rule == "unknown-route" }
      expect(err.severity).to eq(:error)
      expect(err.message).to eq("no route helper `widget_factory_path`")
    end

    it "appends a Levenshtein-suggested name when one is close enough" do
      diags = plugin_diagnostics(run_plugin("useres_path\n"))
      err = diags.find { |d| d.rule == "unknown-route" }
      expect(err.message).to eq("no route helper `useres_path` (did you mean `users_path`?)")
    end
  end

  describe "wrong-arity diagnostics" do
    it "errors when a helper requiring args is called bare" do
      diags = plugin_diagnostics(run_plugin("user_path\n"))
      err = diags.find { |d| d.rule == "wrong-arity" }
      expect(err.severity).to eq(:error)
      expect(err.message).to eq("`user_path` expects 1 argument (:id), got 0")
    end

    it "errors when too many args are passed" do
      diags = plugin_diagnostics(run_plugin("user_path(1, 2)\n"))
      err = diags.find { |d| d.rule == "wrong-arity" }
      expect(err.message).to eq("`user_path` expects 1 argument (:id), got 2")
    end

    it "lists every required placeholder in the message" do
      diags = plugin_diagnostics(run_plugin("post_comment_path(7)\n"))
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
      result = run_plugin("users_path\n", cache_store: cache_store)
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
    # loader. The runner_spec helpers handle this implicitly
    # by re-creating the runner per test; here we are
    # exercising cache behaviour across runs, so the
    # before/after `unregister!` framing isn't enough.
    def run_twice(dir, configuration)
      results = []
      2.times do
        Rigor::Plugin.unregister!
        Dir.chdir(dir) do
          results << Rigor::Analysis::Runner.new(
            configuration: configuration,
            cache_store: cache_store,
            plugin_requirer: requirer
          ).run
        end
      end
      results
    end

    it "hits the cache on a second run with the same routes.yml" do
      Dir.mktmpdir do |dir|
        configuration = materialize_project(dir, source: "users_path\n")
        run_twice(dir, configuration)
      end

      stats = cache_store.stats[:by_producer]["plugin.routes.route_table"]
      expect(stats[:hits]).to be >= 1
      expect(stats[:writes]).to eq(1)
    end

    it "invalidates the cache when routes.yml content changes" do # rubocop:disable RSpec/ExampleLength
      plugin_diags_v2 = nil

      Dir.mktmpdir do |dir|
        configuration_v1 = materialize_project(dir, source: "users_path\n")
        Rigor::Plugin.unregister!
        Dir.chdir(dir) do
          Rigor::Analysis::Runner.new(
            configuration: configuration_v1,
            cache_store: cache_store,
            plugin_requirer: requirer
          ).run
        end

        Rigor::Plugin.unregister!
        configuration_v2 = materialize_project(
          dir,
          source: "people_path\n",
          routes_yaml: "- name: people\n  method: GET\n  path: /people\n"
        )
        result = Dir.chdir(dir) do
          Rigor::Analysis::Runner.new(
            configuration: configuration_v2,
            cache_store: cache_store,
            plugin_requirer: requirer
          ).run
        end
        plugin_diags_v2 = result.diagnostics.select { |d| d.source_family == "plugin.routes" }
      end

      expect(plugin_diags_v2.first.message).to eq("people_path → GET /people")
      stats = cache_store.stats[:by_producer]["plugin.routes.route_table"]
      expect(stats[:writes]).to eq(2) # one per distinct routes.yml content
    end
  end

  describe "graceful failure modes" do
    def run_without_routes_file
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "demo.rb"), "users_path\n")
        configuration = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge(
            "paths" => [File.join(dir, "demo.rb")],
            "plugins" => ["rigor-routes"]
          )
        )
        Dir.chdir(dir) do
          Rigor::Analysis::Runner.new(
            configuration: configuration,
            cache_store: nil,
            plugin_requirer: requirer
          ).run
        end
      end
    end

    it "warns once when the configured routes file does not exist" do
      warning = run_without_routes_file.diagnostics.find { |d| d.rule == "load-error" }
      expect(warning.severity).to eq(:warning)
      expect(warning.message).to include("config/routes.yml")
      expect(warning.message).to include("not found")
    end
  end
end
