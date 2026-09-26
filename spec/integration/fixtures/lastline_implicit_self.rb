# rubocop:disable Style/SpecialGlobalVars, Style/RedundantSelf, Lint/UselessAssignment
require "csv"
require "delegate"
require "stringio"
require "tempfile"
require "rigor/testing"
require_relative "lastline_self_evidence/ruby_line_reader"

# Issue #1415 (ADR-117 WD5) — an implicit-self or `self.` `gets` narrows `$_` as `$stdin.gets` does, unless the file
# shows a `self` whose reader may be written in Ruby. This file mixes nothing into `main`, so it calls
# `Rigor::Testing.assert_type` rather than including `Rigor::Testing`, which would count as such a mixin (each mixin
# shape declines in a file of its own, under `lastline_self_evidence/`). Each case cites what Ruby 4.0.5 answers with
# "a\nb\n" on standard input, the read kept in the reader's frame. `RubyReader` and `RubyReaderClass`
# (`lastline_self_evidence/ruby_line_reader.rb`, which the analysis does not read) carry readers written in Ruby.

# The issue's script body: the loop body runs only when `gets` returned a line (Ruby: "a\n", then "b\n"), and the loop
# exits when it returns nil (Ruby: nil). Run with `read` as the first argument.
if ARGV.first == "read"
  while gets
    Rigor::Testing.assert_type("String", $_)
  end
  Rigor::Testing.assert_type("nil", $_)
end

# The issue's method, the same way (Ruby: "a\n", "b\n", then nil).
def lines
  while gets
    Rigor::Testing.assert_type("String", $_)
  end
  Rigor::Testing.assert_type("nil", $_)
end

# `if gets then $_ else $_ end` (Ruby: the line, then nil at end of input).
def branches
  if gets
    Rigor::Testing.assert_type("String", $_)
  else
    Rigor::Testing.assert_type("nil", $_)
  end
end

# `self.` reaches the same private `Kernel#gets` (Ruby: "a\n"). An implicit-self `readline` does not narrow yet (Ruby:
# "b\n", then `EOFError`): it never returns nil, so its loop leaves through `break` or `EOFError`, and the scope after
# the loop, which still joins the body's entry, would read the narrowed line where Ruby never reaches.
def self_receiver
  Rigor::Testing.assert_type("String", $_) if self.gets
  Rigor::Testing.assert_type("Dynamic[top]", $_) while self.readline
rescue EOFError
  nil
end

# A `while readline` loop left by `break` stays quiet after it (Ruby with "a\nbx\n": "bx\n").
def quiet_readline_break
  x = nil
  while readline
    x = $_
    break if x.start_with?("b")
  end
  x.chomp # QUIET-1415
rescue EOFError
  nil
end

# A block keeps its creator's `self` (Ruby: the line).
def plain_block(items)
  items.each { Rigor::Testing.assert_type("String", $_) if gets }
end

# A method `class << self` defines at the top level is `main`'s own (Ruby: the line).
class << self
  def main_singleton = (Rigor::Testing.assert_type("String", $_) if gets)
end

# In a class body and its methods, `self` is the class or its instance, whose ancestry holds only `Kernel`'s reader or
# a C one: a plain class, a project superclass, `Comparable`, `File`, `StringIO` and a reopened `IO` (Ruby: the line
# on each). A module's own body and singleton methods run with the module as `self` (Ruby: the line).
class LineSource
  def first = (Rigor::Testing.assert_type("String", $_) if gets)
  def self.first = (Rigor::Testing.assert_type("String", $_) if gets)

  class << self
    def second = (Rigor::Testing.assert_type("String", $_) if gets)
  end
end

class ChildSource < LineSource
  def child_first = (Rigor::Testing.assert_type("String", $_) if gets)
end

class RankedSource
  include Comparable

  def first = (Rigor::Testing.assert_type("String", $_) if gets)
end

class NumberedFile < File
  def first = (Rigor::Testing.assert_type("String", $_) if gets)
end

class BufferSource < StringIO
  def first = (Rigor::Testing.assert_type("String", $_) if gets)
end

class IO
  def first_line = (Rigor::Testing.assert_type("String", $_) if gets)
end

module Prompt
  def self.first = (Rigor::Testing.assert_type("String", $_) if gets)

  # An instance method runs with whatever includes the module as `self` (Ruby, included into a `RubyReaderClass`
  # subclass: nil).
  def each_prompt = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

# An ancestry that may hold a Ruby reader declines. `DelegateClass(File)` builds `gets` as a Ruby forwarder, which sets
# the forwarder's `$_` (Ruby: nil); so do `Tempfile`'s forwarders (Ruby: nil); `CSV#gets` and `#readline` are aliases
# of its Ruby `shift` (Ruby: nil on both); a superclass or mixin the analysis cannot resolve may be a gem's Ruby reader
# (Ruby with `RubyReaderClass` or `RubyReader`: nil); `OpenSSL::Buffering` and `Reline`, whose RBS this analysis does
# not load, define theirs in Ruby (Ruby: nil); and a `BasicObject` or `SimpleDelegator` subclass has no `Kernel` reader
# (Ruby: `NameError`, and nil through the delegate's forwarder).
class DelegatedSource < DelegateClass(File)
  def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

class TempSource < Tempfile
  def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

class CsvSource < CSV
  def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)

  def second
    Rigor::Testing.assert_type("Dynamic[top]", $_) while readline
  rescue EOFError
    nil
  end
end

class GemSource < RubyReaderClass
  def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

class MixedSource
  include RubyReader

  def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

class BufferedSource
  include OpenSSL::Buffering

  def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

class PromptSource
  include Reline

  def first
    Rigor::Testing.assert_type("Dynamic[top]", $_) while readline
  rescue EOFError
    nil
  end
end

class ProxySource < BasicObject
  def first = (::Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

class WrappedSource < SimpleDelegator
  def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

# A class body that may gain an ancestor the analysis does not record declines too: a superclass that is not a
# constant (Ruby with `Struct.new(:io)`: the line, declined all the same), a mixin in a method (Ruby, `extend
# RubyReader` in `initialize`: nil), a splatted mixin (Ruby with `Comparable`: the line, declined all the same), and a
# mixin into the class's singleton (Ruby with `RubyReader`: nil).
class StructSource < Struct.new(:io)
  def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

class ExtendedSource
  def initialize = extend(RubyReader)
  def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

class SplatSource
  include(*[Comparable])

  def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

class SingletonMixedSource
  class << self
    include RubyReader
  end

  def self.first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

# So does a mixin through `self.` or `singleton_class.`, and one in a block of the body, which the discovery tables do
# not record either (Ruby with `RubyReader`: nil on each).
class SelfPrepended
  self.prepend(RubyReader)

  def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

class SelfExtended
  self.extend RubyReader

  def self.first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

module SelfExtendedModule
  self.extend(RubyReader)

  def self.first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

class SingletonIncluded
  singleton_class.include(RubyReader)
end

class BlockIncluded
  [RubyReader].each { |mod| include mod }
end

class LaterExtended
  def self.setup = extend(RubyReader)
end

# A dirty class stays dirty past its own body: in a reopening, in a subclass, and in a class that includes a dirty
# module (Ruby, after `ExtendedSource.new`, `LaterExtended.setup` and each mixin above: nil on each).
class ExtendedSource
  def second = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

class ExtendedChild < ExtendedSource
  def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

class StructChild < StructSource
  def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

class SingletonIncluded
  def self.first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

class BlockIncluded
  def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

class LaterExtended
  def self.first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

module SplatModule
  include(*[RubyReader])
end

class SplatIncluder
  include SplatModule

  def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

# A constant the program writes shadows the core class or module an ancestor name would reach (Ruby with each alias
# a `RubyReader` kin: nil on each).
module AliasedIO
  IO = Class.new(RubyReaderClass)

  class Source < IO
    def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
  end
end

module AliasedFile
  File = RubyReaderClass

  class Source < File
    def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
  end
end

module AliasedComparable
  Comparable = RubyReader

  class Source
    include Comparable

    def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
  end
end

# `class << self` in a method opens the singleton of the method's receiver, an instance here, whose `gets` is
# `RubyReader`'s (Ruby, after `SingletonInMethod.new.setup`: nil).
class SingletonInMethod
  include RubyReader

  def setup
    class << self
      def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
    end
  end
end

# A block whose `self` the method rebinds declines, for a receiver whose reader is Ruby's (Ruby with a
# `RubyReaderClass`, or a class or module extended with `RubyReader`: nil on each).
def rebound(source, klass, mod)
  source.instance_eval { Rigor::Testing.assert_type("Dynamic[top]", $_) if gets }
  source.instance_exec { Rigor::Testing.assert_type("Dynamic[top]", $_) if gets }
  klass.class_eval { Rigor::Testing.assert_type("Dynamic[top]", $_) if gets }
  mod.module_eval { Rigor::Testing.assert_type("Dynamic[top]", $_) if gets }
  klass.class_exec { Rigor::Testing.assert_type("Dynamic[top]", $_) if gets }
  mod.module_exec { Rigor::Testing.assert_type("Dynamic[top]", $_) if gets }
  klass.define_method(:reread) { Rigor::Testing.assert_type("Dynamic[top]", $_) if gets }
end

# A method defined in a block belongs to the block's `self`: a `Class.new(CSV)` body's (Ruby: nil), or, in any other
# block, one the analysis does not follow (Ruby here: the line, declined all the same). A method `class << obj`
# defines runs with `obj` (Ruby with an `Object`: the line, declined all the same).
AnonymousCsv = Class.new(CSV) do
  def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

[1].each do
  def block_defined = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

# A class a constant write makes records its superclass nowhere the analysis reads (Ruby with `Class.new(CSV)`:
# nil), even where a `class` body reopens it.
ReopenedCsv = Class.new(CSV)
class ReopenedCsv
  def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

SOURCE = Object.new
class << SOURCE
  def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

# Assumed, not declined (ADR-117 WD4): a top-level method run with another `self`. `Importer.new(input).import` runs
# `lines` above with a `CSV` as `self`, whose `gets` is Ruby's (Ruby: nil inside the loop), and `lines` still reads
# `String` there. So do a file loaded under `load(file, M)` and a DSL's `instance_eval(File.read(f))`.
class Importer < CSV
  def import = lines
end

# Defensive reads of `$_` inside `while gets` stay quiet: the narrowing makes each check redundant, never a report.
def quiet_nil_check
  while gets
    next if $_.nil? # QUIET-1415
    line = $_
    line.chomp # QUIET-1415
  end
end

def quiet_default
  while gets
    line = $_ || "default" # QUIET-1415
    line.chomp # QUIET-1415
  end
end

def quiet_case
  while gets
    case $_ # QUIET-1415
    when nil then next # QUIET-1415
    else $_.chomp # QUIET-1415
    end
  end
end

def quiet_unless
  while gets
    unless $_ # QUIET-1415
      next
    end
    $_.chomp # QUIET-1415
  end
end

# An `ensure` clause also runs after a `return` out of the loop, where `$_` is the line (Ruby with "a\n": warns with
# "a\n"), so it reads `$_` as `Dynamic[top]` and reports nothing.
def quiet_ensure
  while gets
    return $_ if $_.start_with?("a")
  end
  nil
ensure
  Rigor::Testing.assert_type("Dynamic[top]", $_)
  warn "stopped at nil" if $_ # QUIET-1415
end

# A report the narrowing earns (ADR-117 Decision 4): after the loop `$_` is nil, so the tail never prints (Ruby: nil).
def dead_tail
  while gets
    nil
  end
  puts "tail" if $_ # FIRES-1415 flow.always-truthy-condition
end
# rubocop:enable Style/SpecialGlobalVars, Style/RedundantSelf, Lint/UselessAssignment
