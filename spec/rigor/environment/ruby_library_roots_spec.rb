# frozen_string_literal: true

# Issue #2174 — each source `RubyLibraryRoots` reads, against a stubbed directory, so each fails on its own.

require "spec_helper"
require "tmpdir"
require "fileutils"
require "rigor/environment/ruby_library_roots"

RSpec.describe Rigor::Environment::RubyLibraryRoots do
  around do |example|
    Dir.mktmpdir("rigor-library-roots-") { |dir| Dir.chdir(dir) { example.run } }
  end

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  before do
    write("stdlib/net-smtp/0/net-smtp.rbs", "module Net\n  class SMTP\n  end\nend\n")
    write("rubylib/weakref.rb", "class WeakRef < Delegator\nend\n")
    write("gems/matrix-0.4.3/lib/matrix.rb", "class Matrix\nend\nclass Vector\nend\n")
    write("gems/notshipped-1.0.0/lib/notshipped.rb", "module Notshipped\nend\n")
    stub_const("#{described_class}::STDLIB_ROOT", File.expand_path("stdlib"))
    stub_const("#{described_class}::RUBY_LIB_DIR", File.expand_path("rubylib"))
    stub_const("#{described_class}::RUBY_GEMS_DIR", File.expand_path("gems"))
  end

  let(:roots) { described_class.build }

  it "reads a stdlib library's roots under its first dash segment" do
    expect(roots["Net"]).to eq(Set["net"])
  end

  it "reads the interpreter library directory's roots under the file's name" do
    expect(roots["WeakRef"]).to eq(Set["weakref"])
  end

  it "reads a bundled gem's entry file" do
    expect(roots["Matrix"]).to eq(Set["matrix"])
    expect(roots["Vector"]).to eq(Set["matrix"])
  end

  it "does not read a gem installed beside the interpreter that Ruby does not bundle" do
    expect(roots).not_to have_key("Notshipped")
  end
end
