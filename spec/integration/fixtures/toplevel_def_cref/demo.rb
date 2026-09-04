require "rigor/testing"
include Rigor::Testing

# A TOP-LEVEL `def`'s cref (https://github.com/rigortype/rigor/issues/716), and
# the last rung of the `Module.nesting` family after #681 / #707 / #708.
#
# Ruby's `Module.nesting` inside a top-level `def` body is `[]`, so the bare
# `Post` in `def helper = Post.new` names `::Post` no matter which namespace
# calls `helper`. #709 recorded each def's chain at declaration time and
# recorded NOTHING for a top-level def, which left
# `Reflection.lexical_nesting_chain` peeling the CALLER's qualified name — so
# calling `helper` from inside `module Admin` answered `Admin::Post`.
#
# An empty chain is now RECORDED, and a recorded-empty chain resolves at the top
# level first. Every assertion is followed by a call only the correctly resolved
# class owns, declared in the fixture's `sig/`, so a wrong answer FIRES
# `call.undefined-method` rather than merely widening.

class Post
end

module Admin
  class Post
  end
end

module Shared
  class Widget
  end
end

# ── The movable shape. `helper` is written at the top level, so `Post` is
# `::Post` wherever it is read from.
def helper = Post.new

# ── The nested-only shape, and the MUST-STILL-SUCCEED arm. `Gadget` exists ONLY
# under `Shop`, so the top level cannot answer and the caller-derived rung — kept
# deliberately BELOW the top level — is the only source of any type at all. Ruby
# raises `NameError` here; retracting the rung would trade a wrong answer for no
# answer at sites Rigor reports nothing about either way.
def only_nested = Gadget.new

module Shop
  class Gadget
  end

  def self.reads_nested
    assert_type('Shop::Gadget', only_nested)
    only_nested.shop_gadget
  end
end

# ── Called from a namespace that declares its OWN `Post`. The peel reached
# `Admin::Post`; Ruby reaches `::Post`.
module Admin
  def self.reads_toplevel
    assert_type('Post', helper)
    helper.top_post
  end

  class Reader
    def read
      assert_type('Post', helper)
      helper.top_post
    end
  end
end

# ── The ANCESTOR rung, which is a second wrong answer the nesting rung alone
# does not reach: `Child`'s ancestors include `Shared`, so the caller-derived
# ancestor walk answered `Shared::Widget` for a body whose cref is `Object`.
# Suppressing only the nesting rung leaves this arm failing.
class Widget
end

class Base
  include Shared
end

def widget = Widget.new

class Child < Base
  def self.read
    assert_type('Widget', widget)
    widget.top_widget
  end
end

# ── The must-still-succeed twin for a def written INSIDE a declaration: its
# recorded chain is non-empty and is unaffected. Written in both spellings,
# because an implementation that retracted the peel wholesale satisfies the
# compact half and fails the nested one.
class Admin::CompactMaker
  def make = Post.new

  def via_callee
    assert_type('Post', make)
    make.top_post
  end
end

module Admin
  class NestedMaker
    def make = Post.new

    def via_callee
      assert_type('Admin::Post', make)
      make.admin_post
    end
  end
end
