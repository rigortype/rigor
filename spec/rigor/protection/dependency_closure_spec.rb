# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

require "rigor/configuration"
require "rigor/language_server/project_context"
require "rigor/protection/dependency_closure"

# Issue #254 — the ADR-46 reverse edge the Tier-2 closure oracle reads, built once by one recording pass.
RSpec.describe Rigor::Protection::DependencyClosure do
  describe ".index" do
    it "keeps only measured dependents, drops the self-edge, and sorts" do
      dependents = {
        "lib/a.rb" => Set["lib/c.rb", "lib/b.rb", "lib/a.rb", "spec/a_spec.rb"],
        "lib/b.rb" => Set["lib/a.rb"]
      }

      index = described_class.index(dependents, %w[lib/a.rb lib/b.rb lib/c.rb])

      # `spec/a_spec.rb` is outside the measured set: re-analysing it would report diagnostics against a file
      # the run never baselined.
      expect(index).to eq("lib/a.rb" => %w[lib/b.rb lib/c.rb], "lib/b.rb" => %w[lib/a.rb], "lib/c.rb" => [])
    end

    it "answers with an empty list for a path nothing reads from" do
      expect(described_class.index({}, %w[lib/lonely.rb])).to eq("lib/lonely.rb" => [])
    end
  end

  describe ".build" do
    around do |example|
      Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
    end

    # The recording pass must see cross-file reads, which is why it cannot reuse the caller's `prebuilt:` scan
    # (`Runner#ensure_project_discovery` is a no-op under it, and the recorded graph would be silently empty).
    it "records the caller of a sibling-file class as its dependent" do
      FileUtils.mkdir_p("lib")
      File.write("lib/account.rb", "class Account\n  def self.label\n    \"account\"\n  end\nend\n")
      File.write("lib/service.rb", "def lookup\n  Account.label.upcase\nend\n")
      configuration = Rigor::Configuration.load(nil)
      context = Rigor::LanguageServer::ProjectContext.new(configuration: configuration)

      index = described_class.build(
        paths: %w[lib/account.rb lib/service.rb], configuration: configuration,
        environment: context.environment, cache_store: context.cache_store
      )

      expect(index).to eq("lib/account.rb" => ["lib/service.rb"], "lib/service.rb" => [])
    end
  end
end
