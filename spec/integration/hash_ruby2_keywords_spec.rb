# frozen_string_literal: true

# Issue #1778 — `Hash.ruby2_keywords_hash?` and `Hash.ruby2_keywords_hash` resolve through `data/core_overlay/hash.rbs`.
#
# The one-liner from the issue reported `call.undefined-method` on correct code under the default config. The
# RBS-definition half is in `spec/rigor/environment/hash_ruby2_keywords_overlay_spec.rb`. Ruby 4.1 deprecates both
# methods (`call.deprecated-ruby2-keywords`, #1780), and that report must still fire under an explicit `target_ruby`
# of 4.1; the overlay does not gate on the version.
require "spec_helper"

RSpec.describe "Hash.ruby2_keywords_hash? / ruby2_keywords_hash", type: :runner do
  def summary(source, config: {})
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}), config: config)
    result.diagnostics.filter_map do |diagnostic|
      if diagnostic.message.start_with?("dump_type")
        diagnostic.message.delete_prefix("dump_type: ")
      elsif diagnostic.severity == :error
        diagnostic.qualified_rule
      end
    end
  end

  # THE REPORTED FALSE POSITIVE. The last line is the positive control: a Hash singleton method that does not exist
  # still reports, so the silence above is not `Hash` degraded to `Dynamic[top]`.
  it "reports nothing for the issue's one-liner under the default config" do
    expect(summary(<<~RUBY)).to eq([])
      Hash.ruby2_keywords_hash?({})
      Hash.ruby2_keywords_hash({a: 1})
    RUBY
  end

  it "still reports a Hash singleton method that does not exist" do
    expect(summary(<<~RUBY)).to eq(%w[call.undefined-method])
      Hash.ruby2_keywords_hashh({})
    RUBY
  end

  # The predicate is bool. The copy is a Hash, but its key and value stay `Dynamic[top]`: the generic solve over a
  # method's own type variables (`[K, V] (Hash[K, V]) -> Hash[K, V]`) does not bind them from the argument's type
  # here, so the answer is sound but not the argument's exact Hash type. Pinned as it stands, not as the goal.
  it "answers bool for the predicate and a Hash for the copy" do
    expect(summary(<<~RUBY)).to eq(["bool", "Hash[Dynamic[top], Dynamic[top]]"])
      g = Hash.new(0)
      dump_type(Hash.ruby2_keywords_hash?(g))
      dump_type(Hash.ruby2_keywords_hash(g))
    RUBY
  end

  it "keeps the 4.1 deprecation for the same one-liner under an explicit target_ruby 4.1" do
    result = analyze(<<~RUBY, config: { "target_ruby" => "4.1" })
      Hash.ruby2_keywords_hash?({})
    RUBY
    rules = result.diagnostics.map { |diagnostic| diagnostic.rule.to_s }
    expect(rules).to include("call.deprecated-ruby2-keywords")
    expect(rules).not_to include("call.undefined-method")
  end
end
