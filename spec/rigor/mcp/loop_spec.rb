# frozen_string_literal: true

require "json"
require "stringio"
require "rigor/mcp"

RSpec.describe Rigor::MCP::Loop do
  def make_loop(input_lines, server)
    input  = StringIO.new(input_lines.join)
    output = StringIO.new
    loop_instance = described_class.new(input: input, output: output, server: server)
    [loop_instance, output]
  end

  def responses(output_io)
    output_io.string.lines.map { |l| JSON.parse(l) }
  end

  let(:server) do
    Class.new do
      def handle(request)
        id = request["id"]
        return nil unless id

        { "jsonrpc" => "2.0", "id" => id, "result" => { "echo" => request["method"] } }
      end
    end.new
  end

  describe "#run" do
    it "dispatches a well-formed request and writes the response" do
      req = JSON.generate({ "jsonrpc" => "2.0", "id" => 1, "method" => "ping" })
      instance, output = make_loop(["#{req}\n"], server)
      instance.run

      result = responses(output)
      expect(result.size).to eq(1)
      expect(result.first.dig("result", "echo")).to eq("ping")
    end

    it "dispatches multiple requests in order" do
      reqs = [1, 2, 3].map { |i| JSON.generate({ "jsonrpc" => "2.0", "id" => i, "method" => "m#{i}" }) + "\n" }
      instance, output = make_loop(reqs, server)
      instance.run

      ids = responses(output).map { |r| r["id"] }
      expect(ids).to eq([1, 2, 3])
    end

    it "skips blank lines without writing a response" do
      req = JSON.generate({ "jsonrpc" => "2.0", "id" => 1, "method" => "ping" })
      instance, output = make_loop(["\n", "\n", "#{req}\n"], server)
      instance.run

      expect(responses(output).size).to eq(1)
    end

    it "writes a parse-error response for malformed JSON" do
      instance, output = make_loop(["not-json\n"], server)
      instance.run

      result = responses(output)
      expect(result.size).to eq(1)
      expect(result.first.dig("error", "code")).to eq(-32_700)
      expect(result.first["id"]).to be_nil
    end

    it "continues processing after a parse error" do
      req = JSON.generate({ "jsonrpc" => "2.0", "id" => 7, "method" => "ping" })
      instance, output = make_loop(["bad-json\n", "#{req}\n"], server)
      instance.run

      results = responses(output)
      expect(results.size).to eq(2)
      expect(results.last.dig("result", "echo")).to eq("ping")
    end

    it "does not write a response for a notification (server returns nil)" do
      notif = JSON.generate({ "jsonrpc" => "2.0", "method" => "notifications/initialized" })
      instance, output = make_loop(["#{notif}\n"], server)
      instance.run

      expect(output.string).to be_empty
    end

    it "processes no messages when input is empty" do
      instance, output = make_loop([], server)
      instance.run

      expect(output.string).to be_empty
    end
  end
end
