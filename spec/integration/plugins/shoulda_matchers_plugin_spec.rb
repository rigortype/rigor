# frozen_string_literal: true

# Integration spec for `plugins/rigor-shoulda-matchers/`. Validates shoulda matchers against the :model_index
# cross-plugin fact (ADR-9) published by rigor-activerecord.
#
# Issue #573: the analyzer used to consume the fact as if it were rigor-activerecord's internal `ModelIndex`
# OBJECT (`index.find(anchor)` then `entry.column?(...)`), but the published fact is a plain Hash
# (`Activerecord#index_to_published_hash` — ADR-9's "the value is data, not objects" contract, the same shape
# rigor-actionpack and rigor-factorybot key into with `model_index[model_class]`). `Hash#find` with a
# non-block argument does not do a keyed lookup — it returns an Enumerator — so the real cross-plugin path
# raised `NoMethodError` on the very first matcher in any file with a `describe <Model>` block, and the old
# spec below never caught it because it stubbed a `ModelIndex`-shaped object instead of the Hash the producer
# actually publishes.
#
# The lets below now stub the REAL Hash shape (so a future rigor-activerecord field rename shows up here
# too), and the "cross-plugin integration" block at the bottom drives the full producer → consumer path
# through `Rigor::Analysis::Runner` with a real `rigor-activerecord` schema + model, so the contract is
# pinned end-to-end and not just at the shape level.

require "spec_helper"
require "fileutils"
require "tmpdir"

SHOULDA_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-shoulda-matchers/lib", __dir__)
ACTIVERECORD_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-activerecord/lib", __dir__)
$LOAD_PATH.unshift(SHOULDA_PLUGIN_LIB) unless $LOAD_PATH.include?(SHOULDA_PLUGIN_LIB)
$LOAD_PATH.unshift(ACTIVERECORD_PLUGIN_LIB) unless $LOAD_PATH.include?(ACTIVERECORD_PLUGIN_LIB)
require "rigor-shoulda-matchers"
require "rigor-activerecord"

RSpec.describe "plugins/rigor-shoulda-matchers" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::ShouldaMatchers }

  # The published `:model_index` fact's per-model entry — the flat Hash `Activerecord#index_to_published_hash`
  # builds, NOT rigor-activerecord's internal `ModelIndex::Entry` Struct. `columns:` is `Array<String>`;
  # `associations:` is `Array<Hash>` with String `name:` / `target:`, Symbol `kind:`.
  let(:user_entry) do
    {
      table: "users",
      columns: %w[id email name created_at],
      associations: [
        { name: "author", kind: :singular, target: "User", nullable: false, polymorphic: false },
        { name: "posts", kind: :collection, target: "Post", nullable: nil, polymorphic: false },
        { name: "profile", kind: :singular, target: "Profile", nullable: true, polymorphic: false }
      ],
      enums: {},
      scopes: [],
      validations: [],
      callbacks: [],
      aliases: {}
    }
  end

  # The published fact itself: a plain Hash keyed by class name — exactly what
  # `services.fact_store.read(plugin_id: "activerecord", name: :model_index)` returns, never a `ModelIndex`
  # object.
  let(:model_index) { { "User" => user_entry } }

  # Drives the plugin's per-node path (ADR-37): the engine walks with ancestors and the Analyzer's per-node
  # `violations_for` validates each matcher against the (innermost enclosing) describe-model anchor. This
  # mirrors exactly what `node_rule` + `Base#diagnostic` do, returning real `Diagnostic` rows so the assertions
  # below are unchanged.
  def diagnose(source, index: model_index)
    root = Prism.parse(source).value
    diagnostics = []
    Rigor::Source::NodeWalker.each_with_ancestors(root) do |node, ancestors|
      next unless node.is_a?(Prism::CallNode)

      Rigor::Plugin::ShouldaMatchers::Analyzer.violations_for(
        matcher_call: node, ancestors: ancestors, model_index: index
      ).each do |violation|
        diagnostics << Rigor::Analysis::Diagnostic.from_location(
          node.message_loc || node.location, path: "spec/user_spec.rb",
                                             message: violation.message, severity: :warning, rule: violation.rule
        )
      end
    end
    diagnostics
  end

  describe "column matchers" do
    it "is silent for a known column" do
      diags = diagnose(<<~RUBY)
        RSpec.describe User do
          it { should validate_presence_of(:email) }
        end
      RUBY
      expect(diags).to be_empty
    end

    it "fires unknown-column for a missing column" do
      diags = diagnose(<<~RUBY)
        RSpec.describe User do
          it { should validate_presence_of(:nme) }
        end
      RUBY
      err = diags.find { |d| d.rule == "unknown-column" }
      expect(err).not_to be_nil
      expect(err.severity).to eq(:warning)
      expect(err.message).to include("nme")
      expect(err.message).to include("User")
    end

    it "fires for validate_uniqueness_of typo" do
      diags = diagnose(<<~RUBY)
        RSpec.describe User do
          it { should validate_uniqueness_of(:emial) }
        end
      RUBY
      err = diags.find { |d| d.rule == "unknown-column" }
      expect(err).not_to be_nil
      expect(err.message).to include("validate_uniqueness_of")
      expect(err.message).to include("emial")
    end

    it "fires for have_db_column typo" do
      diags = diagnose(<<~RUBY)
        RSpec.describe User do
          it { should have_db_column(:nonexistent) }
        end
      RUBY
      err = diags.find { |d| d.rule == "unknown-column" }
      expect(err).not_to be_nil
    end

    it "lists the known columns in the diagnostic message" do
      diags = diagnose(<<~RUBY)
        RSpec.describe User do
          it { should validate_presence_of(:typo) }
        end
      RUBY
      err = diags.find { |d| d.rule == "unknown-column" }
      expect(err.message).to include("created_at")
      expect(err.message).to include("email")
    end
  end

  describe "association matchers" do
    it "is silent for a known singular association under belong_to" do
      diags = diagnose(<<~RUBY)
        RSpec.describe User do
          it { should belong_to(:author) }
        end
      RUBY
      expect(diags).to be_empty
    end

    it "fires unknown-association for a missing association" do
      diags = diagnose(<<~RUBY)
        RSpec.describe User do
          it { should belong_to(:nonexistent) }
        end
      RUBY
      err = diags.find { |d| d.rule == "unknown-association" }
      expect(err).not_to be_nil
      expect(err.message).to include("nonexistent")
    end

    it "fires association-kind-mismatch for belong_to on a :collection" do
      # `posts` is a :collection association; `belong_to` expects :singular.
      diags = diagnose(<<~RUBY)
        RSpec.describe User do
          it { should belong_to(:posts) }
        end
      RUBY
      err = diags.find { |d| d.rule == "association-kind-mismatch" }
      expect(err).not_to be_nil
      expect(err.message).to include("collection")
      expect(err.message).to include("singular")
    end

    it "fires association-kind-mismatch for have_many on a :singular" do
      diags = diagnose(<<~RUBY)
        RSpec.describe User do
          it { should have_many(:author) }
        end
      RUBY
      err = diags.find { |d| d.rule == "association-kind-mismatch" }
      expect(err).not_to be_nil
      expect(err.message).to include("singular")
      expect(err.message).to include("collection")
    end

    it "is silent for have_many on a :collection" do
      diags = diagnose(<<~RUBY)
        RSpec.describe User do
          it { should have_many(:posts) }
        end
      RUBY
      expect(diags).to be_empty
    end

    it "is silent for have_one on a :singular" do
      diags = diagnose(<<~RUBY)
        RSpec.describe User do
          it { should have_one(:profile) }
        end
      RUBY
      expect(diags).to be_empty
    end
  end

  describe "describe anchor resolution" do
    it "inherits the outer model anchor through a nested describe" do
      # `describe ".active"` doesn't change the anchor; the column lookup still targets User.
      diags = diagnose(<<~RUBY)
        RSpec.describe User do
          describe ".active" do
            it { should validate_presence_of(:nme) }
          end
        end
      RUBY
      err = diags.find { |d| d.rule == "unknown-column" }
      expect(err).not_to be_nil
      expect(err.message).to include("User")
    end

    it "uses the nested model anchor when one is supplied" do
      # Synthetic case: nested `describe Comment` inside `describe User`. Inside Comment's body, the anchor is
      # Comment. We don't have Comment in the stub index, so nothing fires.
      diags = diagnose(<<~RUBY)
        RSpec.describe User do
          describe Comment do
            it { should validate_presence_of(:body) }
          end
        end
      RUBY
      expect(diags).to be_empty
    end

    it "is silent when there is no outer describe-with-constant" do
      diags = diagnose(<<~RUBY)
        describe "some method" do
          it { should validate_presence_of(:email) }
        end
      RUBY
      expect(diags).to be_empty
    end

    it "is silent when the matcher targets a model not in the index" do
      diags = diagnose(<<~RUBY)
        RSpec.describe UnknownModel do
          it { should validate_presence_of(:email) }
        end
      RUBY
      expect(diags).to be_empty
    end

    # #583 — the fact is keyed by the de-rooted class name, so a rooted `describe ::User` must anchor on
    # `"User"` exactly as `describe User` does; a `"::User"` anchor would miss the key silently.
    it "anchors a rooted `describe ::User` on the de-rooted key (must-fire)" do
      diags = diagnose(<<~RUBY)
        RSpec.describe ::User do
          it { should validate_presence_of(:nme) }
        end
      RUBY
      err = diags.find { |d| d.rule == "unknown-column" }
      expect(err).not_to be_nil
      expect(err.message).to include("User")
    end

    it "stays silent for a known column under a rooted `describe ::User` (must-not-fire)" do
      diags = diagnose(<<~RUBY)
        RSpec.describe ::User do
          it { should validate_presence_of(:email) }
        end
      RUBY
      expect(diags).to be_empty
    end
  end

  describe "no model_index available" do
    it "falls silent — the cross-check is opt-in" do
      diags = diagnose(<<~RUBY, index: nil)
        RSpec.describe User do
          it { should validate_presence_of(:totally_typoed) }
        end
      RUBY
      expect(diags).to be_empty
    end
  end

  describe "matcher invocation contexts" do
    it "fires through expect(...).to MATCHER chain" do
      diags = diagnose(<<~RUBY)
        RSpec.describe User do
          it { expect(subject).to validate_presence_of(:nme) }
        end
      RUBY
      err = diags.find { |d| d.rule == "unknown-column" }
      expect(err).not_to be_nil
    end

    it "fires through is_expected.to MATCHER" do
      diags = diagnose(<<~RUBY)
        RSpec.describe User do
          it { is_expected.to belong_to(:nonexistent) }
        end
      RUBY
      err = diags.find { |d| d.rule == "unknown-association" }
      expect(err).not_to be_nil
    end

    it "fires through subject.should MATCHER" do
      diags = diagnose(<<~RUBY)
        RSpec.describe User do
          it { subject.should validate_presence_of(:nme) }
        end
      RUBY
      err = diags.find { |d| d.rule == "unknown-column" }
      expect(err).not_to be_nil
    end
  end

  # #573 regression coverage: drives the FULL producer → consumer path through `Rigor::Analysis::Runner` —
  # rigor-activerecord parses a real `db/schema.rb` + model and publishes the real `:model_index` Hash via
  # `#prepare`; rigor-shoulda-matchers reads it via `read_fact` and validates a real spec file's matchers
  # against it. Every test above stubs the fact (now Hash-shaped); this block is what actually proves the two
  # plugins agree on the wire shape — a hand-rolled stub, however shaped, can still drift from what
  # `Activerecord#index_to_published_hash` really emits.
  describe "cross-plugin integration (real :model_index fact from rigor-activerecord)" do
    let(:schema_for_integration) do
      <<~SCHEMA
        ActiveRecord::Schema.define do
          create_table :users do |t|
            t.string :name
            t.string :email
          end
        end
      SCHEMA
    end

    let(:user_model_for_integration) do
      <<~RUBY
        class User < ApplicationRecord
        end
      RUBY
    end

    def with_real_model_index(spec_source)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        FileUtils.mkdir_p(File.join(dir, "db"))
        FileUtils.mkdir_p(File.join(dir, "spec"))
        File.write(File.join(dir, "db", "schema.rb"), schema_for_integration)
        File.write(File.join(dir, "app", "models", "user.rb"), user_model_for_integration)
        File.write(File.join(dir, "spec", "user_spec.rb"), spec_source)

        configuration = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge(
            "paths" => [File.join(dir, "spec")],
            "plugins" => %w[rigor-activerecord rigor-shoulda-matchers]
          )
        )

        Dir.chdir(dir) do
          runner = Rigor::Analysis::Runner.new(
            configuration: configuration,
            cache_store: nil,
            plugin_requirer: lambda do |name|
              case File.basename(name, ".rb")
              when "rigor-activerecord" then Rigor::Plugin.register(Rigor::Plugin::Activerecord)
              when "rigor-shoulda-matchers" then Rigor::Plugin.register(Rigor::Plugin::ShouldaMatchers)
              end
              true
            end
          )
          yield runner.run
        end
      end
    end

    def shoulda_diagnostics(result)
      result.diagnostics.select { |d| d.source_family == "plugin.shoulda-matchers" }
    end

    it "fires unknown-column for an unknown column (must-fire)" do
      with_real_model_index(<<~RUBY) do |result|
        RSpec.describe User do
          it { should have_db_column(:nonexistent) }
        end
      RUBY
        diags = shoulda_diagnostics(result)
        err = diags.find { |d| d.rule == "unknown-column" }
        expect(err).not_to be_nil
        expect(err.severity).to eq(:warning)
        expect(err.message).to include("nonexistent")
        expect(err.message).to include("User")

        # Regression guard: `Hash#find(anchor)` (no block) used to return an Enumerator instead of the
        # entry, and calling `#column?` on it raised NoMethodError — which the engine isolates as ONE
        # `runtime-error` diagnostic for the whole file, in place of every real diagnostic below it.
        # The raise envelope is stamped `source_family: :plugin_loader`, NOT the plugin's own family,
        # so this must scan the UNFILTERED diagnostics — the filtered set can never contain it.
        expect(result.diagnostics.map(&:rule)).not_to include("runtime-error")
      end
    end

    it "stays silent for a known column (must-not-fire)" do
      with_real_model_index(<<~RUBY) do |result|
        RSpec.describe User do
          it { should have_db_column(:email) }
        end
      RUBY
        diags = shoulda_diagnostics(result)
        expect(diags.map(&:rule)).not_to include("unknown-column")
        expect(result.diagnostics.map(&:rule)).not_to include("runtime-error")
      end
    end

    # #583 — a model declared `class ::User` used to reach this consumer keyed `"::User"` in the real fact,
    # so the `describe User` anchor missed it and every matcher check stood down silently. The producer now
    # publishes the de-rooted key; this is the end-to-end proof through the real `:model_index` fact.
    context "with a model declared `class ::User`" do
      let(:user_model_for_integration) do
        <<~RUBY
          class ::User < ApplicationRecord
          end
        RUBY
      end

      it "fires unknown-column through the real fact (must-fire)" do
        with_real_model_index(<<~RUBY) do |result|
          RSpec.describe User do
            it { should have_db_column(:nonexistent) }
          end
        RUBY
          err = shoulda_diagnostics(result).find { |d| d.rule == "unknown-column" }
          expect(err).not_to be_nil
          expect(err.message).to include("nonexistent")
          expect(err.message).to include("User")
          expect(result.diagnostics.map(&:rule)).not_to include("runtime-error")
        end
      end

      it "fires under a rooted `describe ::User` too (must-fire)" do
        with_real_model_index(<<~RUBY) do |result|
          RSpec.describe ::User do
            it { should have_db_column(:nonexistent) }
          end
        RUBY
          err = shoulda_diagnostics(result).find { |d| d.rule == "unknown-column" }
          expect(err).not_to be_nil
          expect(err.message).to include("nonexistent")
        end
      end

      it "stays silent for a known column (must-not-fire)" do
        with_real_model_index(<<~RUBY) do |result|
          RSpec.describe User do
            it { should have_db_column(:email) }
          end
        RUBY
          expect(shoulda_diagnostics(result).map(&:rule)).not_to include("unknown-column")
          expect(result.diagnostics.map(&:rule)).not_to include("runtime-error")
        end
      end
    end
  end
end
