# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "rigor/cli/check_command"
require "rigor/cli/effects_command"

%w[rigor-actionpack rigor-activejob].each do |gem_name|
  lib = File.expand_path("../../plugins/#{gem_name}/lib", __dir__)
  $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
  require gem_name
end

# Issue #1803, the rigor-actionpack and rigor-activejob sites. Every row changes a file no run analyses and
# compares each cached mode with `--no-cache`: the plain run-result entry, the `--incremental` slot, and a
# `--workers 2` run.
RSpec.describe "run-result caches over the Rails plugins' project indexes (#1803)" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  around do |example|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
  end

  def check(*flags)
    out = StringIO.new
    argv = ["--no-ci-detect", "--no-stats", "--no-baseline", "--format", "json", *flags]
    Rigor::CLI::CheckCommand.new(argv: argv, out: out, err: StringIO.new).run
    out.string
  end

  def rules(json)
    JSON.parse(json).fetch("diagnostics").map do |diagnostic|
      "#{File.basename(diagnostic.fetch('path'))} #{diagnostic.fetch('rule')}"
    end.sort
  end

  def prime
    2.times { check("--incremental") }
    2.times { check }
  end

  def expect_caches_to_match_cold(expected)
    cold = rules(check("--no-cache"))
    expect(cold).to eq(expected)
    expect(rules(check("--incremental"))).to eq(cold)
    expect(rules(check)).to eq(cold)
    expect(rules(check("--workers", "2"))).to eq(cold)
  end

  def write(path, contents)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
  end

  # Only `app/views` is analysed, so a helper, a controller, or a template under the second view root reaches a
  # run through the plugin's render-locals and view-assigns indexes alone.
  describe "rigor-actionpack's template indexes" do
    let(:helper) { "app/helpers/application_helper.rb" }
    let(:folded) { ["_nav.html.erb flow.always-truthy-condition"] }

    before do
      Rigor::Plugin.register(Rigor::Plugin::Actionpack)
      write(".rigor.yml", <<~YAML)
        paths:
          - app/views
        plugins:
          - gem: rigor-actionpack
            id: actionpack
            config:
              view_type_checks: true
              view_search_paths: ["app/views", "app/shared_views"]
      YAML
      # `defined?` names a helper when one defines `current_user`, and declares an optional local otherwise; as
      # a helper the preamble assigns nil, and the condition after it folds.
      write("app/views/shared/_nav.html.erb", <<~ERB)
        <% current_user = nil unless defined?(current_user) %>
        <% if current_user %>on<% end %>
      ERB
      write("app/views/users/_card.html.erb", "<%= n.bogus_n %>\n<%= @m.bogus_m %>\n")
      FileUtils.mkdir_p("app/shared_views")
    end

    def define_helper(name)
      write(helper, "module ApplicationHelper\n  def #{name}\n    nil\n  end\nend\n")
    end

    # The directory exists at the primed run: a missing one is an absence row of its own, which the new file
    # moves without any listing row.
    it "drops every cache once a helper appears under app/helpers" do
      FileUtils.mkdir_p("app/helpers")
      prime
      define_helper("current_user")

      expect_caches_to_match_cold(folded)
    end

    it "drops every cache once a helper stops defining the name" do
      define_helper("current_user")
      prime
      define_helper("other")

      expect_caches_to_match_cold([])
    end

    it "drops every cache once the helper file is removed" do
      define_helper("current_user")
      prime
      File.delete(helper)

      expect_caches_to_match_cold([])
    end

    it "drops every cache once a helper appears under a symlinked app/helpers" do
      FileUtils.mkdir_p("vendor/helpers")
      File.symlink("../vendor/helpers", "app/helpers")
      prime
      write("vendor/helpers/application_helper.rb", "module ApplicationHelper\n  def current_user = nil\nend\n")

      expect_caches_to_match_cold(folded)
    end

    # The second view root is no template glob's, so its templates are read for their render sites only.
    context "with a render site under a view root no template glob claims" do
      let(:site) { "app/shared_views/x.html.erb" }
      let(:typed) { ["_card.html.erb call.undefined-method"] }

      it "drops every cache once the template appears" do
        prime
        write(site, %(<%= render "users/card", n: String.new %>\n))

        expect_caches_to_match_cold(typed)
      end

      it "drops every cache once the template stops passing the local" do
        write(site, %(<%= render "users/card", n: String.new %>\n))
        prime
        write(site, "<p>x</p>\n")

        expect_caches_to_match_cold([])
      end

      it "drops every cache once the template is removed" do
        write(site, %(<%= render "users/card", n: String.new %>\n))
        prime
        File.delete(site)

        expect_caches_to_match_cold([])
      end
    end

    # Guard: the view-assigns walk lists the controller roots, which the `:controller_index` producer's `watch:`
    # glob already records on every run, so this row held before #1803's fix.
    it "drops every cache once a controller assigns the ivar" do
      prime
      write("app/controllers/users_controller.rb",
            "class UsersController < ApplicationController\n  def show\n    @m = String.new\n  end\nend\n")
      write("app/views/users/show.html.erb", "<%= @m.bogus_m %>\n")

      expect_caches_to_match_cold(["_card.html.erb call.undefined-method", "show.html.erb call.undefined-method"])
    end
  end

  # Guard: the queue adapter shapes rigor-activejob's effect attributions and edges, which `init` builds, so it
  # reaches every cache through `Effects::PluginFacts#digest`, recomputed on each run; this row held before
  # #1803's fix.
  describe "rigor-activejob's queue adapter" do
    let(:environment) { "config/environments/development.rb" }

    def effects
      out = StringIO.new
      Rigor::CLI::EffectsCommand.new(argv: [], out: out, err: StringIO.new).run
      out.string.lines.grep(/\ASvc#go:/).join
    end

    def cold_effects
      FileUtils.mv(".rigor", ".rigor-held")
      effects
    ensure
      FileUtils.rm_rf(".rigor")
      FileUtils.mv(".rigor-held", ".rigor")
    end

    before do
      Rigor::Plugin.register(Rigor::Plugin::Activejob)
      write(".rigor.yml", <<~YAML)
        paths:
          - app
        plugins:
          - gem: rigor-activejob
            id: activejob
        effects:
          envelopes:
            - match: "app/models/**/*.rb"
              effect: []
      YAML
      write("app/jobs/w_job.rb", <<~RUBY)
        class ApplicationJob < ActiveJob::Base
        end

        class WJob < ApplicationJob
          def perform(path)
            File.read(path)
          end
        end
      RUBY
      write("app/models/svc.rb", "class Svc\n  def go\n    WJob.perform_later(\"x\")\n  end\nend\n")
    end

    def adapt(name)
      write(environment, "Rails.application.configure do\n  config.active_job.queue_adapter = :#{name}\nend\n")
    end

    def prime_all
      prime
      2.times { effects }
    end

    it "re-reads an environment file that appears, in check and in rigor effects" do
      prime_all
      adapt("inline")

      expect_caches_to_match_cold(["svc.rb effect.envelope-exceeded", "svc.rb job-call"])
      expect(effects).to include("[io.fs.read]").and eq(cold_effects)
    end

    it "re-reads an environment file that is edited or removed" do
      adapt("inline")
      prime_all
      adapt("sidekiq")

      expect_caches_to_match_cold(["svc.rb job-call"])
      expect(effects).to include("io.net").and eq(cold_effects)

      prime_all
      File.delete(environment)

      expect(effects).to include("[io,").and eq(cold_effects)
    end
  end
end
