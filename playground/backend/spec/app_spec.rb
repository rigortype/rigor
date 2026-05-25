# frozen_string_literal: true

require "json"
require "rack/test"
require "rspec"

require_relative "../lib/playground/app"

# ADR-29 backend smoke tests. Runs against an in-process
# `Playground::App` via `Rack::Test::Methods`; no Puma boot.
#
# Run from `playground/backend/`:
#
#   bundle exec rspec spec/app_spec.rb
#
# These specs are intentionally separate from the main Rigor
# spec suite (`spec/` at the project root) because the
# playground backend has its own Gemfile (`puma`, `rack`,
# `rack-test`) and a different `BUNDLE_GEMFILE` boundary. They
# are NOT part of `make verify`.
RSpec.describe Playground::App do
  include Rack::Test::Methods

  let(:app) { described_class.new }

  # ADR-32 example: a method with `# @rbs name: :asc | :desc`
  # called with `:bad` must produce a `call.argument-type-mismatch`
  # diagnostic, even WITHOUT the `# rbs_inline: enabled` magic
  # comment — the playground sets `require_magic_comment: false`
  # per ADR-29 WD4 amendment + ADR-32 WD10.
  let(:ascdesc_source) do
    <<~RUBY
      class AscDesc
        # @rbs asc_or_desc: :asc | :desc
        def ascdesc(asc_or_desc)
          asc_or_desc
        end
      end

      AscDesc.new.ascdesc(:bad)
    RUBY
  end

  def post_check(source)
    post "/check", JSON.generate(source: source), "CONTENT_TYPE" => "application/json"
    expect(last_response.status).to eq(200)
    JSON.parse(last_response.body)
  end

  describe "POST /check" do
    it "returns JSON with diagnostics + error_count + success" do
      body = post_check("x = 1\nputs x\n")
      expect(body).to include("diagnostics", "error_count", "success")
      expect(body["diagnostics"]).to be_an(Array)
    end

    it "flags the ADR-32 ascdesc example without the magic comment (ADR-29 WD4 amendment)" do
      body = post_check(ascdesc_source)
      mismatches = body.fetch("diagnostics").select { |d| d["rule"] == "call.argument-type-mismatch" }
      expect(mismatches).not_to be_empty
      expect(mismatches.first.fetch("message")).to include(":asc | :desc")
      expect(mismatches.first.fetch("message")).to include(":bad")
      expect(body.fetch("error_count")).to be >= 1
      expect(body.fetch("success")).to be(false)
    end

    it "uses the virtual <playground> path label, not the tmpfile path" do
      body = post_check(ascdesc_source)
      paths = body.fetch("diagnostics").map { |d| d.fetch("path") }
      expect(paths.uniq).to eq(["<playground>"])
    end

    it "rejects source larger than 64 KB with a 413 response" do
      oversized = "x = 1\n" * 20_000 # ~120 KB
      post "/check", JSON.generate(source: oversized), "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to eq(413)
    end
  end

  describe "CORS" do
    it "allows the cross-origin preflight" do
      options "/check"
      expect(last_response.status).to eq(200)
      expect(last_response.headers["access-control-allow-origin"]).to eq("*")
    end
  end
end
