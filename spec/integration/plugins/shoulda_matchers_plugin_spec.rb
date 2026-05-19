# frozen_string_literal: true

# Integration spec for `plugins/rigor-shoulda-matchers/`.
# Validates shoulda matchers against the :model_index
# cross-plugin fact (ADR-9) published by rigor-activerecord.
#
# Tests exercise the Analyzer module directly with a stub
# model_index — the full integration through
# rigor-activerecord's producer is covered by the
# activerecord plugin spec; here we pin the matcher
# recogniser shape independently so a future rigor-activerecord
# refactor can't accidentally break the matcher contract.

require "spec_helper"

SHOULDA_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-shoulda-matchers/lib", __dir__)
$LOAD_PATH.unshift(SHOULDA_PLUGIN_LIB) unless $LOAD_PATH.include?(SHOULDA_PLUGIN_LIB)
require "rigor-shoulda-matchers"

RSpec.describe "plugins/rigor-shoulda-matchers" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::ShouldaMatchers }

  # Minimal stub model_index. Mirrors the surface
  # rigor-activerecord's ModelIndex exposes (`find` returning
  # an Entry that responds to `column?` / `association?` /
  # `association` / `column_names` / `association_names`).
  let(:user_entry) do
    Class.new do
      def initialize(columns:, associations:)
        @columns = columns
        @associations = associations
      end

      def column?(name) = @columns.include?(name.to_sym)
      def column_names = @columns.map(&:to_s)
      def association?(name) = @associations.any? { |a| a[:name] == name.to_s }
      def association(name) = @associations.find { |a| a[:name] == name.to_s }
      def association_names = @associations.map { |a| a[:name] }
    end.new(
      columns: %i[id email name created_at],
      associations: [
        { name: "author", kind: :singular, target: "User" },
        { name: "posts", kind: :collection, target: "Post" },
        { name: "profile", kind: :singular, target: "Profile" }
      ]
    )
  end

  let(:model_index) do
    entries = { "User" => user_entry }
    Class.new do
      def initialize(entries) = @entries = entries
      def find(class_name) = @entries[class_name.to_s]
    end.new(entries)
  end

  def diagnose(source, index: model_index)
    root = Prism.parse(source).value
    Rigor::Plugin::ShouldaMatchers::Analyzer.diagnose(
      path: "spec/user_spec.rb", root: root, model_index: index
    )
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
      err = diags.find { |d| d.rule == "shoulda-matchers.unknown-column" }
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
      err = diags.find { |d| d.rule == "shoulda-matchers.unknown-column" }
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
      err = diags.find { |d| d.rule == "shoulda-matchers.unknown-column" }
      expect(err).not_to be_nil
    end

    it "lists the known columns in the diagnostic message" do
      diags = diagnose(<<~RUBY)
        RSpec.describe User do
          it { should validate_presence_of(:typo) }
        end
      RUBY
      err = diags.find { |d| d.rule == "shoulda-matchers.unknown-column" }
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
      err = diags.find { |d| d.rule == "shoulda-matchers.unknown-association" }
      expect(err).not_to be_nil
      expect(err.message).to include("nonexistent")
    end

    it "fires association-kind-mismatch for belong_to on a :collection" do
      # `posts` is a :collection association; `belong_to`
      # expects :singular.
      diags = diagnose(<<~RUBY)
        RSpec.describe User do
          it { should belong_to(:posts) }
        end
      RUBY
      err = diags.find { |d| d.rule == "shoulda-matchers.association-kind-mismatch" }
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
      err = diags.find { |d| d.rule == "shoulda-matchers.association-kind-mismatch" }
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
      # `describe ".active"` doesn't change the anchor; the
      # column lookup still targets User.
      diags = diagnose(<<~RUBY)
        RSpec.describe User do
          describe ".active" do
            it { should validate_presence_of(:nme) }
          end
        end
      RUBY
      err = diags.find { |d| d.rule == "shoulda-matchers.unknown-column" }
      expect(err).not_to be_nil
      expect(err.message).to include("User")
    end

    it "uses the nested model anchor when one is supplied" do
      # Synthetic case: nested `describe Comment` inside
      # `describe User`. Inside Comment's body, the anchor is
      # Comment. We don't have Comment in the stub index, so
      # nothing fires.
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
      err = diags.find { |d| d.rule == "shoulda-matchers.unknown-column" }
      expect(err).not_to be_nil
    end

    it "fires through is_expected.to MATCHER" do
      diags = diagnose(<<~RUBY)
        RSpec.describe User do
          it { is_expected.to belong_to(:nonexistent) }
        end
      RUBY
      err = diags.find { |d| d.rule == "shoulda-matchers.unknown-association" }
      expect(err).not_to be_nil
    end

    it "fires through subject.should MATCHER" do
      diags = diagnose(<<~RUBY)
        RSpec.describe User do
          it { subject.should validate_presence_of(:nme) }
        end
      RUBY
      err = diags.find { |d| d.rule == "shoulda-matchers.unknown-column" }
      expect(err).not_to be_nil
    end
  end
end
