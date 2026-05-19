# frozen_string_literal: true

# Demo: rigor-rspec walks RSpec.describe blocks and
# validates the `let` / `subject` declarations inside
# each scope. This file shows clean usage — no
# diagnostics expected.

# rubocop:disable RSpec/LeadingSubject, RSpec/EmptyLineAfterFinalLet, RSpec/EmptyExampleGroup

# Stand-in `RSpec.describe` so this file parses
# standalone (without RSpec loaded).
module RSpec
  def self.describe(*, &)
    yield
  end
end

# Stand-ins for the DSL methods that get called inside a
# describe block.
def let(_name, &); end
def subject(_name = :subject, &); end
def context(*, &); end

RSpec.describe "User" do
  let(:user) { :alice }
  let(:locale) { "en" }
  subject(:greeting) { "Hello, #{user}" }

  context "when locale is `:ja`" do
    let(:locale) { "ja" } # different scope — not a duplicate
    subject(:greeting) { "ようこそ、#{user}さん" }
  end
end
# rubocop:enable RSpec/LeadingSubject, RSpec/EmptyLineAfterFinalLet, RSpec/EmptyExampleGroup
