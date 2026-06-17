# frozen_string_literal: true

require "tmpdir"
require "fileutils"

require "rigor/signature_path_audit"

RSpec.describe Rigor::SignaturePathAudit do
  around do |example|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
  end

  describe ".audit" do
    it "returns an empty result for the unset default (nil)" do
      expect(described_class.audit(nil)).to eq([])
    end

    it "returns an empty result for an empty configured list" do
      expect(described_class.audit([])).to eq([])
    end

    it "flags a path that does not exist as :missing" do
      entry = described_class.audit(["/no/such/path/sig"]).fetch(0)

      expect(entry.status).to eq(:missing)
      expect(entry).to be_warning
      expect(entry.rbs_file_count).to eq(0)
      expect(entry.message).to include("does not exist")
    end

    it "flags a directory with no .rbs files as :empty" do
      FileUtils.mkdir_p("emptysig")

      entry = described_class.audit([File.expand_path("emptysig")]).fetch(0)

      expect(entry.status).to eq(:empty)
      expect(entry).to be_warning
      expect(entry.message).to include("matched 0 signature files")
    end

    it "flags an existing non-directory path as :not_directory" do
      File.write("sigs.rbs", "# stub\n")

      entry = described_class.audit([File.expand_path("sigs.rbs")]).fetch(0)

      expect(entry.status).to eq(:not_directory)
      expect(entry).to be_warning
      expect(entry.message).to include("is not a directory")
    end

    it "counts .rbs files (recursively) and reports :ok for a populated directory" do
      FileUtils.mkdir_p("sig/nested")
      File.write("sig/foo.rbs", "class Foo\nend\n")
      File.write("sig/nested/bar.rbs", "class Bar\nend\n")

      entry = described_class.audit([File.expand_path("sig")]).fetch(0)

      expect(entry.status).to eq(:ok)
      expect(entry).not_to be_warning
      expect(entry.rbs_file_count).to eq(2)
    end
  end

  describe ".warnings" do
    it "returns only the entries that resolved to nothing" do
      FileUtils.mkdir_p("sig")
      File.write("sig/foo.rbs", "class Foo\nend\n")

      warnings = described_class.warnings([File.expand_path("sig"), "/no/such/path/sig"])

      expect(warnings.map(&:status)).to eq([:missing])
    end
  end

  describe "Entry#to_h" do
    it "serialises the path, status, count, and message for JSON consumers" do
      hash = described_class.audit(["/no/such/path/sig"]).fetch(0).to_h

      expect(hash).to eq(
        "path" => "/no/such/path/sig",
        "status" => "missing",
        "rbs_file_count" => 0,
        "message" => 'signature_paths: "/no/such/path/sig" does not exist (no signatures loaded from it)'
      )
    end
  end
end
