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
  "rigor-activesupport-core-ext" => "ActivesupportCoreExt", "rigor-sidekiq" => "Sidekiq"
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
      result = nil
      Dir.chdir(File.expand_path("../../integration/fixtures/effects/rails", __dir__)) do
        runner = Rigor::Analysis::Runner.new(
          configuration: Rigor::Configuration.new(
            Rigor::Configuration::DEFAULTS.merge(
              "paths" => ["app"], "effects" => {}, "plugins" => RAILS_PLUGIN_ENTRIES
            )
          ),
          cache_store: nil, plugin_requirer: RAILS_PLUGIN_REQUIRER
        )
        # Class-level memo, so it runs outside example scope where the `GuardedAnalysis` mixin lives.
        result = InternalAnalyzerErrorGuard.check!(runner.run(["app"]), context: "rails_layer_spec .table")
      end
      [runner.effect_table, runner.effect_plugin_facts, result.diagnostics]
    end
  end

  let(:table) { self.class.table[0] }
  let(:facts) { self.class.table[1] }
  let(:diagnostics) { self.class.table[2] }

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

  # An association reader returns a `CollectionProxy`, and a query builder on it an `AssociationRelation`.
  # The plugin types both as `Relation[Post]`, so the Relation signature's bound is the one such a call
  # imports. Their builders and writers change the association's target, which the caller can still reach
  # through the owner.
  describe "an association relation typed as a Relation" do
    # A writer that queries before its write, or after a failed one, names both leaves: `io.db.write` does
    # not include `io.db.read`. relation.rbs cites the activerecord 8.1.3.1 path each read comes from.
    read_write = %w[io.db.read io.db.write].freeze

    # The RBS envelopes, written from the callee's side: the receiver changes itself.
    envelope_bounds = {
      "via_build" => [], "via_new" => [], "via_scoped_build" => [],
      "via_create" => read_write, "via_create!" => read_write,
      "via_find_or_create_by" => read_write, "via_find_or_create_by!" => read_write,
      "via_create_or_find_by" => read_write, "via_create_or_find_by!" => read_write,
      "via_first_or_create" => read_write, "via_first_or_create!" => read_write,
      "via_find_or_initialize_by" => ["io.db.read"], "via_first_or_initialize" => ["io.db.read"],
      "via_reset" => [], "via_reload" => ["io.db.read"],
      "via_delete_all" => read_write, "via_destroy_all" => read_write,
      "via_update_all" => read_write, "via_touch_all" => read_write,
      "via_insert_all" => ["io.db.write"], "via_insert_all!" => ["io.db.write"],
      "via_upsert_all" => ["io.db.write"],
      "via_insert" => ["io.db.write"], "via_insert!" => ["io.db.write"], "via_upsert" => ["io.db.write"]
    }.freeze

    # Writers that run on a relation of their own, or on the records they load, so the proxy's target is
    # left alone and the bound is the two I/O leaves with no mutation.
    unmutating_writers = %w[via_update via_update! via_destroy_by via_delete_by].freeze

    # The attribution rows for the writers a plain Relation does not define, written about the call: the
    # proxy is not the caller's `self`, so the change is bare `mutate`.
    row_methods = %w[via_shovel via_push via_append via_concat via_replace via_delete via_destroy via_clear].freeze
    let(:row_bound) { %w[io.db.read io.db.write io.db.transaction mutate] }

    envelope_bounds.each do |method, io|
      it "bounds ##{method} with mutate.self beside #{io.empty? ? 'nothing else' : io.join(', ')}" do
        key = "PostDrafts##{method}"
        expect(declared(key)).to contain_exactly(*io, "mutate.self")
        expect(entry(key)).to be_exhaustive
        expect(entry(key)).not_to be_trivial
      end
    end

    unmutating_writers.each do |method|
      it "bounds ##{method} with the read beside the write and no mutation" do
        key = "PostDrafts##{method}"
        expect(declared(key)).to contain_exactly("io.db.read", "io.db.write")
        expect(entry(key)).to be_exhaustive
      end
    end

    row_methods.each do |method|
      it "colours ##{method} through the proxy-writer row and keeps the site exhaustive" do
        key = "PostDrafts##{method}"
        expect(declared(key)).to match_array(row_bound)
        expect(entry(key)).to be_exhaustive
      end
    end

    # `%a{pure}` on `build` used to let `rigor sig-gen` write `%a{pure}` on a method whose only statement
    # builds into a held association.
    it "withholds %a{pure} from a method that only builds into the association" do
      %w[via_build via_new via_scoped_build].each do |method|
        expect(Rigor::SigGen::EffectAnnotation.decide(entry("PostDrafts##{method}")))
          .to eq([[], :withheld_declared])
      end
    end

    # `insert`, `insert!` and `upsert` used to be undeclared, so the open receiver typed them as `untyped`
    # with no argument check. The declaration keeps that result type, and its parameter list must accept
    # every call Rails does, or the bound would cost a false `call.wrong-arity`.
    it "declares the single-row inserts without a call diagnostic on a call Rails accepts" do
      drafts = diagnostics.select { |diagnostic| diagnostic.path.to_s.end_with?("app/services/post_drafts.rb") }
      expect(drafts.map(&:rule).compact.grep(/\Acall\./)).to be_empty
    end

    # The control: a query builder changes nothing, on a proxy as anywhere else, and stays emit-able.
    it "leaves a query builder on the proxy trivial" do
      expect(entry("PostDrafts#titled")).to be_trivial
      expect(Rigor::SigGen::EffectAnnotation.decide(entry("PostDrafts#titled"))).to eq([["%a{pure}"], :emitted])
    end
  end

  # `Post`'s class body has no callback macro and no uniqueness validator for the callback edge to read, so
  # nothing is synthesised in front of the `ActiveRecord::Base` row, and each `PostMaintenance` method reads
  # exactly the row its one call matches.
  describe "a class-side writer" do
    reading_writers = %w[
      via_find_or_create_by via_find_or_create_by! via_create_or_find_by via_create_or_find_by!
      via_first_or_create via_first_or_create! via_update via_update! via_destroy via_destroy_all
      via_destroy_by via_delete via_delete_all via_delete_by via_update_all via_touch_all via_reset_counters
    ].freeze

    # The control: a writer that queries nothing first must not gain the read from a list edited by name.
    plain_writers = %w[
      via_create via_create! via_insert via_insert! via_insert_all via_insert_all! via_upsert via_upsert_all
      via_update_counters via_increment_counter via_decrement_counter
    ].freeze

    # Delegated readers that had no row at all, and so read as trivially pure.
    readers = %w[via_first_or_initialize via_second! via_async_count via_extract_associated].freeze

    reading_writers.each do |method|
      it "bounds ##{method} with the read beside the write" do
        key = "PostMaintenance##{method}"
        expect(declared(key)).to contain_exactly("io.db.read", "io.db.write")
        expect(entry(key)).to be_exhaustive
      end
    end

    plain_writers.each do |method|
      it "keeps ##{method} a write alone" do
        expect(declared("PostMaintenance##{method}")).to contain_exactly("io.db.write")
      end
    end

    readers.each do |method|
      it "bounds ##{method} with the read it issues" do
        key = "PostMaintenance##{method}"
        expect(declared(key)).to contain_exactly("io.db.read")
        expect(entry(key)).not_to be_trivial
      end
    end

    it "reads the row back in an instance-side lock" do
      expect(declared("PostMaintenance#via_lock!")).to contain_exactly("io.db.read", "io.db.transaction")
      expect(declared("PostMaintenance#via_with_lock")).to contain_exactly("io.db.read", "io.db.transaction")
    end

    # activerecord 8.1.3.1's `Querying::QUERYING_METHODS`: the class methods Rails delegates to `all`, so
    # `Post.update_all` IS `Post.all.update_all`. `update(!)` and `create(!)` are not in it; they are
    # `Persistence` class methods, which is why `Post.create` stays write-only while `Relation#create` reads.
    def querying_methods
      %i[
        find find_by find_by! take take! sole find_sole_by first first! last last!
        second second! third third! fourth fourth! fifth fifth!
        forty_two forty_two! third_to_last third_to_last! second_to_last second_to_last!
        exists? any? many? none? one?
        first_or_create first_or_create! first_or_initialize
        find_or_create_by find_or_create_by! find_or_initialize_by
        create_or_find_by create_or_find_by!
        destroy destroy_all delete delete_all update_all touch_all destroy_by delete_by
        find_each find_in_batches in_batches
        select reselect order regroup in_order_of reorder group limit offset joins left_joins left_outer_joins
        where rewhere invert_where preload extract_associated eager_load includes from lock readonly
        and or annotate optimizer_hints extending
        having create_with distinct references none unscope merge except only
        count average minimum maximum sum calculate
        pluck pick ids async_ids strict_loading excluding without with with_recursive
        async_count async_average async_minimum async_maximum async_sum async_pluck async_pick
        insert insert_all insert! insert_all! upsert upsert_all
      ].freeze
    end

    # Query builders the Relation signature does not declare. With no row, the class-side call reads as
    # pure, which is what a builder is.
    def undeclared_builders = %i[invert_where with_recursive].freeze

    # Each delegated class method carries the I/O labels of the Relation method it delegates to, and a
    # missing row counts as none, so an edit to one side, or a selector left out of both, fails here.
    it "gives each delegated class method the I/O labels of the Relation method" do
      relation_io = relation_io_bounds
      rows = Rigor::Plugin::Activerecord::Effects.singleton_rows.group_by(&:method)
      expect(relation_io).to include("update_all" => %w[io.db.read io.db.write], "where" => [])

      aggregate_failures do
        querying_methods.each do |selector|
          row_io = rows.fetch(selector, []).flat_map(&:labels).grep(/\Aio\./).uniq.sort
          if relation_io.key?(selector.to_s)
            expect([selector, row_io]).to eq([selector, relation_io[selector.to_s]])
          elsif !undeclared_builders.include?(selector)
            expect([selector, row_io]).not_to eq([selector, []])
          end
        end
      end
    end

    def relation_io_bounds
      path = File.expand_path("../../../plugins/rigor-activerecord/sig/active_record/relation.rbs", __dir__)
      _, _, decls = RBS::Parser.parse_signature(RBS::Buffer.new(name: path, content: File.read(path)))
      relation = decls.flat_map(&:members).find { |decl| decl.name.to_s == "Relation" }
      relation.members.grep(RBS::AST::Members::MethodDefinition).to_h do |member|
        labels = member.annotations.map(&:string).grep(/\Arigor:v1:effect /)
                       .flat_map { |text| text.delete_prefix("rigor:v1:effect ").split(/,\s*/) }
        [member.name.to_s, labels.grep(/\Aio\./).sort]
      end
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

  # #440 — the row that names the method, as opposed to the rows that name its callers.
  #
  # `User` never writes `def save`, so its `save` row is synthesised whole from the class body's callbacks
  # and its uniqueness validator. That row used to carry the validator's SELECT and nothing else, and read
  # `User#save: ≤ io.db.read` — "save does not write to the database", which is the one line in a Rails
  # report a reader can check at a glance. The write was there all along at every *call site*; what was
  # missing was the framework's own claim about the selector on the synthesised unit.
  describe "the synthesised persistence row" do
    # Every selector `rigor-activerecord` maps to a write, on a model that defines none of them. One
    # example per method rather than one for `save`, because the defect was structural and they shared it.
    %w[save save! update update! update_attribute touch increment! decrement!].each do |selector|
      it "reports the write on an inherited ##{selector}" do
        expect(declared("User##{selector}")).to include("io.db.write")
      end
    end

    # The destroy triggers are synthesised from `before_destroy` rather than from `before_save`, so they
    # come off a second code path and a fix that only reached the save group would leave them behind.
    %w[destroy destroy! delete].each do |selector|
      it "reports the write on a destroy-side ##{selector}" do
        expect(declared("Audit##{selector}")).to include("io.db.write")
      end
    end

    it "reports the write on the singleton twins a callback synthesises" do
      expect(declared("User.create")).to include("io.db.write")
      expect(declared("User.create!")).to include("io.db.write")
    end

    it "keeps the validator's read beside the write rather than instead of it" do
      expect(declared("User#save")).to include("io.db.read", "io.db.write")
    end

    # `valid?` runs the validators and issues no INSERT; a fix that reached for the write list by name
    # would have coloured this one too.
    it "leaves a read-only trigger a read" do
      expect(declared("User#valid?")).to include("io.db.read")
      expect(declared("User#valid?")).not_to include("io.db.write")
    end

    # The guard rail. A model that spells out `def save` and never reaches `super` has replaced the
    # framework's implementation, and the report must keep saying what that body really does.
    it "does not paint the write onto an override that never delegates upward" do
      expect(declared("RefusedAudit#save")).not_to include("io.db.write")
    end

    # …while the same class's *un*-overridden siblings still carry it, so the exemption is per selector.
    it "keeps the write on the siblings such an override did not replace" do
      expect(declared("RefusedAudit#save!")).to include("io.db.write")
    end

    it "keeps the write on an override that wraps the framework with super" do
      expect(declared("WrappedAudit#save")).to include("io.db.write")
    end

    # A model with neither a callback nor a uniqueness validator earns no synthetic unit at all, and the
    # fix must not invent one: `PlainRecord#save` would otherwise land in the snapshot for every model in
    # the project. Silence is not the same claim as `≤ io.db.read`.
    it "invents no row for a model whose class body declares nothing" do
      expect(table["ApplicationRecord#save"]).to be_nil
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

    # #456 — `job.enqueue` shipped in the vocabulary and nothing produced it: across Redmine and Mastodon
    # the census found zero instances, while Mastodon alone writes 219 `perform_async`-shaped call sites.
    # A Sidekiq worker has no base class, so no spelling of the row could have matched until the
    # plugin-fact ancestry learned to walk `include`.
    it "colours a Sidekiq enqueue through the marker module the worker includes" do
      expect(declared("UsersController#enqueue")).to include("job.enqueue", "io.net")
    end

    # #456 — the two shapes a real application actually writes, neither of which names the mailer class
    # at the `deliver_*` call site. Both were silent: `email.send` appeared zero times across Redmine and
    # Mastodon, on 97 and 39 delivery sites respectively.
    it "colours a delivery whose builder is an implicit self-call" do
      expect(declared("UserMailer.deliver_welcome")).to include("email.send", "job.enqueue")
    end

    it "colours a delivery through ActionMailer's parameterized `with` builder" do
      expect(declared("UsersController#deliver_parameterized")).to include("email.send", "job.enqueue")
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
        guarded_run(runner, ["app"])
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
