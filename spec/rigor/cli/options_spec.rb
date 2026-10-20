# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "optionparser"
require "tmpdir"
require "fileutils"
require "rigor/cli/options"

RSpec.describe Rigor::CLI::Options do
  describe ".add_config" do
    # #1992 — the file the flag names must exist; the example makes one.
    it "parses --config=PATH into options[:config]" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          File.write("custom.yml", "")
          options = {}
          parser = OptionParser.new { |opts| described_class.add_config(opts, options) }
          parser.parse!(["--config=custom.yml"])

          expect(options[:config]).to eq("custom.yml")
        end
      end
    end

    # #1992 — a path that names no file is refused where the flag is read, not handed on to a run that would use
    # the defaults.
    it "refuses a --config=PATH that names no file" do
      options = {}
      parser = OptionParser.new { |opts| described_class.add_config(opts, options) }

      expect { parser.parse!(["--config=missing.yml"]) }
        .to raise_error(Rigor::ConfigurationError, "config file not found: missing.yml")
      expect(options).not_to have_key(:config)
    end

    # The other ways a --config can name no usable file each get their own message.
    it "says why a --config names no usable file" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          FileUtils.mkdir_p("conf.d")
          File.write("locked.yml", "")
          allow(File).to receive(:readable?).and_call_original
          allow(File).to receive(:readable?).with("locked.yml").and_return(false)

          {
            "--config=" => "empty config path",
            "--config=conf.d" => "config path is a directory: conf.d",
            "--config=locked.yml" => "config file not readable: locked.yml"
          }.each do |argument, message|
            parser = OptionParser.new { |opts| described_class.add_config(opts, {}) }
            expect { parser.parse!([argument]) }.to raise_error(Rigor::ConfigurationError, message)
          end
        end
      end
    end

    it "keeps a readable file it is given" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          File.write("ok.yml", "")
          options = {}
          OptionParser.new { |opts| described_class.add_config(opts, options) }.parse!(["--config=ok.yml"])

          expect(options[:config]).to eq("ok.yml")
        end
      end
    end
  end

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
