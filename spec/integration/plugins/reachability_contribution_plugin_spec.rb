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
    # `.rb` only, matching `PathExpansion::RUBY_GLOB` — a fixture may carry a schedule YAML, and the real
    # report never hands one to the scan.
    files.each_key do |relative|
      next unless relative.end_with?(".rb")

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

  # #367 — the schedule is the one place Sidekiq names a worker the constant scan cannot see. Everything
  # else about this plugin is still a decline, and the declines are the load-bearing half: each one below is
  # a name the plugin could have rooted and deliberately does not.
  describe "rigor-sidekiq — supplies roots for schedule-named workers only" do
    let(:workers) do
      {
        "app/workers/nightly_report_worker.rb" =>
          "class NightlyReportWorker\n  include Sidekiq::Job\n  def perform = nil\nend\n",
        "app/workers/orphan_worker.rb" =>
          "class OrphanWorker\n  include Sidekiq::Job\n  def perform(id) = id\nend\n"
      }
    end

    # `sidekiq-cron`'s layout: the document IS the schedule map. `OrphanWorker` is the control — same
    # directory, same marker module, named by no schedule — and a plugin that rooted the discovered worker
    # set would claim it too.
    let(:cron_schedule) do
      workers.merge(
        "config/schedule.yml" => <<~YAML
          nightly_report:
            cron: "0 3 * * *"
            class: "NightlyReportWorker"
        YAML
      )
    end

    it "publishes the `class:` name from config/schedule.yml and nothing else" do
      collect_in("rigor-sidekiq", cron_schedule) do |contribution, _dir|
        expect(contribution.roots).to eq(["NightlyReportWorker"])
        expect(contribution.references).to be_empty
      end
    end

    it "takes the scheduled worker out of the candidate list and leaves the orphan in it" do
      collect_in("rigor-sidekiq", cron_schedule) do |contribution, dir|
        report = report_for(dir, cron_schedule, contribution)

        expect(report.candidates.map(&:fqn)).to include("OrphanWorker")
        expect(report.candidates.map(&:fqn)).not_to include("NightlyReportWorker")
      end
    end

    # Without the plugin the same project reports the nightly worker as dead — the state this slice exists
    # to fix, and the proof the example above is not passing for an unrelated reason.
    it "is what makes the difference: with no contribution the scheduled worker is a candidate" do
      collect_in("rigor-sidekiq", cron_schedule) do |_contribution, dir|
        empty = Rigor::Analysis::Reachability::PluginRoots::Contribution.empty
        expect(report_for(dir, cron_schedule, empty).candidates.map(&:fqn)).to include("NightlyReportWorker")
      end
    end

    # `sidekiq-scheduler` nests the same entries under `sidekiq.yml`'s `:scheduler: :schedule:`, with the
    # Symbol keys that file is conventionally written with.
    it "reads the `:scheduler: :schedule:` block of config/sidekiq.yml" do
      files = workers.merge(
        "config/sidekiq.yml" => <<~YAML
          :concurrency: 5
          :scheduler:
            :schedule:
              nightly_report:
                every: "1h"
                class: "NightlyReportWorker"
        YAML
      )
      collect_in("rigor-sidekiq", files) do |contribution, _dir|
        expect(contribution.roots).to eq(["NightlyReportWorker"])
      end
    end

    # THE decline. A queue name is not a class name: `sidekiq.yml` lists `orphan_worker` as a queue, and
    # inflecting that into `OrphanWorker` would root a worker on a naming coincidence. The queue list is
    # exactly the over-supply #350 declined, so it must contribute nothing even when the inflection would
    # have "worked".
    it "supplies no root for a queue name, even one that inflects to a discovered worker" do
      files = workers.merge(
        "config/sidekiq.yml" => <<~YAML
          :concurrency: 5
          :queues:
            - orphan_worker
            - nightly_report_worker
            - default
        YAML
      )
      collect_in("rigor-sidekiq", files) { |contribution, _dir| expect(contribution).to be_empty }
    end

    # A `class:` the WorkerIndex does not know is dropped rather than published: a typo costs coverage
    # instead of manufacturing a root, and `matched no declaration` stays a meaningful number.
    it "drops a `class:` naming a worker it never discovered" do
      files = workers.merge(
        "config/schedule.yml" => "nightly:\n  cron: \"0 3 * * *\"\n  class: \"NightlyReprotWorker\"\n"
      )
      collect_in("rigor-sidekiq", files) { |contribution, _dir| expect(contribution).to be_empty }
    end

    # A project with no schedule at all is the common case, and it is still the #350 decline: every worker
    # here is named by an ordinary constant reference the scan already records.
    it "contributes nothing when no schedule file exists" do
      collect_in("rigor-sidekiq", workers) { |contribution, _dir| expect(contribution).to be_empty }
    end

    # Fail-soft, paired with a must-still-succeed case — `PluginRoots.collect` swallows every error, so a
    # decline example alone would pass just as well for a plugin that raised on the first byte of YAML.
    it "skips a malformed schedule file without losing the roots a valid one supplies" do
      files = workers.merge(
        "config/sidekiq.yml" => ":scheduler:\n  :schedule:\n   - broken\n\t: indent\n",
        "config/schedule.yml" => "nightly:\n  cron: \"0 3 * * *\"\n  class: \"NightlyReportWorker\"\n"
      )
      collect_in("rigor-sidekiq", files) do |contribution, _dir|
        expect(contribution.roots).to eq(["NightlyReportWorker"])
      end
    end
  end

  # #369 — Solid Queue is the default Active Job backend from Rails 8, and a recurring task names its job
  # only as a string. Same shape as rigor-sidekiq above, one layout difference: `recurring.yml` is keyed by
  # ENVIRONMENT at the top level, so every environment is read rather than a chosen one.
  describe "rigor-activejob — supplies roots for recurring-schedule jobs only" do
    let(:jobs) do
      {
        "app/jobs/send_reminder_job.rb" =>
          "class SendReminderJob < ApplicationJob\n  def perform = nil\nend\n",
        "app/jobs/orphan_job.rb" =>
          "class OrphanJob < ApplicationJob\n  def perform(id) = id\nend\n"
      }
    end

    # `OrphanJob` is the control — same directory, same base class, named by no schedule — so a plugin that
    # rooted the discovered job set would claim it too and the examples below could not tell the difference.
    let(:recurring) do
      jobs.merge(
        "config/recurring.yml" => <<~YAML
          production:
            send_reminder:
              class: "SendReminderJob"
              schedule: "*/3 * * * *"
        YAML
      )
    end

    it "publishes the `class:` name from config/recurring.yml and nothing else" do
      collect_in("rigor-activejob", recurring) do |contribution, _dir|
        expect(contribution.roots).to eq(["SendReminderJob"])
        expect(contribution.references).to be_empty
      end
    end

    it "takes the recurring job out of the candidate list and leaves the orphan in it" do
      collect_in("rigor-activejob", recurring) do |contribution, dir|
        report = report_for(dir, recurring, contribution)

        expect(report.candidates.map(&:fqn)).to include("OrphanJob")
        expect(report.candidates.map(&:fqn)).not_to include("SendReminderJob")
      end
    end

    # Without the plugin the same project reports the recurring job as dead — the state #369 was filed
    # from, on a real Rails 8 application, and the proof the example above is not passing for another
    # reason.
    it "is what makes the difference: with no contribution the recurring job is a candidate" do
      collect_in("rigor-activejob", recurring) do |_contribution, dir|
        empty = Rigor::Analysis::Reachability::PluginRoots::Contribution.empty
        expect(report_for(dir, recurring, empty).candidates.map(&:fqn)).to include("SendReminderJob")
      end
    end

    # EVERY environment block is read. A job scheduled only outside production is still live code, and
    # picking `production:` would report it dead — the same miss this slice exists to fix.
    it "reads a task scheduled only in a non-production environment" do
      files = jobs.merge(
        "config/recurring.yml" => <<~YAML
          staging:
            send_reminder:
              class: "SendReminderJob"
              schedule: "every hour"
        YAML
      )
      collect_in("rigor-activejob", files) do |contribution, _dir|
        expect(contribution.roots).to eq(["SendReminderJob"])
      end
    end

    # The flat layout — no environment key, the document IS the task map. Both depths are read rather than
    # guessed at, because neither layout yields anything under the other's reading.
    it "reads a flat, environment-less document" do
      files = jobs.merge(
        "config/recurring.yml" => "send_reminder:\n  class: \"SendReminderJob\"\n  schedule: \"every hour\"\n"
      )
      collect_in("rigor-activejob", files) do |contribution, _dir|
        expect(contribution.roots).to eq(["SendReminderJob"])
      end
    end

    # THE decline. Solid Queue also accepts inline Ruby, and `command:` names no class the way `class:`
    # does. Parsing a constant out of an arbitrary snippet would manufacture a root from a string — the
    # same over-supply rigor-sidekiq refuses for queue names.
    it "supplies no root for a `command:` entry naming a discovered job" do
      files = jobs.merge(
        "config/recurring.yml" => <<~YAML
          production:
            cleanup:
              command: "OrphanJob.perform_now"
              schedule: "every day at 4am"
        YAML
      )
      collect_in("rigor-activejob", files) { |contribution, _dir| expect(contribution).to be_empty }
    end

    # A `class:` the JobIndex does not know is dropped rather than published: a typo costs coverage instead
    # of manufacturing a root, and `matched no declaration` stays a meaningful number.
    it "drops a `class:` naming a job it never discovered" do
      files = jobs.merge(
        "config/recurring.yml" => "production:\n  send:\n    class: \"SendRemidnerJob\"\n"
      )
      collect_in("rigor-activejob", files) { |contribution, _dir| expect(contribution).to be_empty }
    end

    # Fail-soft, paired with a must-still-succeed case — `PluginRoots.collect` swallows every error, so a
    # decline example alone would pass just as well for a plugin that raised on the first byte of YAML.
    it "skips a malformed schedule without losing the roots a valid one supplies" do
      files = jobs.merge(
        "config/recurring.yml" => "production:\n  send_reminder:\n    class: \"SendReminderJob\"\n",
        "config/other_recurring.yml" => "production:\n - broken\n\t: indent\n"
      )
      collect_in("rigor-activejob", files) do |contribution, _dir|
        expect(contribution.roots).to eq(["SendReminderJob"])
      end
    end
  end

  # The declines. Each is a decision, and each is recorded here so that removing it is a visible edit.
  describe "plugins that deliberately contribute nothing" do
    # Publishing spec references as roots would promote every spec-referenced class to production-reachable
    # and erase WD8's category outright. The ordinary scan already records them with the `:test` role.
    it "rigor-rspec and rigor-rspec-rails contribute nothing for a described class" do
      files = { "spec/models/user_spec.rb" => "RSpec.describe User do\n  it(\"works\") { expect(1).to eq(1) }\nend\n" }

      collect_in("rigor-rspec", files) { |contribution, _dir| expect(contribution).to be_empty }
      collect_in("rigor-rspec-rails", files) { |contribution, _dir| expect(contribution).to be_empty }
    end

    # `MyJob.perform_later` / `MyMailer.welcome` are ordinary constant references too. rigor-activejob is
    # here for the SCHEDULE-LESS project, which is still the #350 decline: it roots a job only when a
    # recurring schedule names one (above), never because a file exists under `app/jobs`.
    it "rigor-activejob with no schedule, and rigor-actionmailer, contribute nothing" do
      job = { "app/jobs/welcome_job.rb" => "class WelcomeJob\n  def perform = nil\nend\n" }
      mailer = { "app/mailers/user_mailer.rb" => "class UserMailer\n  def welcome = nil\nend\n" }

      collect_in("rigor-activejob", job) { |contribution, _dir| expect(contribution).to be_empty }
      collect_in("rigor-actionmailer", mailer) { |contribution, _dir| expect(contribution).to be_empty }
    end

    it "declares neither reachability fact in its manifest" do
      %w[rigor-rspec rigor-rspec-rails rigor-actionmailer].each do |gem_name|
        produces = Object.const_get(REACHABILITY_PLUGIN_CLASSES.fetch(gem_name)).manifest.produces
        expect(produces).not_to include(:reachability_roots), gem_name
        expect(produces).not_to include(:reachability_references), gem_name
      end
    end
  end

  it "declares the facts the contributing plugins do publish" do
    expect(Rigor::Plugin::Pundit.manifest.produces).to include(:reachability_roots)
    expect(Rigor::Plugin::Sidekiq.manifest.produces).to include(:reachability_roots)
    expect(Rigor::Plugin::Sidekiq.manifest.produces).not_to include(:reachability_references)
    expect(Rigor::Plugin::Activejob.manifest.produces).to include(:reachability_roots)
    expect(Rigor::Plugin::Activejob.manifest.produces).not_to include(:reachability_references)
    expect(Rigor::Plugin::Factorybot.manifest.produces).to include(:reachability_references)
  end
end
