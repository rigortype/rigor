# frozen_string_literal: true

require "spec_helper"

# Issue #1812 — `Hash.new(capacity: 10)` read its brace-less keyword hash as `Hash#initialize`'s `V default_value`
# positional, so the hash typed `Hash[Dynamic[top], { capacity: 10 }]` and a read `h[:k].foo` reported an undefined
# method on the record. Ruby binds a brace-less keyword list to the `capacity:` keyword
# (`Hash.new(capacity: 10).default #=> nil`); only a braced hash (`Hash.new({ capacity: 10 }).default #=>
# {capacity: 10}`) is the default value, and a positional default beside the keyword
# (`Hash.new(5, capacity: 10).default #=> 5`) still is.
RSpec.describe "Hash.new with the capacity: keyword", type: :runner do
  def dumped_types(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def reported_rules(source)
    analyze(source).diagnostics.filter_map { |diagnostic| diagnostic.rule if diagnostic.severity == :error }
  end

  it "does not read the keyword hash as the default value" do
    expect(dumped_types(<<~RUBY)).to eq(%w[Hash])
      dump_type(Hash.new(capacity: 10))
    RUBY
  end

  it "reports nothing on a read through the hash" do
    expect(reported_rules(<<~RUBY)).to be_empty
      h = Hash.new(capacity: 10)
      h[:k].foo
    RUBY
  end

  it "keeps a positional default given beside the keyword" do
    expect(dumped_types(<<~RUBY)).to eq(["Hash[Dynamic[top], Integer]"])
      dump_type(Hash.new(5, capacity: 10))
    RUBY
  end

  it "keeps a braced hash as the default value" do
    expect(dumped_types(<<~RUBY)).to eq(["Hash[Dynamic[top], { capacity: 10 }]"])
      dump_type(Hash.new({ capacity: 10 }))
    RUBY
  end

  it "leaves the scalar default and the block form unchanged" do
    expect(dumped_types(<<~RUBY)).to eq(["Hash[Dynamic[top], Integer]", "Hash"])
      dump_type(Hash.new(0))
      dump_type(Hash.new { |h, k| h[k] = [] })
    RUBY
  end

  # A literal send dispatches `new` with the outer call node, whose arguments lead with the selector symbol.
  it "reads the keyword hash through a literal send" do
    expect(reported_rules(<<~RUBY)).to be_empty
      h = Hash.send(:new, capacity: 1)
      h[:k].foo
      g = Hash.public_send(:new, capacity: 1)
      g[:k].foo
    RUBY
  end

  # `Hash.send(:new, { a: 1 }).default #=> {a: 1}`: the braced argument is still the default through a send.
  it "keeps a braced default through a literal send" do
    expect(dumped_types(<<~RUBY)).to eq(["Hash[Dynamic[top], { a: 1 }]"])
      dump_type(Hash.send(:new, { a: 1 }))
    RUBY
  end
end
