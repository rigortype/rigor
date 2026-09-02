# frozen_string_literal: true

# Integration spec for `plugins/rigor-activestorage/`. Mirrors the structure of the `rigor-activerecord` spec
# — materialises model files on disk, runs the analyser, and asserts both the diagnostic stream and the
# per-model attachment index.

require "spec_helper"
require "fileutils"
require "tmpdir"

unless defined?(ACTIVESTORAGE_PLUGIN_LIB)
  ACTIVESTORAGE_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-activestorage/lib", __dir__)
end
$LOAD_PATH.unshift(ACTIVESTORAGE_PLUGIN_LIB) unless $LOAD_PATH.include?(ACTIVESTORAGE_PLUGIN_LIB)
require "rigor-activestorage"

RSpec.describe "plugins/rigor-activestorage" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Activestorage }

  # rubocop:disable Lint/ConstantDefinitionInBlock, RSpec/LeakyConstantDeclaration
  USER_WITH_ATTACHMENTS = <<~RUBY
    class User < ApplicationRecord
      has_one_attached :avatar
      has_many_attached :photos
    end
  RUBY
  POST_WITHOUT_ATTACHMENTS = "class Post < ApplicationRecord\nend\n"
  APPLICATION_RECORD = "class ApplicationRecord\nend\n"
  USER_RBS = <<~RBS
    class User
      attr_accessor name: String
    end
  RBS
  # rubocop:enable Lint/ConstantDefinitionInBlock, RSpec/LeakyConstantDeclaration

  # Materialises a project tree on disk + runs `rigor check` against `demo.rb`; returns
  # `[result, attachment_index]` so specs can assert against the diagnostic stream AND the structured per-model
  # state captured by the plugin.
  def run_as(source, models: { "app/models/application_record.rb" => APPLICATION_RECORD,
                               "app/models/user.rb" => USER_WITH_ATTACHMENTS,
                               "app/models/post.rb" => POST_WITHOUT_ATTACHMENTS },
             sig: { "sig/user.rbs" => USER_RBS })
    files = models.merge(sig).merge("demo.rb" => source)
    Dir.mktmpdir do |dir|
      materialize_files(dir, files)
      Dir.chdir(dir) do
        configuration = Rigor::Configuration.new(
          "paths" => ["demo.rb"],
          "signature_paths" => ["sig"],
          "plugins" => ["rigor-activestorage"]
        )
        runner = Rigor::Analysis::Runner.new(
          configuration: configuration, cache_store: nil,
          collect_stats: false,
          plugin_requirer: build_plugin_requirer
        )
        result = runner.run
        plugin = runner.plugin_registry.find("activestorage")
        [result, plugin&.send(:attachment_index)]
      end
    end
  end

  describe "attachment discovery" do
    it "records `has_one_attached :avatar` as a singular attachment on User" do
      _result, index = run_as("x = 1\n")
      attachments = index.attachments_for("User")
      avatar = attachments.find { |a| a[:name] == "avatar" }

      expect(avatar).to include(name: "avatar", kind: :singular)
    end

    it "records `has_many_attached :photos` as a collection attachment on User" do
      _result, index = run_as("x = 1\n")
      attachments = index.attachments_for("User")
      photos = attachments.find { |a| a[:name] == "photos" }

      expect(photos).to include(name: "photos", kind: :collection)
    end

    it "leaves models without `has_*_attached` macros absent from the index" do
      _result, index = run_as("x = 1\n")

      expect(index.attachments_for("Post")).to be_nil
    end
  end

  describe "diagnostic emission" do
    it "surfaces `attachment-call` info on a recognised attachment access" do
      result, _index = run_as("User.avatar\n")
      info = result.diagnostics.find { |d| d.rule == "attachment-call" }

      expect(info).not_to be_nil
      expect(info.severity).to eq(:info)
      expect(info.message).to include("User.avatar")
      expect(info.message).to include("ActiveStorage::Attached::One")
    end

    it "stays silent on calls to non-attached attribute names" do
      result, _index = run_as("User.nope\n")
      info = result.diagnostics.find { |d| d.rule == "attachment-call" }

      expect(info).to be_nil
    end

    it "stays silent on calls to classes without attachments" do
      result, _index = run_as("Post.something\n")
      info = result.diagnostics.find { |d| d.rule == "attachment-call" }

      expect(info).to be_nil
    end
  end

  # #621 — the discoverer used to key `class ::User` as `"::User"` (and, nested inside a module, as the
  # nonsense `"Admin::::User"`), and both consumers papered over the first spelling with an
  # `attachments_for(name) || attachments_for("::#{name}")` retry. Keys are de-rooted at the producer now,
  # which makes a rooted declaration and a plain reopen collide on ONE key — so the attachment rows union
  # instead of the last file in the glob clobbering the first.
  describe "rooted declarations and reopens (#621)" do
    let(:rooted_models) do
      {
        "app/models/application_record.rb" => APPLICATION_RECORD,
        "app/models/a_user.rb" => "class ::User < ApplicationRecord\n  has_one_attached :avatar\nend\n"
      }
    end

    # A later-sorting file reopens the rooted declaration plainly, adding its own attachment.
    let(:reopen_models) do
      rooted_models.merge(
        "app/models/z_user_ext.rb" => "class User < ApplicationRecord\n  has_many_attached :photos\nend\n"
      )
    end

    it "keys a rooted declaration under its plain spelling" do
      _result, index = run_as("x = 1\n", models: rooted_models)

      expect(index.class_names).to include("User")
      expect(index.class_names).not_to include("::User")
      expect(index.attachments_for("User")).to include(a_hash_including(name: "avatar", kind: :singular))
    end

    it "keys a declaration rooted INSIDE a module as the top-level constant it names" do
      models = {
        "app/models/application_record.rb" => APPLICATION_RECORD,
        "app/models/admin_user.rb" => <<~RUBY
          module Admin
            class ::User < ApplicationRecord
              has_one_attached :avatar
            end
          end
        RUBY
      }
      result, index = run_as("User.avatar\n", models: models)

      expect(index.class_names).to eq(["User"])
      info = result.diagnostics.find { |d| d.rule == "attachment-call" }
      expect(info).not_to be_nil
      expect(info.message).to include("ActiveStorage::Attached::One")
    end

    it "keeps the rooted declaration's attachment when a later file reopens the class plainly" do
      result, index = run_as("User.avatar\n", models: reopen_models)

      expect(index.attachments_for("User").map { |a| a[:name] }).to contain_exactly("avatar", "photos")
      info = result.diagnostics.find { |d| d.rule == "attachment-call" }
      expect(info).not_to be_nil
      expect(info.message).to include("User.avatar")
      expect(info.message).to include("ActiveStorage::Attached::One")
    end

    it "keeps the earlier declaration's attachment across a PLAIN reopen too" do
      models = {
        "app/models/application_record.rb" => APPLICATION_RECORD,
        "app/models/a_user.rb" => "class User < ApplicationRecord\n  has_one_attached :avatar\nend\n",
        "app/models/z_user_ext.rb" => "class User < ApplicationRecord\n  has_many_attached :photos\nend\n"
      }
      result, index = run_as("User.avatar\n", models: models)

      expect(index.attachments_for("User").map { |a| a[:name] }).to contain_exactly("avatar", "photos")
      expect(result.diagnostics.find { |d| d.rule == "attachment-call" }).not_to be_nil
    end

    it "also keeps the reopen's own attachment" do
      result, _index = run_as("User.photos\n", models: reopen_models)
      info = result.diagnostics.find { |d| d.rule == "attachment-call" }

      expect(info).not_to be_nil
      expect(info.message).to include("ActiveStorage::Attached::Many")
    end

    it "still stays silent on a name no declaration attaches" do
      result, _index = run_as("User.nope\n", models: reopen_models)

      expect(result.diagnostics.find { |d| d.rule == "attachment-call" }).to be_nil
    end

    it "still stays silent on a class no declaration introduces" do
      result, index = run_as("Nowhere.avatar\n", models: reopen_models)

      expect(index.attachments_for("Nowhere")).to be_nil
      expect(result.diagnostics.find { |d| d.rule == "attachment-call" }).to be_nil
    end
  end

  describe "dynamic_return return-type narrowing" do
    it "narrows `user.avatar` to `Nominal[ActiveStorage::Attached::One]`" do
      _result, index = run_as("x = 1\n")
      plugin = Rigor::Plugin::Activestorage.allocate
      plugin.instance_variable_set(:@attachment_index, index)

      call_node = Prism.parse("user.avatar").value.statements.body.first
      scope = Object.new
      scope.define_singleton_method(:type_of) do |_node|
        Rigor::Type::Combinator.nominal_of("User")
      end
      scope.define_singleton_method(:environment) { nil }
      receiver_type = Rigor::Type::Combinator.nominal_of("User")
      type = plugin.dynamic_return_type(call_node: call_node, scope: scope, receiver_type: receiver_type)

      expect(type).to eq(
        Rigor::Type::Combinator.nominal_of("ActiveStorage::Attached::One")
      )
    end

    it "narrows `user.photos` to `Nominal[ActiveStorage::Attached::Many]`" do
      _result, index = run_as("x = 1\n")
      plugin = Rigor::Plugin::Activestorage.allocate
      plugin.instance_variable_set(:@attachment_index, index)

      call_node = Prism.parse("user.photos").value.statements.body.first
      scope = Object.new
      scope.define_singleton_method(:type_of) do |_node|
        Rigor::Type::Combinator.nominal_of("User")
      end
      scope.define_singleton_method(:environment) { nil }
      receiver_type = Rigor::Type::Combinator.nominal_of("User")
      type = plugin.dynamic_return_type(call_node: call_node, scope: scope, receiver_type: receiver_type)

      expect(type).to eq(
        Rigor::Type::Combinator.nominal_of("ActiveStorage::Attached::Many")
      )
    end

    it "declines on non-Nominal receivers (e.g., untyped)" do
      _result, index = run_as("x = 1\n")
      plugin = Rigor::Plugin::Activestorage.allocate
      plugin.instance_variable_set(:@attachment_index, index)

      call_node = Prism.parse("user.avatar").value.statements.body.first
      scope = Object.new
      scope.define_singleton_method(:type_of) do |_node|
        Rigor::Type::Combinator.untyped
      end
      receiver_type = Rigor::Type::Combinator.untyped
      type = plugin.dynamic_return_type(call_node: call_node, scope: scope, receiver_type: receiver_type)

      expect(type).to be_nil
    end

    it "declines on attachment-name calls with arguments" do
      _result, index = run_as("x = 1\n")
      plugin = Rigor::Plugin::Activestorage.allocate
      plugin.instance_variable_set(:@attachment_index, index)

      call_node = Prism.parse("user.avatar(some_arg)").value.statements.body.first
      scope = Object.new
      scope.define_singleton_method(:type_of) do |_node|
        Rigor::Type::Combinator.nominal_of("User")
      end
      receiver_type = Rigor::Type::Combinator.nominal_of("User")
      type = plugin.dynamic_return_type(call_node: call_node, scope: scope, receiver_type: receiver_type)

      expect(type).to be_nil
    end

    it "declines on unknown class names" do
      _result, index = run_as("x = 1\n")
      plugin = Rigor::Plugin::Activestorage.allocate
      plugin.instance_variable_set(:@attachment_index, index)

      call_node = Prism.parse("unknown.avatar").value.statements.body.first
      scope = Object.new
      scope.define_singleton_method(:type_of) do |_node|
        Rigor::Type::Combinator.nominal_of("Unknown")
      end
      receiver_type = Rigor::Type::Combinator.nominal_of("Unknown")
      type = plugin.dynamic_return_type(call_node: call_node, scope: scope, receiver_type: receiver_type)

      expect(type).to be_nil
    end
  end

  # #613 / ADR-45 WD1b — the discovery walk gated its glob on `File.directory?(app/models)`, so a project
  # without the root recorded nothing at all: the run-result entry had no edge for the root's appearance and
  # the warm run kept serving the no-attachments answer. The presence half is the same gap inverted — a root
  # that exists but holds no files yet leaves no read row either, so its DELETION was invisible too. Fresh
  # `Cache::Store` per run, so a hit has to come off disk.
  describe "warm-run cache across the appearance of `app/models` (#613)" do
    # Returns `[result, counters]` — the run-diagnostics slot's `hits:` / `misses:` say whether this run was
    # SERVED or RE-ANALYZED.
    def run_warm(dir, cache_root)
      Rigor::Plugin.unregister!
      store = Rigor::Cache::Store.new(root: cache_root)
      result = Dir.chdir(dir) do
        Rigor::Analysis::Runner.new(
          configuration: Rigor::Configuration.new("paths" => ["demo.rb"], "plugins" => ["rigor-activestorage"]),
          cache_store: store, collect_stats: false, plugin_requirer: build_plugin_requirer
        ).run
      end
      counters = store.stats.fetch(:by_producer)
                      .fetch(Rigor::Analysis::RunCacheKey::RUN_DIAGNOSTICS_PRODUCER_ID) { { hits: 0, misses: 0 } }
      [result, counters.slice(:hits, :misses)]
    end

    def attachment_call(result)
      result.diagnostics.find { |d| d.rule == "attachment-call" }
    end

    def with_project
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |cache_root|
          materialize_files(dir, "demo.rb" => "User.avatar\n")
          yield dir, cache_root
        end
      end
    end

    it "re-analyzes the warm run once the `app/models` root is CREATED: the attachment resolves" do
      with_project do |dir, cache_root|
        cold, cold_counters = run_warm(dir, cache_root)
        expect(cold_counters).to eq(hits: 0, misses: 1)
        expect(attachment_call(cold)).to be_nil

        materialize_files(dir, "app/models/user.rb" => USER_WITH_ATTACHMENTS)
        warm, counters = run_warm(dir, cache_root)
        expect(counters).to eq(hits: 0, misses: 1)
        expect(attachment_call(warm)&.message).to include("ActiveStorage::Attached::One")
      end
    end

    it "serves the warm run from cache when nothing changed (a probe row does not thrash)" do
      with_project do |dir, cache_root|
        materialize_files(dir, "app/models/user.rb" => USER_WITH_ATTACHMENTS)
        cold, = run_warm(dir, cache_root)

        warm, counters = run_warm(dir, cache_root)
        expect(counters).to eq(hits: 1, misses: 0)
        expect(warm.diagnostics.map { |d| [d.rule, d.line, d.message] })
          .to eq(cold.diagnostics.map { |d| [d.rule, d.line, d.message] })
      end
    end

    it "re-analyzes the warm run once an EMPTY `app/models` root is DELETED (the presence row's direction)" do
      with_project do |dir, cache_root|
        # An empty root is the case only the presence row covers: the walk read no file, so there is no
        # content row to go stale when the root disappears.
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        _cold, cold_counters = run_warm(dir, cache_root)
        expect(cold_counters).to eq(hits: 0, misses: 1)

        FileUtils.rm_rf(File.join(dir, "app"))
        _warm, counters = run_warm(dir, cache_root)
        expect(counters).to eq(hits: 0, misses: 1)
      end
    end
  end
end
