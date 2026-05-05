require "rigor/testing"
include Rigor::Testing

# v0.0.5 — Exception catalog import. Init_Exception in
# `references/ruby/error.c` registers the entire error hierarchy
# in one pass, so the YAML carries 27 classes (Exception,
# StandardError, RuntimeError, KeyError, NameError, …). Only the
# base `Exception` row is wired into `CATALOG_BY_CLASS`; subclass
# instances reach the catalog via `is_a?(Exception)` and consult
# the base-class entries.
#
# Per the robustness principle, every base method that *could*
# fold has been weighed:
# - `:dispatch` methods (`==`, `to_s`, `message`) remain catalog-
#   classified `:dispatch` and the catalog declines automatically.
# - `:mutates_self` methods (`full_message`, `inspect`) likewise
#   decline at the catalog tier.
# - `:leaf` methods that depend on runtime state (`backtrace`,
#   `backtrace_locations`, `set_backtrace`, `detailed_message`,
#   the singleton `to_tty?`) and aliasing constructors
#   (`initialize`, `exception`) are blocklisted in
#   `exception_catalog.rb` so a future `Constant<Exception>`
#   carrier cannot fold a non-deterministic value.
# - The remaining foldable surface is `#cause` — a pure ivar
#   accessor — which today has no constant carrier to exercise it
#   through.
#
# What the import buys today:
# 1. `Exception.new` / `RuntimeError.new` / `KeyError.new`
#    receivers route through `CATALOG_BY_CLASS`, so a future
#    constant-fold path on these has the catalog already wired.
# 2. The blocklist defends against accidental folds of
#    state-dependent methods if a `Constant<Exception>` carrier
#    is added later.
# 3. The YAML is documentation-grade: the 34 instance methods
#    across the 27 classes are now visible to anyone inspecting
#    `data/builtins/ruby_core/exception.yml`.
#
# What the import does NOT yet unlock: RBS-tier projection of
# Exception methods (`#message`, `#to_s`, `#cause`) on instance
# receivers — the analyzer's RBS dispatch does not yet route
# Exception sigs (the same gap visible in `struct_catalog.rb`).
# That is a separate slice; the catalog is in place so the
# follow-up only needs to flip the RBS-side switch.

# Class-object typing flows through `ClassRegistry`.
assert_type("singleton(Exception)", Exception)
assert_type("singleton(RuntimeError)", RuntimeError)
assert_type("singleton(KeyError)", KeyError)

# Constructors resolve to the receiver's nominal — RuntimeError
# stays `RuntimeError` rather than widening to `Exception`.
err = Exception.new
assert_type("Exception", err)

re = RuntimeError.new("oops")
assert_type("RuntimeError", re)

ke = KeyError.new("missing")
assert_type("KeyError", ke)

# Sub-class hierarchy resolves at the type-construction tier.
ne = NameError.new("undef")
assert_type("NameError", ne)

nme = NoMethodError.new("undef")
assert_type("NoMethodError", nme)
