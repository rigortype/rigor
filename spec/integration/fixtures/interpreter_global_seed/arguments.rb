# rubocop:disable Style/SpecialGlobalVars
require "stringio"
require "rigor/testing"
include Rigor::Testing

# Issue #1362 — a global still on its declared seed, or a local copied from one, passed where a signature (this
# fixture's `sig/`) requires the type the file writes: the declared members are not diagnostic fuel, so the call
# reports only when the file's writes themselves are rejected, as before the join. The same holds for a method whose
# body ends on such a read. Each method runs once this file's writes ran.

class Cap
  def self.take(io) = io.string
  def self.file(file) = file.path
  def self.text(text) = text
  def self.count(number) = number
end

class Ret
  def out = $stdout # QUIET-1362
  def out_copy # QUIET-1362
    out = $stdout
    out
  end

  def separator = $/ # QUIET-1362
  def verbose = $VERBOSE # QUIET-1362
  def out_count = $stdout # FIRES-1362 def.return-type-mismatch
end

$stdout = StringIO.new
$stderr = File.open(File::NULL, "w")
$/ = "\n"
$VERBOSE = true

# Ruby: "" for each.
def take_direct = Cap.take($stdout) # QUIET-1362

def take_copy
  out = $stdout
  Cap.take(out) # QUIET-1362
end

# Ruby: "/dev/null".
def file_direct = Cap.file($stderr) # QUIET-1362

def file_copy
  err = $stderr
  Cap.file(err) # QUIET-1362
end

# Ruby: "\n".
def text_direct = Cap.text($/) # QUIET-1362

def text_copy
  sep = $/
  Cap.text(sep) # QUIET-1362
end

# Controls: the file's writes themselves are rejected, so the call still reports (Ruby: the method runs on a
# `StringIO`, which is no `Integer`).
def count_direct = Cap.count($stdout) # FIRES-1362 call.argument-type-mismatch

def count_copy
  out = $stdout
  Cap.count(out) # FIRES-1362 call.argument-type-mismatch
end
# rubocop:enable Style/SpecialGlobalVars
