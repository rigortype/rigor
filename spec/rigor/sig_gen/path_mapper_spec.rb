# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Rigor::SigGen::PathMapper do
  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmpdir) }

  def configuration(paths: ["lib"], signature_paths: ["sig"])
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => paths,
        "signature_paths" => signature_paths
      ).compact
    )
  end

  def mapper(**)
    described_class.new(configuration: configuration(**), project_root: tmpdir)
  end

  it "maps lib/foo.rb to sig/foo.rbs by stripping the source root prefix" do
    target = mapper.target_for("lib/foo.rb")

    expect(target.to_s).to eq(File.join(tmpdir, "sig/foo.rbs"))
  end

  it "preserves the relative subpath under the source root" do
    target = mapper.target_for("lib/foo/bar/baz.rb")

    expect(target.to_s).to eq(File.join(tmpdir, "sig/foo/bar/baz.rbs"))
  end

  it "honours a custom source root and signature root" do
    target = mapper(paths: ["/abs/app"], signature_paths: ["sig-rbs"]).target_for("app/models/user.rb")

    expect(target.to_s).to eq(File.join(tmpdir, "sig-rbs/models/user.rbs"))
  end

  it "leaves paths that are not under any source root in place" do
    target = mapper.target_for("vendor/extra.rb")

    expect(target.to_s).to eq(File.join(tmpdir, "sig/vendor/extra.rbs"))
  end

  describe "layout-index integration" do
    let(:layout_index) do
      dir = File.join(tmpdir, "sig")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "foo.rbs"), "class MyClass\nend\n")
      Rigor::SigGen::LayoutIndex.new(signature_paths: [dir], project_root: tmpdir)
    end

    def mapper_with_index(**)
      described_class.new(configuration: configuration(**), project_root: tmpdir, layout_index: layout_index)
    end

    it "resolves a mapped file through the layout index" do
      m = mapper_with_index
      result = m.existing_target_for("MyClass")
      expect(result).not_to be_nil
      expect(result.to_s).to match(%r{sig/foo\.rbs$})
    end

    it "returns nil for class names not in the index" do
      m = mapper_with_index
      expect(m.existing_target_for("NoSuchClass")).to be_nil
    end
  end

  describe "strip_source_root (private helper)" do
    it "returns a bare Pathname when the entire path is the source root" do
      m = mapper
      result = m.send(:strip_source_root, Pathname(m.send(:source_root_name)))
      expect(result).to eq(Pathname(""))
    end
  end
end
