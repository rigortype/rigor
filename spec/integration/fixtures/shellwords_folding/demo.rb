require "rigor/testing"
require "shellwords"
include Rigor::Testing

# `Shellwords` is a pure, side-effect-free module.  Every method
# here operates on string literals (or Tuples of them for #join),
# so the analyzer can evaluate the call at inference time and
# return the exact `Constant<String>` or `Tuple` result.

# ── escape / shellescape ─────────────────────────────────────────────
assert_type('"hello"',           Shellwords.escape("hello"))
_escape_space = Shellwords.escape("hello world")
assert_type('"hello\\\\ world"',   _escape_space)
assert_type(%q["''"],              Shellwords.escape(""))   # always non-empty
assert_type('"hello\\\\ world"',   Shellwords.shellescape("hello world"))

# ── split / shellsplit / shellwords ──────────────────────────────────
assert_type('["echo", "hello", "world"]', Shellwords.split("echo hello world"))
_split_cmd = Shellwords.split("git commit -m 'initial commit'")
assert_type('["git", "commit", "-m", "initial commit"]', _split_cmd)
assert_type("[]", Shellwords.split(""))

assert_type('["ls", "-la"]', Shellwords.shellsplit("ls -la"))
assert_type('["ls", "-la"]', Shellwords.shellwords("ls -la"))

# ── join / shelljoin ──────────────────────────────────────────────────
assert_type('"echo hello world"',
            Shellwords.join(["echo", "hello", "world"]))
_join_arr = Shellwords.join(["git", "commit", "-m", "initial commit"])
assert_type('"git commit -m initial\\\\ commit"', _join_arr)
assert_type('""', Shellwords.join([]))

assert_type('"ls -la"', Shellwords.shelljoin(["ls", "-la"]))

# ── non-constant inputs fall back to RBS ─────────────────────────────
str = rand > 0.5 ? "a b" : "c d"  # non-constant: Nominal[String]
assert_type("String", Shellwords.escape(str))
assert_type("Array[String]", Shellwords.split(str))
