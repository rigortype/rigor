# frozen_string_literal: true

# ADR-39 — `have_http_status` symbol validation reads the REAL `Rack::Utils::SYMBOL_TO_STATUS_CODE` (the repo
# bundle carries `rack` as a development dependency), never a vendored snapshot that could go stale. When Rack
# is unavailable the accepted set is unknowable, so the check declines rather than emitting a false `unknown-symbol`.

require "spec_helper"

RSPEC_RAILS_HSC_LIB = File.expand_path("../../../plugins/rigor-rspec-rails/lib", __dir__)
$LOAD_PATH.unshift(RSPEC_RAILS_HSC_LIB) unless $LOAD_PATH.include?(RSPEC_RAILS_HSC_LIB)
require "rigor-rspec-rails"

RSpec.describe "plugins/rigor-rspec-rails — HttpStatusCodes (ADR-39)" do
  let(:described_class) { Rigor::Plugin::RspecRails::HttpStatusCodes }

  describe ".known_symbols (real Rack in the dev bundle)" do
    it "draws the status symbols from the real Rack::Utils catalogue" do
      require "rack/utils"
      known = described_class.known_symbols
      expect(known).to be_a(Set)
      # Every real Rack symbol is accepted — including any the old
      # vendored snapshot might have lagged.
      Rack::Utils::SYMBOL_TO_STATUS_CODE.each_key do |sym|
        expect(known).to include(sym)
      end
    end

    it "unions the stable Rails status-group aliases" do
      expect(described_class.known_symbols)
        .to include(:success, :missing, :redirect, :error, :informational)
    end
  end

  describe ".known_symbols when Rack is unavailable" do
    before { allow(described_class).to receive(:rack_status_symbols).and_return(nil) }

    # ADR-39: decline, never guess from a stale copy.
    it "returns nil so the caller declines to flag any symbol" do
      expect(described_class.known_symbols).to be_nil
    end
  end
end
