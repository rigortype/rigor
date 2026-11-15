# frozen_string_literal: true

require "spec_helper"

# Issue #3219 — Ruby keeps one class-variable slot for a class and its subclasses, but the class-cvar census keyed
# each class alone, so a superclass's `@@x = nil` never reached a subclass's entry and `@@x.nil?` there folded on
# correct code. Each "does not fold" source prints "clean" under Ruby 4.0.5 when its `failures` runs before the
# write the census saw; each "folds" one is a control whose read can never be `nil`.
RSpec.describe "class-cvar census superclass join (#3219)", type: :runner do
  def folds(source, sig: {})
    analyze(files: { "code.rb" => source }, sig: sig).diagnostics
                                                     .select { |d| d.rule.to_s == "flow.always-truthy-condition" }
                                                     .map(&:line)
  end

  def reader(name = "@@c", singleton: false)
    receiver = singleton ? "self." : ""
    "  def #{receiver}failures\n    count = #{name}.nil? ? 0 : 1\n    puts \"clean\" if count == 0\n    count\n  end\n"
  end

  def guard_line(source) = source.lines.index { |l| l.include?("if count == 0") } + 1

  it "does not fold a subclass read of the `nil` its superclass's body writes (the issue's repro)" do
    source = "class Base; @@c = nil; end\nclass Sub < Base\n  def set = @@c = 1\n#{reader}end\n"
    expect(folds(source)).to eq([])
  end

  it "folds when the in-file superclass writes nothing (control)" do
    source = "class Base; end\nclass Sub < Base\n  def set = @@c = 1\n#{reader}end\n"
    expect(folds(source)).to eq([guard_line(source)])
  end

  it "does not fold a subclass read of the `nil` a superclass's `def` writes" do
    source = "class Base\n  def self.reset = @@c = nil\nend\nclass Sub < Base\n  def set = @@c = 1\n#{reader}end\n"
    expect(folds(source)).to eq([])
  end

  it "does not fold a superclass read of the `nil` a subclass writes into the shared slot" do
    source = "class Base\n  def self.init = @@c = 1\n#{reader(singleton: true)}end\n" \
             "class Sub < Base\n  def self.clear = @@c = nil\nend\n"
    expect(folds(source)).to eq([])
  end

  it "does not fold through a grandparent declared in an enclosing module" do
    source = "module Ns\n  class Top; @@c = nil; end\n  class Mid < Top; end\n  class Leaf < Mid\n    " \
             "def set = @@c = 1\n#{reader.gsub(/^/, '  ')}  end\nend\n"
    expect(folds(source)).to eq([])
  end

  it "does not fold when the superclass's body write follows the subclass" do
    # Ruby: with `Base`'s `@@c = nil` in place, `failures` prints "clean" before `set` runs. Had `set` run first,
    # `Sub` would hold its own `@@c`, and the read after `Base`'s write raises "class variable @@c of Sub is overtaken
    # by Base". The join does not depend on the order the classes are written in.
    source = "class Base; end\nclass Sub < Base\n  def set = @@c = 1\n#{reader}end\nclass Base; @@c = nil; end\n"
    expect(folds(source)).to eq([])
  end

  {
    "a superclass no file declares" => "Unknown",
    "a superclass a signature declares" => "StandardError",
    "a non-constant superclass" => "Struct.new(:a)"
  }.each do |label, superclass|
    it "does not fold under #{label}, whose writes are unseen" do
      source = "class Sub < #{superclass}\n  def set = @@c = 1\n#{reader}end\n"
      expect(folds(source)).to eq([])
    end
  end

  it "folds under an explicit `Object` superclass, which ends the tree (control)" do
    source = "class Sub < Object\n  def set = @@c = 1\n#{reader}end\n"
    expect(folds(source)).to eq([guard_line(source)])
  end

  it "folds when a rooted superclass names a top-level class that never writes `nil` (control)" do
    # `::Base` is the top-level class; the nearer `Ns::Base`'s `nil` is another slot.
    source = "class Base; end\nmodule Ns\n  class Base; @@c = nil; end\n  class Sub < ::Base\n    " \
             "def set = @@c = 1\n#{reader.gsub(/^/, '  ')}  end\nend\n"
    expect(folds(source)).to eq([guard_line(source)])
  end

  it "does not fold when the superclass's nearer candidate only a signature declares" do
    # `Status` inside `module Process` is the core `Process::Status`, not the file's top-level `Status`. Ruby: with
    # `class Process::Status; @@c = nil; end` elsewhere, `Process::Sub.allocate.failures` prints "clean".
    source = "class Status; def x = @@c = :top; end\nmodule Process\n  class Sub < Status\n    " \
             "def set = @@c = 1\n#{reader.gsub(/^/, '  ')}  end\nend\n"
    expect(folds(source)).to eq([])
  end

  it "does not fold under an in-file reopen of a class a bundled signature declares" do
    source = "class StandardError; end\nclass MyErr < StandardError\n  def set = @@c = 1\n#{reader}end\n"
    expect(folds(source)).to eq([])
  end

  it "does not fold in an in-file reopen of a class a bundled signature declares" do
    # Ruby: another file's `class StandardError; @@c = nil; end` shares the slot with this reopening.
    source = "class StandardError\n  def set = @@c = 1\n#{reader}end\n"
    expect(folds(source)).to eq([])
  end

  it "folds in a headerless class only the project's own signature declares (control)" do
    source = "class Sidecar\n  def set = @@c = 1\n#{reader}end\n"
    sig = { "sidecar.rbs" => "class Sidecar\n  def set: () -> Integer\n  def failures: () -> Integer\nend\n" }
    expect(folds(source, sig: sig)).to eq([guard_line(source)])
  end
end
