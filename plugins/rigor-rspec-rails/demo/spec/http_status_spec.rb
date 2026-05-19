# frozen_string_literal: true

# Worked example — rigor-rspec-rails fires
# `have_http_status.out-of-range` for numeric args outside
# 100..599 and `have_http_status.unknown-symbol` for typos
# in the symbol set. Recognised symbols / valid numerics
# stay silent.

RSpec.describe "HomeController" do
  it "every recognised shape stays silent" do
    expect(response).to have_http_status(200)       # OK
    expect(response).to have_http_status(:ok)       # OK
    expect(response).to have_http_status(:success)  # OK (2xx group alias)
    expect(response).to have_http_status(:missing)  # OK (404 alias)
  end

  it "fires out-of-range on numeric below 100" do
    expect(response).to have_http_status(99)        # warning: out-of-range
  end

  it "fires out-of-range on numeric above 599" do
    expect(response).to have_http_status(600)       # warning: out-of-range
  end

  it "fires unknown-symbol on a typo'd symbol" do
    expect(response).to have_http_status(:succes)   # warning: unknown-symbol
  end

  it "is silent on a variable arg (cannot prove statically)" do
    expected_status = compute_status
    expect(response).to have_http_status(expected_status) # OK — not statically checkable
  end
end
