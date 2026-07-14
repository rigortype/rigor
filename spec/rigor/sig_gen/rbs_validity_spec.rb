# frozen_string_literal: true

require "rigor/sig_gen/rbs_validity"

# The guard that stops sig-gen poisoning its own consumer: an emitted `.rbs` that `rbs` cannot parse is
# quarantined whole by `rigor check`, so every type in that file vanishes — and for a project adopting
# `reject-unparseable-signatures`, the build fails. The oracle here is `RBS::Parser` itself, i.e. exactly the
# parser the consumer will use, not an approximation of it.
RSpec.describe Rigor::SigGen::RbsValidity do
  describe ".method_line_error" do
    it "accepts a well-formed instance method line" do
      expect(described_class.method_line_error("def size: () -> Integer")).to be_nil
    end

    it "accepts a singleton and a module_function line" do
      expect(described_class.method_line_error("def self.parse: (String) -> Integer")).to be_nil
      expect(described_class.method_line_error("def self?.helper: () -> void")).to be_nil
    end

    it "accepts a nil line (a skipped candidate renders nothing)" do
      expect(described_class.method_line_error(nil)).to be_nil
    end

    # The two rendering bugs that actually shipped. They are the reason this guard exists, so they are pinned
    # as the shapes it must reject — not because these exact bugs can recur (both are fixed), but because the
    # guard's whole value is catching the NEXT one like them.
    it "rejects a non-identifier record key (the mastodon `data-contrast:` bug)" do
      error = described_class.method_line_error("def h: () -> { data-contrast: Integer }")
      expect(error).to include("record key")
    end

    it "rejects a block param rendered before the parens (the `&block` constructor bug)" do
      error = described_class.method_line_error("def initialize: (**untyped, ?{ (?) -> void })")
      expect(error).not_to be_nil
    end
  end

  describe ".source_error" do
    it "accepts a well-formed file" do
      source = "module Acme\n  class Widget\n    def size: () -> Integer\n  end\nend\n"
      expect(described_class.source_error(source)).to be_nil
    end

    it "reports the parse error of a malformed file" do
      source = "class Broken\n  def h: () -> { data-contrast: Integer }\nend\n"
      expect(described_class.source_error(source)).to include("record key")
    end
  end
end
