# rubocop:disable Style/SpecialGlobalVars
require "delegate"
require "rigor/testing"

# Issue #1359 — an implicit-self `gets` sets `$_` for certain only in the top-level script body, whose `self` is
# `main`, and only while the program mixes nothing into `main`: this file calls `Rigor::Testing.assert_type`
# rather than including `Rigor::Testing`, which would count as such a mixin. Run it with `read` as the first
# argument to read standard input; each case cites what Ruby 4.0.5 answers.

# `DelegateClass(File)` builds `gets` as a Ruby forwarder, which sets the forwarder's own `$_`.
class DelegatedLines < DelegateClass(File)
end

# A top-level method is a private method of every object, so its implicit-self `gets` is this subclass's forwarder
# when `Importer.new(file).import` calls it (Ruby: nil inside the loop, which runs once per line of the file).
def helper
  while gets
    Rigor::Testing.assert_type("Dynamic[top]", $_)
  end
end

class Importer < DelegatedLines
  def import = helper
end

if ARGV.first == "read"
  # The issue's `lines` and `if gets then $_ else $_ end`, in the script body (Ruby: the line, then nil).
  while gets
    Rigor::Testing.assert_type("String", $_)
  end
  Rigor::Testing.assert_type("nil", $_)
  if gets then Rigor::Testing.assert_type("String", $_) else Rigor::Testing.assert_type("nil", $_) end

  # A block's `self` is the one its method gives it, which the analyzer does not follow: `instance_exec` makes it
  # the forwarder (Ruby: nil, the line went to the forwarder's frame).
  DelegatedLines.new(File.open(__FILE__)).instance_exec { Rigor::Testing.assert_type("Dynamic[top]", $_) if gets }
  [1].each { Rigor::Testing.assert_type("Dynamic[top]", $_) if gets }

  Importer.new(File.open(__FILE__)).import
end
# rubocop:enable Style/SpecialGlobalVars
