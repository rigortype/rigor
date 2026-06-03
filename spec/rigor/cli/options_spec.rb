# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "optionparser"
require "tmpdir"
require "rigor/cli/options"

RSpec.describe Rigor::CLI::Options do
  describe ".add_editor_mode" do
    it "parses the --tmp-file / --instead-of pair into the options hash" do
      options = {}
      parser = OptionParser.new { |opts| described_class.add_editor_mode(opts, options) }
      parser.parse!(["--tmp-file=/tmp/buf.rb", "--instead-of=lib/real.rb"])

      expect(options).to eq(tmp_file: "/tmp/buf.rb", instead_of: "lib/real.rb")
    end
  end

  describe ".resolve_buffer_binding" do
    let(:err) { StringIO.new }

    it "returns nil when neither editor-mode flag is set" do
      expect(described_class.resolve_buffer_binding({}, err: err)).to be_nil
      expect(err.string).to be_empty
    end

    it "returns :usage_error and explains when the flags are unpaired" do
      result = described_class.resolve_buffer_binding({ tmp_file: "/tmp/x.rb" }, err: err)

      expect(result).to eq(:usage_error)
      expect(err.string).to include("--tmp-file and --instead-of must appear together")
    end

    it "returns :usage_error when the temp file is unreadable" do
      result = described_class.resolve_buffer_binding(
        { tmp_file: "/no/such/buffer.rb", instead_of: "lib/real.rb" }, err: err
      )

      expect(result).to eq(:usage_error)
      expect(err.string).to include("no such file or not readable")
    end

    it "returns a BufferBinding for a valid, readable pair" do
      Dir.mktmpdir do |dir|
        tmp = File.join(dir, "buffer.rb")
        File.write(tmp, "x = 1\n")

        binding = described_class.resolve_buffer_binding(
          { tmp_file: tmp, instead_of: "lib/real.rb" }, err: err
        )

        expect(binding).to be_a(Rigor::Analysis::BufferBinding)
        expect(binding.logical_path).to eq("lib/real.rb")
        expect(binding.physical_path).to eq(tmp)
        expect(err.string).to be_empty
      end
    end
  end
end
