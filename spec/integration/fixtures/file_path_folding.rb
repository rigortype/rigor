require "rigor/testing"
include Rigor::Testing

# `File` carries a small set of path-manipulation class methods
# that are pure functions over their string arguments — they
# never touch the filesystem and never depend on the current
# working directory. Rigor folds them when every argument is a
# `Constant<String>` so the analyzer carries the precise path
# string downstream.

assert_type('"bar.rb"', File.basename("/foo/bar.rb"))
assert_type('"bar"',    File.basename("/foo/bar.rb", ".rb"))
assert_type('"/foo"',   File.dirname("/foo/bar.rb"))
assert_type('".rb"',    File.extname("hello.rb"))
assert_type('""',       File.extname("plain"))
assert_type('"a/b/c.rb"', File.join("a", "b", "c.rb"))
assert_type('["/foo", "bar.rb"]', File.split("/foo/bar.rb"))

# Boolean predicate folds to Constant[true|false].
assert_type("true",  File.absolute_path?("/foo/bar"))
assert_type("false", File.absolute_path?("foo/bar"))

# Composes with the String catalog: `File.extname(p).end_with?(".rb")`
# threads the precise extension into the predicate so the truthy
# edge collapses to `Constant[true]`.
assert_type("true", File.extname("hello.rb").end_with?(".rb"))

# Filesystem-touching methods (`File.read`, `File.exist?`) DO NOT
# fold — they have side effects and the analyzer leaves the RBS
# tier to type them. The principle here is clause-1 of the
# robustness rule: strict where we can prove it, RBS-widened
# where we cannot.
contents = (File.read("test.txt") rescue "fallback")
assert_type('"fallback" | String', contents)
