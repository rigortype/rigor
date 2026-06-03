# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::MethodDispatcher::CGIFolding do
  def cgi_singleton = Rigor::Type::Combinator.singleton_of("CGI")
  def c(value)      = Rigor::Type::Combinator.constant_of(value)

  def fold(method_name, *arg_types)
    described_class.try_dispatch(cc(
                                   receiver: cgi_singleton,
                                   method_name: method_name,
                                   args: arg_types
                                 ))
  end

  # ── escapeHTML / escape_html / h ──────────────────────────────────────

  describe "escapeHTML / escape_html / h" do
    it "escapes <, >, &, \" to HTML entities" do
      expect(fold(:escapeHTML, c('<p class="x">&</p>')))
        .to eq(c("&lt;p class=&quot;x&quot;&gt;&amp;&lt;/p&gt;"))
    end

    it "returns plain strings unchanged" do
      expect(fold(:escapeHTML, c("hello"))).to eq(c("hello"))
    end

    it "treats escape_html as an alias" do
      expect(fold(:escape_html, c("<b>"))).to eq(c("&lt;b&gt;"))
    end

    it "treats h as an alias" do
      expect(fold(:h, c("<b>"))).to eq(c("&lt;b&gt;"))
    end
  end

  # ── unescapeHTML / unescape_html ──────────────────────────────────────

  describe "unescapeHTML / unescape_html" do
    it "unescapes HTML entities back to raw characters" do
      expect(fold(:unescapeHTML, c("&lt;p&gt;&amp;&lt;/p&gt;")))
        .to eq(c("<p>&</p>"))
    end

    it "returns plain strings unchanged" do
      expect(fold(:unescapeHTML, c("hello"))).to eq(c("hello"))
    end

    it "treats unescape_html as an alias" do
      expect(fold(:unescape_html, c("&lt;b&gt;"))).to eq(c("<b>"))
    end
  end

  # ── escape / unescape (URL) ───────────────────────────────────────────

  describe "CGI.escape / unescape (URL)" do
    it "URL-encodes special characters" do
      expect(fold(:escape, c("hello world"))).to eq(c("hello+world"))
    end

    it "URL-decodes" do
      expect(fold(:unescape, c("hello+world"))).to eq(c("hello world"))
    end
  end

  # ── escapeURIComponent / escape_uri_component ─────────────────────────

  describe "CGI.escapeURIComponent / escape_uri_component" do
    it "percent-encodes special characters" do
      expect(fold(:escapeURIComponent, c("hello world"))).to eq(c("hello%20world"))
    end

    it "treats escape_uri_component as an alias" do
      expect(fold(:escape_uri_component, c("a b"))).to eq(c("a%20b"))
    end
  end

  # ── unescapeURIComponent ──────────────────────────────────────────────

  describe "CGI.unescapeURIComponent" do
    it "percent-decodes" do
      expect(fold(:unescapeURIComponent, c("hello%20world"))).to eq(c("hello world"))
    end
  end

  # ── escapeElement / escape_element ────────────────────────────────────

  describe "CGI.escapeElement / escape_element" do
    it "escapes only the named HTML elements" do
      result = fold(:escapeElement, c('<A HREF="url">link</A>'), c("A"), c("IMG"))
      expect(result).to be_a(Rigor::Type::Constant)
      expect(result.value).to be_a(String)
      expect(result.value).to include("&lt;")
    end

    it "treats escape_element as an alias" do
      expect(fold(:escape_element, c("<br>"), c("br"))).to eq(fold(:escapeElement, c("<br>"), c("br")))
    end

    it "declines when element args are non-Constant" do
      expect(fold(:escapeElement, c("<br>"), Rigor::Type::Combinator.nominal_of("String"))).to be_nil
    end
  end

  # ── Decline / edge cases ──────────────────────────────────────────────

  describe "decline cases" do
    it "declines for a non-Constant argument" do
      expect(fold(:escapeHTML, Rigor::Type::Combinator.nominal_of("String"))).to be_nil
    end

    it "declines for a non-String constant" do
      expect(fold(:escapeHTML, c(42))).to be_nil
    end

    it "declines for a non-Singleton receiver" do
      result = described_class.try_dispatch(cc(
                                              receiver: c("CGI"),
                                              method_name: :escapeHTML,
                                              args: [c("hello")]
                                            ))
      expect(result).to be_nil
    end

    it "declines for a wrong singleton class" do
      result = described_class.try_dispatch(cc(
                                              receiver: Rigor::Type::Combinator.singleton_of("String"),
                                              method_name: :escapeHTML,
                                              args: [c("hello")]
                                            ))
      expect(result).to be_nil
    end

    it "declines for an unsupported method" do
      expect(fold(:parse, c("hello"))).to be_nil
    end

    it "declines when the argument list is empty" do
      expect(fold(:escapeHTML)).to be_nil
    end
  end
end
