# frozen_string_literal: true

# ADR-102 WD3 / #350 — what each bundled plugin contributes to `rigor unused`, end to end through the real
# protocol: a materialised project, the real plugin class, `PluginRoots.collect`, and the real {Graph}.
#
# The file is organised around one asymmetry, restated from ADR-102 § Consequences because it is the reason
# most of these plugins contribute NOTHING:
#
# > a root source that over-supplies silently hides real dead code, which is worse than one that
# > under-supplies.
#
# So every "it contributes X" example here is paired with a control showing what it does NOT contribute —
# an orphan policy stays a candidate, a factoried class stays out of production reachability — and the
# declining plugins get explicit examples rather than an absence of examples, because "nobody wrote a test"
# and "we decided not to" are indistinguishable in a diff a year from now.

require "spec_helper"

require "fileutils"
require "tmpdir"

require "rigor/analysis/reachability/graph"
require "rigor/analysis/reachability/plugin_roots"
require "rigor/analysis/reachability/scan"

%w[pundit factorybot sidekiq rspec rspec-rails activejob actionmailer].each do |gem_name|
  lib = File.expand_path("../../../plugins/rigor-#{gem_name}/lib", __dir__)
  $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
  require "rigor-#{gem_name}"
end

REACHABILITY_PLUGIN_CLASSES = {
  "rigor-pundit" => "Rigor::Plugin::Pundit",
  "rigor-factorybot" => "Rigor::Plugin::Factorybot",
  "rigor-sidekiq" => "Rigor::Plugin::Sidekiq",
  "rigor-rspec" => "Rigor::Plugin::Rspec",
  "rigor-rspec-rails" => "Rigor::Plugin::RspecRails",
  "rigor-activejob" => "Rigor::Plugin::Activejob",
  "rigor-actionmailer" => "Rigor::Plugin::Actionmailer"
}.freeze

RSpec.describe "plugin contributions to `rigor unused`" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  # Materialises `files` in a tmpdir and runs the real collection pass from inside it — the plugins resolve
  # their search paths against the working directory, exactly as they do under `rigor unused`.
  def collect_in(gem_name, files)
    Dir.mktmpdir do |dir|
      files.each do |relative, contents|
        full = File.join(dir, relative)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, contents)
      end
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => [dir], "plugins" => [gem_name])
      )
      # The loader hands the requirer a resolved path, not the gem name, so the class comes from the
      # closure — the same shape `PluginHelpers#build_plugin_requirer` uses.
      plugin_class = Object.const_get(REACHABILITY_PLUGIN_CLASSES.fetch(gem_name))
      loaded = false
      Dir.chdir(dir) do
        contribution = Rigor::Analysis::Reachability::PluginRoots.collect(
          configuration: configuration,
          plugin_requirer: lambda do |_name|
            loaded = true
            Rigor::Plugin.register(plugin_class)
            true
          end
        )
        # `PluginRoots.collect` is fail-soft by design: it swallows every error and returns an empty
        # contribution. That makes "contributes nothing" and "never ran" identical from outside, so every
        # example in this file — the declines above all — would pass vacuously if the plugin failed to load.
        # This is the harness saying "yes, it ran".
        expect(loaded).to be(true), "#{gem_name} was never required: the contribution is empty for the " \
                                    "wrong reason"
        yield(contribution, dir)
      end
    end
  end

  # The report the CLI builds, minus the CLI: declarations and references from the fixture files, plus the
  # plugin's contribution threaded in the two ways `UnusedCommand#run` threads it.
  def report_for(dir, files, contribution)
    declarations = []
    references = []
    files.each_key do |relative|
      result = Rigor::Analysis::Reachability::Scan.call(path: relative,
                                                        source: File.read(File.join(dir, relative)))
      next if result.nil?

      declarations.concat(result.declarations)
      references.concat(result.references)
    end
    references.concat(contribution.references.map do |reference|
      Rigor::Analysis::Reachability::Scan::Reference.new(as_written: reference.name, nesting: [].freeze,
                                                         from: nil, role: reference.role, path: "(plugin)", line: 1)
    end)
    Rigor::Analysis::Reachability::Graph.new(declarations: declarations, references: references,
                                             root_fqns: contribution.roots).report
  end

  describe "rigor-pundit — supplies roots" do
    # `authorize @post` reaches `PostPolicy` by a name that appears nowhere in the source. `OrphanPolicy` is
    # the control: it sits in the same directory, under the same base class, and nothing authorizes against
    # it. A root source that published `policy_search_paths` wholesale would claim both.
    let(:files) do
      {
        "app/policies/application_policy.rb" => "class ApplicationPolicy\nend\n",
        "app/policies/post_policy.rb" => "class PostPolicy < ApplicationPolicy\n  def update? = true\nend\n",
        "app/policies/orphan_policy.rb" => "class OrphanPolicy < ApplicationPolicy\n  def show? = true\nend\n",
        "app/controllers/posts_controller.rb" =>
          "class PostsController\n  def update\n    @post = nil\n    authorize @post\n  end\nend\n"
      }
    end

    it "publishes only the policy an authorization call names" do
      collect_in("rigor-pundit", files) do |contribution, _dir|
        expect(contribution.roots).to eq(["PostPolicy"])
        expect(contribution.references).to be_empty
      end
    end

    it "takes the named policy out of the candidate list and leaves the orphan in it" do
      collect_in("rigor-pundit", files) do |contribution, dir|
        report = report_for(dir, files, contribution)

        expect(report.candidates.map(&:fqn)).to include("OrphanPolicy")
        expect(report.candidates.map(&:fqn)).not_to include("PostPolicy")
      end
    end

    # Without the plugin the same project reports the live policy as dead — the state this slice exists to
    # fix, and the proof that the example above is not passing for some unrelated reason.
    it "is what makes the difference: with no contribution the live policy is a candidate" do
      collect_in("rigor-pundit", files) do |_contribution, dir|
        empty = Rigor::Analysis::Reachability::PluginRoots::Contribution.empty
        expect(report_for(dir, files, empty).candidates.map(&:fqn)).to include("PostPolicy")
      end
    end

    it "recognises a constant record as well as a convention-named one" do
      files = {
        "app/policies/application_policy.rb" => "class ApplicationPolicy\nend\n",
        "app/policies/widget_policy.rb" => "class WidgetPolicy < ApplicationPolicy\n  def index? = true\nend\n",
        "app/controllers/widgets_controller.rb" =>
          "class WidgetsController\n  def index\n    policy_scope(Widget.all)\n  end\nend\n"
      }
      collect_in("rigor-pundit", files) { |contribution, _dir| expect(contribution.roots).to eq(["WidgetPolicy"]) }
    end
  end

  describe "rigor-factorybot — supplies test-role references, not roots" do
    # `class: "Admin::User"` is a string: the constant scan cannot see it, so `Admin::User` reads as dead
    # without the plugin. But the naming happens in the test tree, so it must not become a production root.
    let(:files) do
      {
        "app/models/admin/user.rb" => "module Admin\n  class User\n  end\nend\n",
        "spec/factories/users.rb" => <<~RUBY
          FactoryBot.define do
            factory :user, class: "Admin::User" do
              name { "x" }
            end
          end
        RUBY
      }
    end

    it "publishes the factory's model class as a `:test`-role reference and roots nothing" do
      collect_in("rigor-factorybot", files) do |contribution, _dir|
        expect(contribution.roots).to be_empty
        expect(contribution.references).to include(
          Rigor::Analysis::Reachability::PluginRoots::Reference.new(name: "Admin::User", role: :test)
        )
      end
    end

    # The point of the role. Both halves matter: out of `candidates` (something does reach it) and into
    # `test_only` (nothing in production does) — which is the WD8 answer a root would have destroyed.
    it "lands the class in test_only rather than in candidates" do
      collect_in("rigor-factorybot", files) do |contribution, dir|
        report = report_for(dir, files, contribution)

        expect(report.candidates.map(&:fqn)).not_to include("Admin::User")
        expect(report.test_only.map(&:fqn)).to eq(["Admin::User"])
      end
    end

    it "is what makes the difference: with no contribution the string-named class is a candidate" do
      collect_in("rigor-factorybot", files) do |_contribution, dir|
        empty = Rigor::Analysis::Reachability::PluginRoots::Contribution.empty
        expect(report_for(dir, files, empty).candidates.map(&:fqn)).to include("Admin::User")
      end
    end
  end

  # The three declines. Each is a decision, and each is recorded here so that removing it is a visible edit.
  describe "plugins that deliberately contribute nothing" do
    # `MyWorker.perform_async` is an ordinary constant reference the scan already records. Rooting every
    # discovered worker would claim "a file exists under app/workers" as evidence something enqueues it.
    it "rigor-sidekiq contributes nothing for a worker the scan can already see" do
      files = {
        "app/workers/welcome_worker.rb" =>
          "class WelcomeWorker\n  include Sidekiq::Job\n  def perform(id) = id\nend\n",
        "app/workers/orphan_worker.rb" =>
          "class OrphanWorker\n  include Sidekiq::Job\n  def perform(id) = id\nend\n"
      }
      collect_in("rigor-sidekiq", files) { |contribution, _dir| expect(contribution).to be_empty }
    end

    # Publishing spec references as roots would promote every spec-referenced class to production-reachable
    # and erase WD8's category outright. The ordinary scan already records them with the `:test` role.
    it "rigor-rspec and rigor-rspec-rails contribute nothing for a described class" do
      files = { "spec/models/user_spec.rb" => "RSpec.describe User do\n  it(\"works\") { expect(1).to eq(1) }\nend\n" }

      collect_in("rigor-rspec", files) { |contribution, _dir| expect(contribution).to be_empty }
      collect_in("rigor-rspec-rails", files) { |contribution, _dir| expect(contribution).to be_empty }
    end

    # `MyJob.perform_later` / `MyMailer.welcome` are ordinary constant references too.
    it "rigor-activejob and rigor-actionmailer contribute nothing" do
      job = { "app/jobs/welcome_job.rb" => "class WelcomeJob\n  def perform = nil\nend\n" }
      mailer = { "app/mailers/user_mailer.rb" => "class UserMailer\n  def welcome = nil\nend\n" }

      collect_in("rigor-activejob", job) { |contribution, _dir| expect(contribution).to be_empty }
      collect_in("rigor-actionmailer", mailer) { |contribution, _dir| expect(contribution).to be_empty }
    end

    it "declares neither reachability fact in its manifest" do
      %w[rigor-sidekiq rigor-rspec rigor-rspec-rails rigor-activejob rigor-actionmailer].each do |gem_name|
        produces = Object.const_get(REACHABILITY_PLUGIN_CLASSES.fetch(gem_name)).manifest.produces
        expect(produces).not_to include(:reachability_roots), gem_name
        expect(produces).not_to include(:reachability_references), gem_name
      end
    end
  end

  it "declares the facts the contributing plugins do publish" do
    expect(Rigor::Plugin::Pundit.manifest.produces).to include(:reachability_roots)
    expect(Rigor::Plugin::Factorybot.manifest.produces).to include(:reachability_references)
  end
end
