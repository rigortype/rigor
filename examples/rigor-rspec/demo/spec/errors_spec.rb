# frozen_string_literal: true

# DO NOT run via `rspec spec/errors_spec.rb` — analyse
# with `bundle exec rigor check` to see rigor-rspec's
# diagnostics.

# rubocop:disable RSpec/OverwritingSetup, RSpec/LeadingSubject, RSpec/MultipleSubjects, RSpec/EmptyExampleGroup, RSpec/EmptyLineAfterSubject

module RSpec
  def self.describe(*, &)
    yield
  end
end

def let(_name, &); end
def subject(_name = :subject, &); end
def context(*, &); end

RSpec.describe "Mistakes" do
  # Duplicate `let(:user)` in the same scope —
  # the second one wins at runtime, the first is
  # silently shadowed:
  #   plugin.rspec.duplicate-let
  let(:user) { :alice }
  let(:user) { :bob }

  # Self-referencing `let` — calls `tags` from inside its
  # own block body, which infinite-loops at runtime:
  #   plugin.rspec.self-reference
  let(:tags) { tags.map(&:upcase) }

  # `subject` follows the same rules:
  #   plugin.rspec.duplicate-let (severity: warning)
  subject(:greeting) { "Hi" }
  subject(:greeting) { "Hello" }
end
# rubocop:enable RSpec/OverwritingSetup, RSpec/LeadingSubject, RSpec/MultipleSubjects, RSpec/EmptyExampleGroup, RSpec/EmptyLineAfterSubject
