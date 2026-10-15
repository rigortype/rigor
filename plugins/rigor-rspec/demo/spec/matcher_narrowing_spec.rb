# frozen_string_literal: true

# Pillar 2 Slice 1 demo — `expect(x).to MATCHER` narrows `x` downstream so subsequent calls in the same
# `it` body resolve against the narrowed type. Without this slice, `x` would stay at its entry type
# (typically `untyped` for spec-local bindings) and the downstream `.length` / `.upcase` calls would
# either fall through `Dynamic[top]` or fire `possible-nil-receiver`.

RSpec.describe "matcher narrowing" do
  it "narrows to String through be_a(String)" do
    x = some_thing
    expect(x).to be_a(String)
    x.upcase # x is narrowed to String — `.upcase` resolves
  end

  it "narrows to Integer through be_kind_of(Integer)" do
    x = some_thing
    expect(x).to be_kind_of(Integer) # rubocop:disable RSpec/ClassCheck
    x + 1 # x narrowed to Integer — `+` resolves
  end

  it "narrows to nil through be_nil" do
    x = some_thing
    expect(x).to be_nil
    # x is now Constant<nil>; downstream `.foo` would fire.
  end

  it "narrows an Integer to Constant<42> through eq(42)" do
    x = rand(100)
    expect(x).to eq(42)
    x + 1 # x narrowed from Integer to Constant<42>. `==` is x's own method, so a Dynamic or
    # user-class local would keep its type instead
  end

  it "narrows a String to Constant<\"hi\"> through eq(\"hi\")" do
    x = String(some_thing)
    expect(x).to eq("hi")
    x.upcase # x narrowed from String to the "hi" Constant — `.upcase` resolves
  end
end
