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
end
