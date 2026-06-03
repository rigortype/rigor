# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"
require "rigor/cli/command"

RSpec.describe Rigor::CLI::Command do
  describe "#initialize" do
    it "defaults the streams to $stdout / $stderr" do
      command = described_class.new(argv: ["x"])

      expect(command.instance_variable_get(:@argv)).to eq(["x"])
      expect(command.instance_variable_get(:@out)).to be($stdout)
      expect(command.instance_variable_get(:@err)).to be($stderr)
    end

    it "accepts injected streams" do
      out = StringIO.new
      err = StringIO.new
      command = described_class.new(argv: [], out: out, err: err)

      expect(command.instance_variable_get(:@out)).to be(out)
      expect(command.instance_variable_get(:@err)).to be(err)
    end
  end

  describe "#collect_paths" do
    subject(:command) { described_class.new(argv: [], err: err) }

    let(:err) { StringIO.new }

    it "expands directories to their .rb files and keeps explicit files, de-duplicated" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.rb"), "")
        File.write(File.join(dir, "b.rb"), "")
        File.write(File.join(dir, "c.txt"), "")
        explicit = File.join(dir, "a.rb")

        paths = command.send(:collect_paths, [dir, explicit], command_name: "demo")

        expect(paths).to contain_exactly(File.join(dir, "a.rb"), File.join(dir, "b.rb"))
        expect(err.string).to be_empty
      end
    end

    it "returns nil and reports the offending arg under the command name" do
      result = command.send(:collect_paths, ["/no/such/path"], command_name: "type-scan")

      expect(result).to be_nil
      expect(err.string).to eq("type-scan: not a file or directory: /no/such/path\n")
    end
  end
end
