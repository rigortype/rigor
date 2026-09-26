# Issue #1415 — the Ruby readers the `lastline_implicit_self.rb` fixture and this directory's entries mix in, so that
# each can be run on Ruby 4.0.5 (`ruby -Ilib <fixture> read < input`). The analysis reads none of it: every constant
# here is one the analyzed file cannot resolve, as a gem's would be.

# A module whose readers are written in Ruby: each returns one line, then nil, and sets its own frame's `$_`, never
# its caller's.
module RubyReader
  def gets(*)
    @ruby_lines ||= ["ruby\n"]
    @ruby_lines.shift
  end

  def readline(*) = gets || raise(EOFError)
end

class RubyReaderClass
  include RubyReader
end

# A refinement that makes an implicit-self reader Ruby's.
module RefineKernel
  refine Kernel do
    def gets(*)
      @ruby_lines ||= ["ruby\n"]
      @ruby_lines.shift
    end
  end
end
