# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "rigor/protection/discovery_seed"

# #1624 across files. `DefinerResolution`'s answer past a class's last superclass turns on facts of the file that
# declares the superclass (an expression there is UNKNOWN, a constant naming a project class is followed) and on a
# project reopening of `Object` anywhere. No firing site reads ABSENT and UNKNOWN differently for these shapes yet,
# so a warm run cannot show the difference as a diagnostic; this pins what the warm run's re-check rests on instead:
# in each world the read gives the answer the tree implies and, read while a dependency recording is active, files
# the edge a change to that fact fires (the declaring file's site, or the negative method edge on `Object.ox`).
RSpec.describe "a superclass the tables cannot follow — dependency edges (#1624)" do
  let(:dir) { Dir.mktmpdir("rigor-opaque-superclass-") }

  after { FileUtils.rm_rf(dir) }

  def write(name, source) = File.write(File.join(dir, name), source)

  def scope
    tables = Rigor::Protection::DiscoverySeed.discovery_tables(Dir[File.join(dir, "*.rb")])
    base = Rigor::Scope.empty
    base.with_discovery(base.discovery.with(**tables))
  end

  # The read's answer and the record a consumer in `c.rb` keeps of it.
  def read(name, side)
    answer = nil
    record = Rigor::Analysis::DependencyRecorder.record_for(File.join(dir, "c.rb")) do
      answer = case Rigor::Inference::DefinerResolution.resolve(scope, "Media", name, side, question: :definer)
               in Rigor::Inference::DefinerResolution::Known(answer: _, owner:) then owner
               in Rigor::Inference::DefinerResolution::UNKNOWN then :unknown
               in Rigor::Inference::DefinerResolution::ABSENT then :absent
               end
    end
    [answer, record]
  end

  def declaring_file_filed?(record) = record.sources.any? { |path| File.basename(path) == "a.rb" }

  before do
    write("base.rb", "class Base\n  def x = 1\nend\n")
    write("c.rb", "Media.new\n")
  end

  it "answers each world's way and files the declaring file when the expression becomes a constant" do
    write("a.rb", "class Media < Class.new(Base)\n  def own = 1\nend\n")
    answer, record = read(:zzz, :instance)
    expect(answer).to eq(:unknown)
    expect(declaring_file_filed?(record)).to be(true)

    write("a.rb", "class Media < Base\n  def own = 1\nend\n")
    answer, record = read(:zzz, :instance)
    expect(answer).to eq(:absent)
    expect(declaring_file_filed?(record)).to be(true)
  end

  it "answers each world's way and files the declaring file when the constant becomes an expression" do
    write("a.rb", "class Media < Base\n  def own = 1\nend\n")
    expect(read(:zzz, :instance).first).to eq(:absent)

    write("a.rb", "class Media < Struct.new(:a)\n  def own = 1\nend\n")
    answer, record = read(:zzz, :instance)
    expect(answer).to eq(:unknown)
    expect(declaring_file_filed?(record)).to be(true)
  end

  it "files the negative method edge a new reopening of `Object` fires, and is Unknown once it exists" do
    write("a.rb", "class Media\n  def own = 1\nend\n")
    answer, record = read(:ox, :singleton)
    expect(answer).to eq(:absent)
    expect(record.missing).to include("method:Object.ox")

    write("object.rb", "class Object\n  def self.ox = 1\nend\n")
    expect(read(:ox, :singleton).first).to eq(:unknown)
  end
end
