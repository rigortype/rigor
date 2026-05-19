# frozen_string_literal: true

# Integration spec for `plugins/rigor-rspec-rails/`.
# v0.1.0 covers `have_http_status(int_or_symbol)` validation
# only — the larger behavioral matcher surface (render_template
# / route_to / redirect_to / have_enqueued_job / have_received)
# is deferred per the README's "Deferred matchers" section.

require "spec_helper"

RSPEC_RAILS_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-rspec-rails/lib", __dir__)
$LOAD_PATH.unshift(RSPEC_RAILS_PLUGIN_LIB) unless $LOAD_PATH.include?(RSPEC_RAILS_PLUGIN_LIB)
require "rigor-rspec-rails"

RSpec.describe "plugins/rigor-rspec-rails" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::RspecRails }

  def diagnostics_for(source)
    result = run_plugin(source: source)
    plugin_diagnostics(result)
  end

  describe "have_http_status — numeric arg" do
    it "is silent for a valid 2xx status" do
      diags = diagnostics_for("expect(response).to have_http_status(200)\n")
      expect(diags).to be_empty
    end

    it "is silent for the lower bound (100)" do
      diags = diagnostics_for("expect(response).to have_http_status(100)\n")
      expect(diags).to be_empty
    end

    it "is silent for the upper bound (599)" do
      diags = diagnostics_for("expect(response).to have_http_status(599)\n")
      expect(diags).to be_empty
    end

    it "fires out-of-range below 100" do
      diags = diagnostics_for("expect(response).to have_http_status(99)\n")
      err = diags.find { |d| d.rule == "have_http_status.out-of-range" }
      expect(err).not_to be_nil
      expect(err.severity).to eq(:warning)
      expect(err.message).to include("99")
      expect(err.message).to include("100..599")
    end

    it "fires out-of-range above 599" do
      diags = diagnostics_for("expect(response).to have_http_status(600)\n")
      err = diags.find { |d| d.rule == "have_http_status.out-of-range" }
      expect(err).not_to be_nil
      expect(err.message).to include("600")
    end
  end

  describe "have_http_status — symbol arg" do
    it "is silent for a recognised standard symbol (:ok)" do
      diags = diagnostics_for("expect(response).to have_http_status(:ok)\n")
      expect(diags).to be_empty
    end

    it "is silent for a recognised standard symbol (:not_found)" do
      diags = diagnostics_for("expect(response).to have_http_status(:not_found)\n")
      expect(diags).to be_empty
    end

    it "is silent for a Rails status-group alias (:success)" do
      diags = diagnostics_for("expect(response).to have_http_status(:success)\n")
      expect(diags).to be_empty
    end

    it "is silent for the :successful 2xx alias" do
      diags = diagnostics_for("expect(response).to have_http_status(:successful)\n")
      expect(diags).to be_empty
    end

    it "is silent for the :missing (404) alias" do
      diags = diagnostics_for("expect(response).to have_http_status(:missing)\n")
      expect(diags).to be_empty
    end

    it "is silent for the :redirect alias" do
      diags = diagnostics_for("expect(response).to have_http_status(:redirect)\n")
      expect(diags).to be_empty
    end

    it "is silent for the :error / :server_error aliases" do
      diags = diagnostics_for(<<~RUBY)
        expect(response).to have_http_status(:error)
        expect(response).to have_http_status(:server_error)
      RUBY
      expect(diags).to be_empty
    end

    it "is silent for the new :unprocessable_content alias (Rails 7.2+)" do
      # Newer Rails uses `:unprocessable_content` as a synonym
      # of `:unprocessable_entity` (422); recognise both.
      diags = diagnostics_for("expect(response).to have_http_status(:unprocessable_content)\n")
      expect(diags).to be_empty
    end

    it "fires unknown-symbol on a typo (:succes — missing 's')" do
      diags = diagnostics_for("expect(response).to have_http_status(:succes)\n")
      err = diags.find { |d| d.rule == "have_http_status.unknown-symbol" }
      expect(err).not_to be_nil
      expect(err.severity).to eq(:warning)
      expect(err.message).to include(":succes")
    end

    it "fires unknown-symbol on a misspelling (:not_fund)" do
      diags = diagnostics_for("expect(response).to have_http_status(:not_fund)\n")
      err = diags.find { |d| d.rule == "have_http_status.unknown-symbol" }
      expect(err).not_to be_nil
      expect(err.message).to include(":not_fund")
    end
  end

  describe "have_http_status — non-statically-checkable args" do
    it "is silent for a variable arg" do
      diags = diagnostics_for(<<~RUBY)
        expected = compute_status
        expect(response).to have_http_status(expected)
      RUBY
      have_diags = diags.select { |d| d.rule.start_with?("have_http_status") }
      expect(have_diags).to be_empty
    end

    it "is silent for a method-call arg" do
      diags = diagnostics_for("expect(response).to have_http_status(api_status)\n")
      have_diags = diags.select { |d| d.rule.start_with?("have_http_status") }
      expect(have_diags).to be_empty
    end

    it "is silent for a String arg (Rails accepts string literals too)" do
      # The plugin intentionally skips the String form rather
      # than parse / validate the numeric content.
      diags = diagnostics_for("expect(response).to have_http_status(\"200\")\n")
      have_diags = diags.select { |d| d.rule.start_with?("have_http_status") }
      expect(have_diags).to be_empty
    end
  end

  describe "matcher invocation context" do
    it "fires on the bare `have_http_status(arg)` matcher form" do
      # Some specs call `should have_http_status(404)` or use
      # the matcher inside a custom matcher composition. The
      # diagnostic should still fire because the matcher
      # itself is recognised regardless of the surrounding
      # chain.
      diags = diagnostics_for("should have_http_status(700)\n")
      err = diags.find { |d| d.rule == "have_http_status.out-of-range" }
      expect(err).not_to be_nil
    end

    it "fires on `.not_to have_http_status(typo)`" do
      diags = diagnostics_for("expect(response).not_to have_http_status(:succes)\n")
      err = diags.find { |d| d.rule == "have_http_status.unknown-symbol" }
      expect(err).not_to be_nil
    end
  end
end
