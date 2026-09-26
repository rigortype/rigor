# rubocop:disable Style/SpecialGlobalVars
require "stringio"
require "rigor/testing"
include Rigor::Testing

# Issue #1362 — `$>` names the same variable as `$stdout`, but the analysis does not unify the two names yet (#1366,
# after #1429). A file that writes only `$stdout` leaves `$>` unbound, so the class-guarded reads #1429 is about stay
# as quiet on `$>` as they were (Ruby: nil, "" and nil, since `STDOUT` is no `StringIO`).

$stdout = STDOUT

def unbound_alias = assert_type("Dynamic[top]", $>)
def guarded_is_a = ($>.is_a?(StringIO) ? $>.string : nil) # QUIET-1362
def guarded_respond_to = ($>.respond_to?(:string) ? $>.string : "") # QUIET-1362
def guarded_case = (case $> when StringIO then $>.string end) # QUIET-1362
# rubocop:enable Style/SpecialGlobalVars
