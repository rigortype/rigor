# frozen_string_literal: true

# Worked example — rigor-shoulda-matchers validates the
# columns / associations referenced by shoulda matchers
# against the `:model_index` published by
# `rigor-activerecord`. Activate both plugins for the cross-
# check to fire; with `rigor-activerecord` alone, the column
# / association names are silently accepted.

RSpec.describe User do
  it { is_expected.to validate_presence_of(:email) }      # OK if `email` is a column
  it { is_expected.to validate_presence_of(:nme) }        # warning: unknown column

  it { is_expected.to belong_to(:author) }                # OK if `author` is :singular
  it { is_expected.to belong_to(:posts) }                 # warning: kind mismatch (posts is :collection)

  it { is_expected.to have_many(:comments) }              # OK if `comments` is :collection
  it { is_expected.to have_many(:nonexistent) }           # warning: unknown association

  describe ".active" do
    it { is_expected.to validate_presence_of(:email) }    # nested describe; anchor remains User
  end
end
