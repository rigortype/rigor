# frozen_string_literal: true

RSpec.describe Rigor::Analysis::Diagnostic do
  it "formats a stable human-readable diagnostic" do
    diagnostic = described_class.new(
      path: "lib/example.rb",
      line: 3,
      column: 7,
      message: "unexpected token",
      severity: :error
    )

    expect(diagnostic.to_s).to eq("lib/example.rb:3:7: error: unexpected token")
    expect(diagnostic.to_h).to include(
      "path" => "lib/example.rb",
      "line" => 3,
      "column" => 7,
      "severity" => "error"
    )
  end
end
