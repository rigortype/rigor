# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "rigor/cli/check_command"

[
  File.expand_path("../fixtures/external_plugin/rigor-shared-key-demo/lib", __dir__),
  File.expand_path("../../plugins/rigor-sidekiq/lib", __dir__),
  File.expand_path("../../plugins/rigor-rails-i18n/lib", __dir__)
].each { |lib| $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib) }
require "rigor-shared-key-demo"
require "rigor-sidekiq"
require "rigor-rails-i18n"

# Issue #1574 — `rigor check --incremental` on a project whose plugin producers share a frozen String between a
# row and the key of an index Hash, as rigor-sidekiq, rigor-rails-i18n and rigor-rails-routes do. The priming
# run computes each producer and writes its ADR-45 cache entry; every later run is served that entry. The ADR-88
# fact-surface fingerprint digested `Marshal.dump` bytes, which differ between the computed and the served
# value, so the null run after the prime and every edit run after it reported "plugin fact surface changed"
# and fell back to a full analysis. Each run here is a fresh `CheckCommand` over a fresh cache store, as a
# fresh process is.
RSpec.describe "rigor check --incremental over producers that share frozen Strings" do
  # A plugin gem registers itself on its first `require` only, and the suite unregisters every plugin between
  # examples, so the plugins are registered here and each config entry names its plugin id.
  before do
    Rigor::Plugin.unregister!
    plugin_classes.each { |klass| Rigor::Plugin.register(klass) }
  end

  after { Rigor::Plugin.unregister! }

  around do |example|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def write_project(plugins, files)
    entries = plugins.map { |gem, id| "  - gem: #{gem}\n    id: #{id}\n" }.join
    write(".rigor.yml", "paths:\n  - app\nplugins:\n#{entries}")
    write("app/models/user.rb", "class User\n  def name = \"u\"\nend\n")
    files.each { |path, content| write(path, content) }
  end

  def check(*flags)
    out = StringIO.new
    err = StringIO.new
    argv = ["--no-ci-detect", "--no-stats", "--no-baseline", "--format", "json", *flags]
    Rigor::CLI::CheckCommand.new(argv: argv, out: out, err: err).run
    [out.string, err.string]
  end

  def rules(json)
    JSON.parse(json).fetch("diagnostics").map { |diagnostic| diagnostic.fetch("rule") }
  end

  # Prime, then a null run and an edit run. Both must reuse the snapshot, and each must print exactly what a
  # `--no-cache` run of the same tree prints. Returns the edit run's output.
  def expect_warm_journey
    _, prime_err = check("--incremental")
    expect(prime_err).to include("--incremental cold")

    null_out, null_err = check("--incremental")
    expect(null_err).to include("--incremental warm — reused cached diagnostics")
    expect(null_err).not_to include("plugin fact surface changed")
    expect(null_out).to eq(check("--no-cache").first)

    File.write("app/models/user.rb", "class User\n  def name = \"u\"\n  def email = \"e\"\nend\n")
    edit_out, edit_err = check("--incremental")
    expect(edit_err).to include("--incremental warm — reused cached diagnostics")
    expect(edit_err).not_to include("plugin fact surface changed")
    expect(edit_out).to eq(check("--no-cache").first)
    edit_out
  end

  context "with a fixture plugin whose index is keyed by its rows' frozen names" do
    let(:plugin_classes) { [Rigor::Plugin::SharedKeyDemo] }

    it "stays warm across a null run and an edit, and answers what a --no-cache run answers" do
      write_project(
        { "rigor-shared-key-demo" => "shared-key-demo" },
        "app/jobs/signup.rb" => "class Signup\n  def call = WelcomeWorker.perform_async(1, 2)\nend\n"
      )

      # The positive control: the plugin read its producer and reported the call.
      expect(rules(expect_warm_journey)).to include("worker-arity")
    end
  end

  context "with rigor-sidekiq and rigor-rails-i18n" do
    let(:plugin_classes) { [Rigor::Plugin::Sidekiq, Rigor::Plugin::RailsI18n] }

    it "stays warm across a null run and an edit, and answers what a --no-cache run answers" do
      write_project(
        { "rigor-sidekiq" => "sidekiq", "rigor-rails-i18n" => "rails-i18n" },
        "app/workers/welcome_worker.rb" => <<~RUBY,
          module Sidekiq
            module Worker; end
          end

          class WelcomeWorker
            include Sidekiq::Worker

            def perform(user_id) = user_id
          end
        RUBY
        "config/locales/en.yml" => "en:\n  users:\n    welcome: \"Welcome\"\n    bye: \"Bye\"\n",
        "config/locales/ja.yml" => "ja:\n  users:\n    welcome: \"ようこそ\"\n",
        "app/jobs/signup.rb" => <<~RUBY
          class Signup
            def call
              WelcomeWorker.perform_async(1, 2)
              I18n.t("users.welcome")
            end
          end
        RUBY
      )

      # The positive controls: both plugins read their producers and reported the calls.
      expect(rules(expect_warm_journey)).to include("wrong-arity", "translation-call")
    end
  end
end
