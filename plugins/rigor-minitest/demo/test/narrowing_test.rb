# frozen_string_literal: true

# Worked example — Minitest narrowing through assert_* /
# refute_* / _(x).must_* / .wont_*. Without rigor-minitest the
# downstream `.upcase` / `.length` / `+` calls fall through
# `Dynamic[top]` (no diagnostic, but also no precision); the
# plugin emits a `post_return_fact` so the local resolves at
# the narrowed type for the rest of the test body.

require "minitest/autorun"

class NarrowingTest < Minitest::Test
  def test_assert_kind_of
    x = some_call
    assert_kind_of(String, x)
    x.upcase # x narrowed to String — `.upcase` resolves
  end

  def test_assert_nil
    x = some_call
    assert_nil(x)
    # x is Constant<nil>; downstream `x.foo` would now fire.
  end

  def test_assert_equal
    x = some_call
    assert_equal(42, x)
    x + 1 # x narrowed to Constant<42> — `+` resolves
  end

  def test_refute_nil
    result = fetch_value
    refute_nil(result)
    result.length # narrowed away from nil — `.length` resolves
  end

  def test_spec_style_must_be_kind_of
    user = build_user
    _(user).must_be_kind_of(String)
    user.upcase
  end

  def test_spec_style_wont_be_nil
    response = call_api
    _(response).wont_be_nil
    response.length
  end
end
