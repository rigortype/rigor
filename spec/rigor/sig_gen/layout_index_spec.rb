# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Rigor::SigGen::LayoutIndex do
  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmpdir) }

  def write_sig(rel, content)
    full = File.join(tmpdir, rel)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
    full
  end

  def index(*sig_dirs)
    described_class.new(signature_paths: sig_dirs, project_root: tmpdir)
  end

  it "maps a top-level class to its declaring sig file" do
    path = write_sig("sig/foo.rbs", "class Foo\nend\n")

    expect(index(File.join(tmpdir, "sig")).file_for("Foo")).to eq(Pathname(path))
  end

  it "skips an invalid-UTF-8 sig file before it reaches the parser, keeping its siblings indexed" do
    # Pre-parser encoding guard: rbs releases before 4.1 could hang the C lexer on an invalid byte — a
    # failure the index's rescue cannot absorb — so the file must be rejected on encoding alone. `\xE9` is a
    # bare Latin-1 é, invalid in UTF-8; the declarations around it are well-formed.
    good = write_sig("sig/foo.rbs", "class Foo\nend\n")
    File.binwrite(File.join(tmpdir, "sig/broken.rbs"), "class Broken\nend\n# caf\xE9\n")
    idx = index(File.join(tmpdir, "sig"))

    expect(idx.file_for("Foo")).to eq(Pathname(good))
    expect(idx.file_for("Broken")).to be_nil
  end

  it "walks nested modules / classes and indexes fully-qualified names" do
    path = write_sig("sig/all.rbs", <<~RBS)
      module Outer
        module Inner
          class Leaf
          end
        end
        class Sibling
        end
      end
    RBS
    idx = index(File.join(tmpdir, "sig"))

    expect(idx.file_for("Outer")).to eq(Pathname(path))
    expect(idx.file_for("Outer::Inner")).to eq(Pathname(path))
    expect(idx.file_for("Outer::Inner::Leaf")).to eq(Pathname(path))
    expect(idx.file_for("Outer::Sibling")).to eq(Pathname(path))
  end

  it "returns nil for class names with no declaration" do
    write_sig("sig/foo.rbs", "class Foo\nend\n")

    expect(index(File.join(tmpdir, "sig")).file_for("Bar")).to be_nil
  end

  it "applies the auto-detect default when signature_paths is nil" do
    write_sig("sig/foo.rbs", "class Foo\nend\n")

    auto = described_class.new(signature_paths: nil, project_root: tmpdir)

    expect(auto.file_for("Foo")).to eq(Pathname(File.join(tmpdir, "sig/foo.rbs")))
  end

  it "skips files that fail to parse (no crash)" do
    write_sig("sig/bad.rbs", "this is not RBS{{{ syntax\n")
    write_sig("sig/good.rbs", "class Good\nend\n")

    idx = index(File.join(tmpdir, "sig"))

    expect(idx.file_for("Good")).not_to be_nil
  end

  it "first-found wins when multiple files declare the same class" do
    path_a = write_sig("sig/a.rbs", "class Same\nend\n")
    write_sig("sig/b.rbs", "class Same\nend\n")

    expect(index(File.join(tmpdir, "sig")).file_for("Same")).to eq(Pathname(path_a))
  end

  it "reports empty? as true when no sig paths contain declarations" do
    FileUtils.mkdir_p(File.join(tmpdir, "empty_sig"))
    idx = described_class.new(signature_paths: [File.join(tmpdir, "empty_sig")], project_root: tmpdir)
    expect(idx.empty?).to be(true)
  end

  it "reports empty? as false when declarations exist" do
    write_sig("sig/foo.rbs", "class Foo\nend\n")
    idx = index(File.join(tmpdir, "sig"))
    expect(idx.empty?).to be(false)
  end
end
