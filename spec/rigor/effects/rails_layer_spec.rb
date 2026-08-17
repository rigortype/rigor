# frozen_string_literal: true

require "rigor"
require "rigor/analysis/runner"

# The bundled Rails plugins, required by their own entry points and re-registered per run.
#
# The suite pervasively calls `Rigor::Plugin.unregister!` while `require` is a once-per-process no-op, so a
# spec that names bundled plugins in `plugins:` and lets the loader `require` them passes alone and finds an
# empty registry inside a full run. The convention the other plugin integration specs use — require the
# entry points here, hand the loader a requirer that re-registers — is what makes this file order-independent.
RAILS_PLUGIN_GEMS = {
  "rigor-railties" => "Railties", "rigor-activerecord" => "Activerecord",
  "rigor-activejob" => "Activejob", "rigor-actionmailer" => "Actionmailer",
  "rigor-actionpack" => "Actionpack", "rigor-actioncable" => "Actioncable",
  "rigor-activestorage" => "Activestorage", "rigor-rails-i18n" => "RailsI18n",
  "rigor-activesupport-core-ext" => "ActivesupportCoreExt"
}.freeze

RAILS_PLUGIN_GEMS.each_key do |gem_name|
  path = File.expand_path("../../../plugins/#{gem_name}/lib", __dir__)
  $LOAD_PATH.unshift(path) unless $LOAD_PATH.include?(path)
  require gem_name
end

# Re-registers whatever an earlier example's `unregister!` cleared. Paired with the `id:` form of the
# `plugins:` entries below, which resolves by id rather than by the loader's newly-registered delta — the
# delta is empty here by construction, because the file-level `require` above already ran the gem's body.
RAILS_PLUGIN_REQUIRER = lambda do |name|
  constant = RAILS_PLUGIN_GEMS[File.basename(name.to_s, ".rb")] || RAILS_PLUGIN_GEMS[name.to_s]
  Rigor::Plugin.register(Rigor::Plugin.const_get(constant)) if constant
  true
end

# `{gem:, id:}` entries, so the loader looks the class up by id.
RAILS_PLUGIN_ENTRIES = RAILS_PLUGIN_GEMS.map do |gem_name, constant|
  { "gem" => gem_name, "id" => Rigor::Plugin.const_get(constant).manifest.id }
end.freeze

# ADR-103 WD10 / WD14 (#387) — the Rails effect layer end to end over
# `spec/integration/fixtures/effects/rails`, a Rails-shaped app carrying **no Rigor syntax at all**.
#
# That is the claim under test. Every label below comes from a bundled plugin's manifest or its shipped
# RBS reaching an ordinary Rails idiom through the project's own `class … <` lines; the fixture is what a
# Rails app looks like, not what one looks like after adopting Rigor.
RSpec.describe "the Rails effect layer" do
  def fixture
    File.expand_path("../../integration/fixtures/effects/rails", __dir__)
  end

  def configuration(plugins: RAILS_PLUGIN_ENTRIES)
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => ["app"], "effects" => {}, "plugins" => plugins
      )
    )
  end

  # One run, shared by every example: the fixture is small but a Runner is not, and each example asks a
  # different question of the same table.
  def self.table
    @table ||= begin
      runner = nil
      Dir.chdir(File.expand_path("../../integration/fixtures/effects/rails", __dir__)) do
        runner = Rigor::Analysis::Runner.new(
          configuration: Rigor::Configuration.new(
            Rigor::Configuration::DEFAULTS.merge(
              "paths" => ["app"], "effects" => {}, "plugins" => RAILS_PLUGIN_ENTRIES
            )
          ),
          cache_store: nil, plugin_requirer: RAILS_PLUGIN_REQUIRER
        )
        runner.run(["app"])
      end
      [runner.effect_table, runner.effect_plugin_facts]
    end
  end

  let(:table) { self.class.table.first }
  let(:facts) { self.class.table.last }

  def entry(key)
    table[key] or raise "no effect-table entry for #{key.inspect}"
  end

  def declared(key)
    entry(key).declared.to_a
  end

  describe "ActiveRecord" do
    # The row is written on `ActiveRecord::Base`; the app writes `User.find`. What connects them is
    # `User < ApplicationRecord < ActiveRecord::Base`, read off the project's own source.
    it "reaches a model finder through the project's inheritance chain" do
      expect(declared("UsersController#show")).to include("io.db.read")
    end

    # The truthful reading of laziness (design note § 11.2): `where` composes and issues nothing. This is
    # the one assertion that would pass just as easily if the whole layer were wired backwards, so it is
    # paired with the finder above deliberately.
    it "leaves a bare relation builder empty" do
      expect(entry("UsersController#index").declared).to be_empty
      expect(entry("UsersController#index").proven).to be_empty
    end

    it "colours a persistence call as a write" do
      expect(declared("UsersController#create")).to include("io.db.write")
    end

    # `sql_verb` narrowing on the spelling a Rails app actually uses, where the connection object has no
    # declared type and the class that handed it over does.
    it "narrows raw SQL by the statement's own leading verb" do
      expect(declared("Report#raw")).to include("io.db.write")
      expect(declared("Report#raw")).not_to include("io.db.read")
    end
  end

  describe "framework edges" do
    # `save` runs `before_save :normalize_email` and `after_commit :notify`; `notify` logs. None of that
    # is visible at the call site, and all of it is the caller's own code.
    it "carries a model's callbacks into its caller" do
      expect(declared("UsersController#create")).to include("telemetry")
    end

    # `validates :email, uniqueness: true` is a SELECT before the write.
    it "carries a uniqueness validator's query into save" do
      expect(declared("User#save")).to include("io.db.read")
    end

    it "runs a job's perform through perform_now" do
      expect(entry("UsersController#run_now").proven.to_a).to include("global.write")
    end

    # The rule the whole deferred-execution section exists to protect (ADR-103 WD4). `perform` writes a
    # global; if an enqueue edged into it, that write would appear here.
    it "never edges an enqueue into the job body" do
      expect(entry("UsersController#enqueue").proven).to be_empty
      expect(declared("UsersController#enqueue")).not_to include("global.write")
    end

    it "runs a mailer body through the class-method mapping" do
      expect(declared("UsersController#deliver")).to include("io.db.read")
    end
  end

  describe "the queue adapter" do
    # `config/application.rb` says `:solid_queue`, so the enqueue is an INSERT and a "no database on this
    # path" envelope is right to object to it.
    it "narrows the enqueue transport from config.active_job.queue_adapter" do
      expect(declared("UsersController#enqueue"))
        .to include("io.db.write", "rails.activejob.enqueue", "job.enqueue")
    end

    it "reads a set(...) builder as pure and its enqueue as the effect" do
      expect(declared("UsersController#enqueue_later")).to include("io.db.write", "rails.activejob.enqueue")
    end

    it "falls back to bare io when no adapter is declared" do
      rows = Rigor::Plugin::Activejob::Effects.attributions(nil)
      expect(rows.first.labels).to include("io")
      expect(rows.first.labels).not_to include("io.db.write")
    end

    it "reads a Redis-backed adapter as io.net" do
      rows = Rigor::Plugin::Activejob::Effects.attributions("sidekiq")
      expect(rows.first.labels).to include("io.net")
    end

    # `:inline` is the one setting that licenses the edge the layer otherwise refuses.
    it "edges perform_later to perform only under the inline adapter" do
      expect(Rigor::Plugin::Activejob::Effects.edges(nil).map(&:method)).to eq([nil])
      expect(Rigor::Plugin::Activejob::Effects.edges("inline").map(&:method))
        .to eq([nil, :perform_later])
    end
  end

  describe "ActionMailer and ActionPack" do
    it "colours deliver_now as a send" do
      expect(declared("UsersController#deliver")).to include("email.send", "rails.actionmailer.deliver")
    end

    # `session[:user_id] = 1` is `[]=` on a receiver nothing types; the self-path row is what reaches it.
    it "colours a session write through the self-path row" do
      expect(declared("UsersController#login")).to include("mutate", "rails.session.write")
    end

    # `render` is `mutate.self`, not `io` — Rack writes the socket later, outside any project method.
    it "colours render as a response mutation and keeps the template taint" do
      expect(declared("UsersController#render_page")).to include("mutate.self", "rails.response.write")
      expect(entry("UsersController#render_page").causes.map(&:first)).to include("template-not-analysed")
    end
  end

  describe "the Rails namespace" do
    it "colours the cache" do
      expect(declared("Report#cached")).to include("cache.read", "io")
    end

    it "colours the environment as a global read" do
      expect(declared("Report#environment")).to include("global.read", "rails.config.read")
    end

    it "colours a translation lookup" do
      expect(declared("Report#translated")).to include("global.read", "rails.i18n.translate")
    end

    it "colours the zone-aware clock" do
      expect(declared("Report#stamp")).to include("nondet.time", "global.read")
    end
  end

  describe "discharge" do
    # ADR-103 WD6 — a first-party bundled plugin's framework-derived attribution discharges, so a site
    # whose receiver the typer could not name is still exhaustive. Without it every `Rails.env` in a Rails
    # app would carry a `dynamic-receiver` taint that no amount of annotation could ever clear.
    it "leaves a plugin-coloured site exhaustive" do
      expect(entry("Report#environment")).to be_exhaustive
      expect(entry("Report#cached")).to be_exhaustive
      expect(entry("UsersController#show")).to be_exhaustive
    end

    it "accepts every bundled Rails plugin's contribution without a warning" do
      expect(facts.warnings).to be_empty
    end
  end

  # The measured regression this guards: on the sequential path the cross-file discovery pre-pass fills the
  # superclass table AFTER the first file has already asked for the compiled plugin tables, so an
  # unconditional memo pinned the run to an empty ancestry and `Issue.find` on a
  # `Issue < ApplicationRecord < ActiveRecord::Base` found no row. A pooled run hid it: its workers are
  # seeded with the finished table before they fork.
  describe "on the sequential path" do
    it "still reaches a model finder through the inheritance chain" do
      table = nil
      Dir.chdir(fixture) do
        runner = Rigor::Analysis::Runner.new(
          configuration: configuration, cache_store: nil, workers: 0,
          plugin_requirer: RAILS_PLUGIN_REQUIRER
        )
        runner.run(["app"])
        table = runner.effect_table
      end

      expect(table["UsersController#show"].declared.to_a).to include("io.db.read")
    end
  end

  describe "the entry-point presets" do
    it "registers the rails preset and its per-component slices" do
      expect(Rigor::Effects::EntryPoints.names)
        .to include("rails", "rails-controllers", "rails-jobs", "rails-mailers", "rails-channels")
    end

    it "expands the rails preset to the four entry directories" do
      expect(Rigor::Effects::EntryPoints.globs_for("rails"))
        .to contain_exactly("app/channels/**/*.rb", "app/controllers/**/*.rb", "app/jobs/**/*.rb",
                            "app/mailers/**/*.rb")
    end
  end
end
