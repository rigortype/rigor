# frozen_string_literal: true

require "spec_helper"

# ADR-39 — the shared inflection helper. The repo bundle carries
# `activesupport` as a development dependency (see rigortype.gemspec), so
# in the suite the real `ActiveSupport::Inflector` path is exercised; the
# `Fallback` module is tested directly for the gem-absent degradation.
RSpec.describe Rigor::Plugin::Inflector do
  describe "with the real ActiveSupport::Inflector (bundled in dev)" do
    it "is available in the repo bundle" do
      expect(described_class.active_support_available?).to be(true)
    end

    it "resolves regular inflections" do
      expect(described_class.pluralize("post")).to eq("posts")
      expect(described_class.singularize("categories")).to eq("category")
      expect(described_class.underscore("BlogPost")).to eq("blog_post")
      expect(described_class.camelize("blog_post")).to eq("BlogPost")
      expect(described_class.tableize("BlogPost")).to eq("blog_posts")
      expect(described_class.classify("blog_posts")).to eq("BlogPost")
    end

    # The whole point of ADR-39: the irregulars the former hand-rolled
    # copies got wrong are now authoritative.
    it "resolves irregular inflections the hand-rolled copies missed" do
      expect(described_class.pluralize("person")).to eq("people")
      expect(described_class.pluralize("child")).to eq("children")
      expect(described_class.pluralize("analysis")).to eq("analyses")
      expect(described_class.singularize("people")).to eq("person")
      expect(described_class.singularize("analyses")).to eq("analysis")
    end

    it "flattens namespaced names like Rails" do
      expect(described_class.underscore("Admin::DomainBlocksController"))
        .to eq("admin/domain_blocks_controller")
      expect(described_class.tableize("Admin::User")).to eq("admin_users")
    end
  end

  describe Rigor::Plugin::Inflector::Fallback do
    it "covers the regular cases without ActiveSupport" do
      expect(described_class.pluralize("post")).to eq("posts")
      expect(described_class.pluralize("category")).to eq("categories")
      expect(described_class.pluralize("box")).to eq("boxes")
      expect(described_class.pluralize("wolf")).to eq("wolves")
      expect(described_class.singularize("categories")).to eq("category")
      expect(described_class.singularize("wolves")).to eq("wolf")
      expect(described_class.underscore("BlogPost")).to eq("blog_post")
      expect(described_class.classify("blog_posts")).to eq("BlogPost")
    end

    it "covers the small irregular table it ships" do
      expect(described_class.pluralize("person")).to eq("people")
      expect(described_class.singularize("children")).to eq("child")
    end
  end

  describe "degradation when ActiveSupport is unavailable" do
    it "uses the fallback when the availability check is false" do
      allow(described_class).to receive(:active_support_available?).and_return(false)
      # `analysis` is beyond the fallback table, so it degrades to the
      # regular rule (`analyses`) rather than the AS-authoritative form —
      # acceptable for the gem-absent path, and never a crash.
      expect(described_class.pluralize("post")).to eq("posts")
      expect(described_class.underscore("BlogPost")).to eq("blog_post")
    end

    it "never raises, even on odd input" do
      expect { described_class.pluralize("") }.not_to raise_error
      expect { described_class.underscore("") }.not_to raise_error
    end
  end
end
