# frozen_string_literal: true

require "spec_helper"

# The order pin of ADR-116 WD12, run from the typer's side too. `verify-changed` selects a spec by the `lib/` file
# it mirrors, so the specs under this directory run when `lib/rigor/inference/expression_typer.rb` changes, and
# an edit to the ladder there meets the tables it is held to before it is pushed. The rule, the reading and what
# it cannot see are in `spec/rigor/inference/call_ladder_spec.rb`.
RSpec.describe "ExpressionTyper's call ladder" do
  it_behaves_like "the call ladder the tables declare"
end
