require "rigor/testing"
include Rigor::Testing

# `File` carries a small set of path-manipulation class methods
# that are pure functions over their string arguments — they
# never touch the filesystem and never depend on the current
# working directory.
#
# All of them, however, observe `File::SEPARATOR` /
# `File::ALT_SEPARATOR` and produce different answers on Windows
# vs POSIX hosts (`File.basename("a\\b.rb")` is `"b.rb"` on
# Windows and `"a\\b.rb"` on POSIX, etc). Folding to a
# `Constant<String>` would silently bake the analyzer-host's
# platform into the inferred type and mis-report it on a host
# with a different separator policy.
#
# The default policy (`fold_platform_specific_paths: false`) is
# therefore platform-agnostic: the analyzer declines the fold so
# the RBS tier answers with the wider `Nominal[String]` envelope.
# Single-platform projects can opt in via:
#
#   # .rigor.yml
#   fold_platform_specific_paths: true
#
# (See `spec/integration/fixtures/file_path_folding_optin/`.)

# In the default mode each fold lands at the RBS-declared shape:
assert_type("String", File.basename("/foo/bar.rb"))
assert_type("String", File.dirname("/foo/bar.rb"))
assert_type("String", File.extname("hello.rb"))
assert_type("String", File.join("a", "b", "c.rb"))
assert_type("[String, String]", File.split("/foo/bar.rb"))
assert_type("false | true", File.absolute_path?("/foo"))

# Filesystem-touching methods stay outside the FileFolding tier
# regardless of mode — they have side effects.
contents = (File.read("test.txt") rescue "fallback")
assert_type('"fallback" | String', contents)
