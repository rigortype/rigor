# frozen_string_literal: true

# Issue #2174 — a `require` of a library Ruby ships enters the incremental snapshot's fingerprint only when that
# library declares a root the project's own source or signatures declare a class or module under: only then can it
# open a class (`RbsLoader#ruby_library_reopen?`), so only then must every file be re-checked. Anywhere else the
# edit re-checks the one file it touched.

require "spec_helper"
require "tmpdir"
require "fileutils"
require "rigor/configuration"
require "rigor/cache/incremental_snapshot"

RSpec.describe Rigor::Cache::IncrementalSnapshot, ".fingerprint" do
  around do |example|
    Dir.mktmpdir("rigor-shipped-features-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:configuration) { Rigor::Configuration.new("paths" => %w[lib]) }

  def fingerprint = described_class.fingerprint(configuration: configuration, roots: %w[lib])

  before do
    FileUtils.mkdir_p("lib")
    File.write("lib/a.rb", "class Foo\nend\n")
  end

  it "stays warm when a stdlib require is added to a project that reopens no library class" do
    before = fingerprint
    File.write("lib/b.rb", "require \"json\"\n")

    expect(fingerprint).to eq(before)
  end

  it "goes cold when the required library declares a class the project's source reopens" do
    File.write("lib/m.rb", "class Matrix\nend\n")
    before = fingerprint
    File.write("lib/b.rb", "require \"matrix\"\n")

    expect(fingerprint).not_to eq(before)
  end

  it "goes cold when the class is reopened only in the project's signatures" do
    FileUtils.mkdir_p("sig")
    File.write("sig/ripper.rbs", "class Ripper\nend\n")
    before = fingerprint
    File.write("lib/b.rb", "require \"ripper\"\n")

    expect(fingerprint).not_to eq(before)
  end
end
