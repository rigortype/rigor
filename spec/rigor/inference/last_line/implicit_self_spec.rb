# frozen_string_literal: true

require "spec_helper"
require "prism"

# Issue #1415 (ADR-117 WD5) — an implicit-self or `self.` reader narrows `$_` while the file gives it a `self` whose
# ancestry holds no reader written in Ruby. Each shape cites what Ruby 4.0.5 answers for `$_` after the reader.
RSpec.describe Rigor::Inference::LastLine::ImplicitSelf do
  let(:project) { Rigor::Scope.empty(environment: Rigor::Environment.for_project(signature_paths: [])) }

  # Whether the last implicit-self reader in `source`, indexed from `seed`, narrows `$_`.
  def reads_line?(source, seed = project)
    tree = Prism.parse(source).value
    index = Rigor::Inference::ScopeIndexer.index(tree, default_scope: seed)
    readers = []
    tree.breadth_first_search do |node|
      readers << node if node.is_a?(Prism::CallNode) && %i[gets readline].include?(node.name) &&
                         (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
      false
    end
    reader = readers.max_by { |node| node.location.start_offset }
    Rigor::Inference::LastLine.reads_line?(reader, index[reader])
  end

  # Ruby: the line on each.
  it "narrows on `main` and on a class or module whose ancestry holds only `Kernel`'s or a C reader" do
    ["while gets; end", "def lines = (1 if gets)", "self.readline", "items.each { gets }",
     "class A\n  def x = gets\nend", "class A\n  def self.x = gets\nend", "module M\n  def self.x = gets\nend",
     "class B; end\nclass A < B\n  def x = gets\nend", "class A\n  include Comparable\n  def x = gets\nend",
     "class A < File\n  def x = gets\nend", "class A < StringIO\n  def x = readline\nend",
     "class IO\n  def first_line = gets\nend", "class Object\n  def first_line = gets\nend",
     "module H; end\nclass A\n  include H\n  def x = gets\nend",
     "class B\n  extend Comparable\nend\nclass A < B\n  def self.x = gets\nend",
     "$stdin = StringIO.new('a')\nreadline"].each do |source|
      expect(reads_line?(source)).to be(true), source
    end
  end

  # Ruby: nil on each (a `Struct.new` superclass and a `BasicObject` one aside: the line, and `NameError`).
  it "declines where the ancestry may hold a reader written in Ruby" do
    ["class A < Tempfile\n  def x = gets\nend", "class A < CSV\n  def x = gets\nend",
     "class A < CSV\n  def x = readline\nend",
     "class A < Unknown\n  def x = gets\nend", "class A\n  include Unknown\n  def x = gets\nend",
     "class A < SimpleDelegator\n  def x = gets\nend", "class A < BasicObject\n  def x = gets\nend",
     "class A < DelegateClass(File)\n  def x = gets\nend",
     "class B < DelegateClass(File); end\nclass A < B\n  def x = gets\nend",
     "class B < Tempfile; end\nclass A < B\n  def x = gets\nend", "class A\n  extend Unknown\n  def self.x = gets\nend",
     "class B < Unknown; end\nclass A < B\n  def self.x = gets\nend", "class CSV\n  def first_line = gets\nend",
     "class A\n  include OpenSSL::Buffering\n  def x = gets\nend", "A = Class.new(CSV)\nclass A\n  def x = gets\nend",
     "A = DelegateClass(File)\nclass A\n  def self.x = gets\nend"].each do |source|
      expect(reads_line?(source)).to be(false), source
    end
  end

  # `OpenSSL::Buffering` declares both readers in RBS, in itself (Ruby: nil).
  it "declines on an ancestor whose RBS places a reader outside `Kernel` and `IO` kin" do
    environment = Rigor::Environment.for_project(signature_paths: [], libraries: ["openssl"])
    openssl = Rigor::Scope.empty(environment: environment)

    expect(reads_line?("class A\n  include OpenSSL::Buffering\n  def x = gets\nend", openssl)).to be(false)
    expect(reads_line?("class A < OpenSSL::SSL::SSLSocket\n  def x = gets\nend", openssl)).to be(false)
    expect(reads_line?("class A\n  include Comparable\n  def x = gets\nend", openssl)).to be(true)
  end

  # `Kernel#readline` reads through `$stdin`, which hands a Ruby object its own `readline` (Ruby: nil), while
  # `Kernel#gets` sets `$_` to the line whatever `$stdin` holds (Ruby: the line).
  it "declines `readline`, and not `gets`, after the file binds `$stdin` to a non-reader" do
    expect(reads_line?("$stdin = Object.new\nreadline")).to be(false)
    expect(reads_line?("$stdin = Object.new\ngets")).to be(true)
  end

  # A mixin into `Object` another file of the program declares reaches every object (Ruby: nil).
  it "declines when the program records a mixin into `Object`, `Kernel` or `BasicObject`" do
    %w[Object Kernel BasicObject].each do |root|
      seeded = project.with_discovery(project.discovery.with(discovered_includes: { root => ["RubyReader"] }))
      expect(reads_line?("while gets; end", seeded)).to be(false), root
      expect(reads_line?("class A\n  def x = gets\nend", seeded)).to be(false), root
    end
  end

  # Another file's `A = Class.new(CSV)` reaches this one only through the census of written constant names.
  it "declines a class whose name another file writes as a constant" do
    seeded = project.with_discovery(project.discovery.with(constant_writers: { "A" => Set["A"] }))
    expect(reads_line?("class A\n  def x = gets\nend", seeded)).to be(false)
    expect(reads_line?("class A\n  def x = gets\nend")).to be(true)
  end

  it "declines a reader it holds no evidence for, such as a callee body another file wrote" do
    call = Prism.parse("gets").value.statements.body.first
    expect(described_class.reader?(call, project)).to be(false)
  end
end
