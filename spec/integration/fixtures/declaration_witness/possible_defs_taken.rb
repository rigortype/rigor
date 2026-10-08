# frozen_string_literal: true

# ADR-119 WD3's possible definers, in the world where every possible contribution runs (`RUBY_VERSION > "3"` holds
# under the suite's Ruby, and `[1].each` runs its block). `possible_defs_skipped.rb` is the same text in the world
# where none of them runs; the witness must agree with Ruby in both, which holds only when the tables read each of
# these definers as possible and the certain controls (a meta-new block, `private def`) as certain.

class Reopened
  def base = 1
end

class Probe
  def both = 1
  def base_alias = 1

  if RUBY_VERSION > "3"
    def both = 2
    def gated(arg) = arg
    attr_reader :gated_reader
    alias gated_alias base_alias
  end

  [1].each do
    def in_block = 1
  end

  begin
    Integer(RUBY_VERSION > "3" ? "1" : "x")
    def rescued_main = 1
  rescue ArgumentError
    nil
  end

  if RUBY_VERSION > "3"
    class << self
      def gated_singleton = 1
    end
  end

  Made = Class.new do
    def made(arg) = arg
  end

  private def hidden = 1
end

class Reopened
  def reopened = 1
end if RUBY_VERSION > "3"
