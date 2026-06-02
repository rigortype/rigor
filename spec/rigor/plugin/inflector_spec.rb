# frozen_string_literal: true

require "spec_helper"

# ADR-39 — the shared inflection helper. It inflects ONLY with the real
# `ActiveSupport::Inflector` (no built-in approximation, which would be a
# source of wrong facts → false positives). The repo bundle carries
# `activesupport` as a development dependency (see rigortype.gemspec), so
# the suite exercises the real path; absence is covered by stubbing the
# loader to confirm it raises rather than guesses.
RSpec.describe Rigor::Plugin::Inflector do
  describe "with the real ActiveSupport::Inflector (bundled in dev)" do
    it "is available in the repo bundle" do
      expect(described_class.available?).to be(true)
    end

    it "resolves regular inflections" do
      expect(described_class.pluralize("post")).to eq("posts")
      expect(described_class.singularize("categories")).to eq("category")
      expect(described_class.underscore("BlogPost")).to eq("blog_post")
      expect(described_class.camelize("blog_post")).to eq("BlogPost")
      expect(described_class.tableize("BlogPost")).to eq("blog_posts")
      expect(described_class.classify("blog_posts")).to eq("BlogPost")
    end

    # The whole point of ADR-39: the irregulars a hand-rolled
    # approximation gets wrong are authoritative because the real
    # inflector answers.
    it "resolves irregular inflections an approximation would miss" do
      expect(described_class.pluralize("person")).to eq("people")
      expect(described_class.pluralize("child")).to eq("children")
      expect(described_class.pluralize("analysis")).to eq("analyses")
      expect(described_class.singularize("people")).to eq("person")
      expect(described_class.singularize("analyses")).to eq("analysis")
    end

    it "flattens namespaced names like Rails" do
      expect(described_class.underscore("Admin::DomainBlocksController"))
        .to eq("admin/domain_blocks_controller")
      # tableize composes underscore + pluralize with ::->_ flattening,
      # matching AR's real table name (NOT Inflector.tableize's admin/users).
      expect(described_class.tableize("Admin::User")).to eq("admin_users")
    end
  end

  describe "when ActiveSupport::Inflector cannot be reached" do
    # Simulate the library being unreachable under the configured isolation
    # strategy: Isolation.call raises Unavailable, which Inflector re-raises
    # as its own Unavailable (never approximating).
    before do
      allow(Rigor::Plugin::Isolation).to receive(:call)
        .and_raise(Rigor::Plugin::Isolation::Unavailable, "...add `activesupport`...")
    end

    it "reports unavailable rather than guessing" do
      expect(described_class.available?).to be(false)
    end

    # No approximation: every inflection raises a clear Unavailable error
    # (the caller's per-plugin rescue turns this into silence — reduced
    # coverage, never a wrong inflection / false positive).
    it "raises Unavailable instead of returning an approximation" do
      expect { described_class.pluralize("person") }
        .to raise_error(Rigor::Plugin::Inflector::Unavailable)
      expect { described_class.tableize("BlogPost") }
        .to raise_error(Rigor::Plugin::Inflector::Unavailable)
    end
  end

  it "rejects a non-allow-listed method" do
    expect { described_class.invoke(:constantize, "Foo") }
      .to raise_error(ArgumentError, /allow-listed/)
  end
end
