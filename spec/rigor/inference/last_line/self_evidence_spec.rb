# frozen_string_literal: true

require "spec_helper"
require "prism"

# Issue #1415 (ADR-117 WD5) — what a file shows about the `self` its implicit-self readers run with. Each shape cites
# what Ruby 4.0.5 answers for `$_` after the reader, with a module whose readers are written in Ruby mixed in.
RSpec.describe Rigor::Inference::LastLine::SelfEvidence do
  # The context of the last implicit-self `gets` / `readline` in `source`.
  def context_of(source)
    tree = Prism.parse(source).value
    readers = []
    tree.breadth_first_search do |node|
      readers << node if node.is_a?(Prism::CallNode) && %i[gets readline].include?(node.name) &&
                         (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
      false
    end
    described_class.new(tree).context(readers.max_by { |node| node.location.start_offset })
  end

  it "places a reader in the script body, a top-level method or a top-level `class << self` on `main`" do
    ["while gets; end", "def lines = gets", "self.gets", "self.readline", "items.each { gets }",
     "class << self\n  def lines = gets\nend", "def self.lines = gets"].each do |source|
      expect(context_of(source)).to eq(described_class::MAIN), source
    end
  end

  it "places a reader in a class body, its methods and a module's own body and singleton methods on the declaration" do
    ["class A\n  def x = gets\nend", "class A\n  def self.x = gets\nend", "class A\n  gets\nend",
     "class A\n  class << self\n    def x = gets\n  end\nend", "module M\n  def self.x = gets\nend",
     "module M\n  gets\nend",
     "class A\n  include Comparable\n  extend Forwardable\n  def x = gets\nend",
     "module U\n  extend self\n  def self.x = gets\nend",
     "class A < Base\n  def x = gets\nend", "class A < ::B::C\n  def x = gets\nend"].each do |source|
      expect(context_of(source)).to be_a(Prism::ClassNode).or(be_a(Prism::ModuleNode)), source
    end
  end

  # Ruby: nil on each, with the block's or method's `self` one whose reader is Ruby's.
  it "gives no context to a reader whose `self` a block or method may rebind" do
    ["o.instance_eval { gets }", "o.instance_exec { gets }", "k.class_eval { gets }", "m.module_eval { gets }",
     "k.class_exec { gets }", "m.module_exec { gets }", "define_method(:x) { gets }",
     "k.define_singleton_method(:x) { gets }",
     "o.instance_eval { items.each { gets } }", "Class.new(CSV) { gets }", "::Class.new(CSV) { gets }",
     "Struct.new(:a) { def x = gets }", "Data.define(:a) { def x = gets }", "[1].each { def x = gets }",
     "o.instance_eval { def x = gets }", "class << obj\n  def x = gets\nend", "def obj.x = gets",
     "module M\n  def x = gets\nend", "module M\n  module_function\n  def x = gets\nend",
     "o.send(:instance_eval) { gets }", "o.public_send(name) { gets }"].each do |source|
      expect(context_of(source)).to be_nil, source
    end
  end

  # Ruby: nil on each where the ancestor is a gem's Ruby reader; declined all the same where it is not.
  it "gives no context to a reader in a declaration that may gain an ancestor the tables do not record" do
    ["class A < DelegateClass(File)\n  def x = gets\nend", "class A < Struct.new(:io)\n  def x = gets\nend",
     "class A\n  def initialize = extend(M)\n  def x = gets\nend", "class A\n  include(*mods)\n  def x = gets\nend",
     "class A\n  include mod\n  def x = gets\nend", "class A\n  if ok\n    include M\n  end\n  def x = gets\nend",
     "class A\n  class << self\n    include M\n  end\n  def self.x = gets\nend",
     "class A\n  singleton_class.include(M)\n  def self.x = gets\nend"].each do |source|
      expect(context_of(source)).to be_nil, source
    end
  end

  # Ruby: nil on each, except `Kernel.include` and the `BasicObject` mixins, where `Kernel#gets` still comes first.
  it "gives no reader in the file a context once the file may change what `main` or `Object` reaches" do
    ["include M", "extend M", "using R", "send(:include, M)", "public_send(:extend, M)", "__send__('prepend', M)",
     "send(name, M)", "send(*args)", "class << self\n  include M\nend", "singleton_class.include(M)",
     "self.singleton_class.extend(M)", "TOPLEVEL_BINDING.receiver.extend(M)", "Object.include(M)", "Object.prepend(M)",
     "Kernel.include(M)", "::Kernel.prepend(M)", "BasicObject.include(M)", "Object.extend(M)", "self.class.include(M)",
     "obj.extend(M)", "class Object\n  include M\nend", "module Kernel\n  prepend M\nend", "Object.send(:include, M)",
     "o.instance_eval { include M }", "blk = -> { 1 }\no.instance_exec(&blk)", "define_method(:x, blk)",
     "class A\n  using R\nend", "eval(code)", "Object.class_eval('include M')", "binding.eval(src)",
     "Object.const_set(:W, Class.new(CSV))"].each do |shape|
      expect(context_of("#{shape}\nwhile gets; end")).to be_nil, shape
      expect(context_of("while gets; end\n#{shape}")).to be_nil, shape
    end
  end

  # Ruby: nil for the name the file defines on `main` or puts in place through a macro; the other reader is untouched.
  it "gives no context to a reader of a name the file defines, or writes as a literal a macro may define" do
    ["def self.gets = 1", "class << self\n  def gets = 1\nend", "define_singleton_method(:gets) { 1 }",
     "def_delegators :@io, :gets", "attr_reader :gets", "undef_method 'gets'", "alias gets to_s"].each do |shape|
      expect(context_of("#{shape}\nwhile gets; end")).to be_nil, shape
      expect(context_of("#{shape}\nwhile readline; end")).to eq(described_class::MAIN), shape
    end
  end

  it "keeps the context across a call that only names a reader, and a block argument that runs one" do
    ["respond_to?(:gets)", "io.send(:gets)", "method(:gets)", "ios.each(&:gets)", "o.instance_exec(&:gets)",
     "o.instance_exec(1, 2) { |a, b| a }", "items.map { |i| i }", "class A\n  include Comparable\nend"].each do |shape|
      expect(context_of("#{shape}\nwhile gets; end")).to eq(described_class::MAIN), shape
    end
  end
end
