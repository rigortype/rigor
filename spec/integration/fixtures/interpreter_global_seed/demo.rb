# rubocop:disable Style/SpecialGlobalVars, Style/GlobalVars
require "stringio"
require "rigor/testing"
include Rigor::Testing

# Issue #1362 (ADR-117 WD1) — a global Ruby's own signatures declare holds what the interpreter set, from the
# command line (`-w`, `-W0`, `-d`, `-0`) or at boot, until a write, and any other loaded file may write it. So a
# write in this file only widens the declared type every method body starts from. Each case cites what Ruby 4.0.5
# answers for the method when another file, or the command line, set the global last.

$VERBOSE = true

# The issue's example. Under `ruby -W0`, or once another file sets `$VERBOSE = false`, the condition is false. The
# declared `nil` is not joined (#1437), so the seed is `bool`.
def warn_when_verbose
  warn "verbose" if $VERBOSE # QUIET-1362
  assert_type("bool", $VERBOSE)
end

$/ = ","

# The nil-bearing separators are not joined yet (#1437): `$/` reads this file's write, as before #1362, and the
# issue's guard on it still folds although `ruby -0777` leaves `$/` nil. Flip the fold to QUIET-1362 when #1437 lands.
def record_separator = assert_type('","', $/)

def separator_guard
  return unless $/ # FIRES-1362 flow.always-truthy-condition

  $/.size
end

$stdout = StringIO.new

# `$stdout` holds an `IO` until this file's write runs, so a read is the declared `IO` joined with the write. A
# `StringIO`-only method stays quiet: a member of the union has it (Ruby: the captured text once the write ran).
def captured = assert_type("IO | StringIO", $stdout)
def captured_text = $stdout.string # QUIET-1362
def emit = assert_type("nil", $stdout.puts("x"))

# `$>` is `$stdout` at runtime, but the analysis does not unify the two names yet (#1366): this file never writes
# `$>`, so it stays unbound, as before (Ruby: the same captured text).
def captured_alias = assert_type("Dynamic[top]", $>)
def captured_alias_text = $>.string # QUIET-1362

# The class-guarded shapes of #1429 stay quiet, and no `when` clause is unreachable (Ruby: each arm runs under the
# occupant it names).
def guarded_is_a = ($stdout.is_a?(StringIO) ? $stdout.string : nil) # QUIET-1362
def guarded_respond_to = ($stdout.respond_to?(:string) ? $stdout.string : "") # QUIET-1362
def guarded_case = (case $stdout when StringIO then $stdout.string end) # QUIET-1362

def by_class
  case $stdout
  when IO then :io # QUIET-1362
  when StringIO then :string_io # QUIET-1362
  end
end

$stderr = File.open(File::NULL, "w")

# A write of a subclass keeps it as a member of the join, so a `File`-only method stays quiet (Ruby: the file's
# mtime while this file's write holds).
def logged = assert_type("File | IO", $stderr)
def logged_mtime = $stderr.mtime # QUIET-1362

$stdin = StringIO.new("a\n")

# A `$stdin` joined with the file's `StringIO` is still a core reader, so a reader condition narrows `$_` (Ruby:
# "a\n" once the write ran).
def input = assert_type("IO | StringIO", $stdin)

def read_line
  assert_type("String", $_) if $stdin.gets
end

$DEBUG = true

# RBS declares `$DEBUG: boolish`, an alias read as `Dynamic[top]`, so a condition on it folds nowhere.
def debugging
  puts "debug" if $DEBUG # QUIET-1362
  assert_type("Dynamic[top] | true", $DEBUG)
end

$0 = "prog"

def program_name = assert_type('"prog" | String', $0)

# Controls: a global no core or stdlib signature declares keeps the union of this file's writes, including one the
# project's own `sig/` declares (`$declared_flag: bool`).
$flag = true

def flag_check
  assert_type("true", $flag)
  1 if $flag # FIRES-1362 flow.always-truthy-condition
end

$declared_flag = true

def declared_flag_check
  assert_type("true", $declared_flag)
  1 if $declared_flag # FIRES-1362 flow.always-truthy-condition
end
# rubocop:enable Style/SpecialGlobalVars, Style/GlobalVars
