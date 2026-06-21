# frozen_string_literal: true

require "json"
require "stringio"
require "rigor/mcp"
require "rigor/cli"

RSpec.describe Rigor::MCP::Server do
  subject(:server) { described_class.new(err: StringIO.new) }

  # Convenience: send a request and round-trip through JSON so all
  # hash accesses use string keys (mirrors the wire format).
  def request(id:, method:, params: nil)
    req = { "id" => id, "method" => method }
    req["params"] = params if params
    JSON.parse(JSON.generate(server.handle(req)))
  end

  def tool_call(name, arguments = {})
    request(id: 1, method: "tools/call",
            params: { "name" => name, "arguments" => arguments })
  end

  # ------------------------------------------------------------------ #
  # Protocol lifecycle                                                    #
  # ------------------------------------------------------------------ #

  describe "initialize" do
    it "returns the protocol version and server info" do
      resp = request(id: 0, method: "initialize", params: {})

      expect(resp["error"]).to be_nil
      result = resp["result"]
      expect(result["protocolVersion"]).to eq(described_class::PROTOCOL_VERSION)
      expect(result.dig("serverInfo", "name")).to eq("rigor")
      expect(result.dig("serverInfo", "version")).to eq(Rigor::VERSION)
      expect(result.dig("capabilities", "tools", "listChanged")).to be(false)
    end
  end

  describe "ping" do
    it "returns an empty result" do
      resp = request(id: 1, method: "ping")

      expect(resp["error"]).to be_nil
      expect(resp["result"]).to eq({})
    end
  end

  describe "notifications (no id)" do
    it "returns nil for notifications/initialized" do
      result = server.handle({ "method" => "notifications/initialized" })

      expect(result).to be_nil
    end
  end

  describe "unknown method" do
    it "returns a -32601 error" do
      resp = request(id: 9, method: "tools/nope")

      expect(resp["result"]).to be_nil
      expect(resp.dig("error", "code")).to eq(-32_601)
    end
  end

  # ------------------------------------------------------------------ #
  # tools/list                                                            #
  # ------------------------------------------------------------------ #

  describe "tools/list" do
    it "lists the seven expected tool names" do
      resp = request(id: 2, method: "tools/list")

      names = resp.dig("result", "tools").map { |t| t["name"] }
      expect(names).to contain_exactly(
        "rigor_check", "rigor_type_of", "rigor_triage",
        "rigor_annotate", "rigor_sig_gen", "rigor_explain", "rigor_coverage"
      )
    end

    it "includes an inputSchema for each tool" do
      resp = request(id: 2, method: "tools/list")

      resp.dig("result", "tools").each do |tool|
        expect(tool["inputSchema"]).to be_a(Hash), "#{tool['name']} has no inputSchema"
        expect(tool["inputSchema"]["type"]).to eq("object")
      end
    end
  end

  # ------------------------------------------------------------------ #
  # tools/call — unknown tool                                             #
  # ------------------------------------------------------------------ #

  describe "tools/call with an unknown name" do
    it "returns a -32602 error" do
      resp = tool_call("rigor_nonexistent")

      expect(resp["result"]).to be_nil
      expect(resp.dig("error", "code")).to eq(-32_602)
    end
  end

  # ------------------------------------------------------------------ #
  # tools/call — rigor_explain (fast, catalog-only, no file I/O)          #
  # ------------------------------------------------------------------ #

  describe "rigor_explain" do
    it "returns a JSON catalog entry for a known rule" do
      resp = tool_call("rigor_explain", { "rule" => "call.undefined-method" })

      expect(resp["error"]).to be_nil
      result = resp["result"]
      expect(result["isError"]).to be(false)
      text = result.dig("content", 0, "text")
      entries = JSON.parse(text)
      expect(entries).to be_an(Array)
      expect(entries.first["id"]).to eq("call.undefined-method")
    end

    it "returns the full catalog when no rule is given" do
      resp = tool_call("rigor_explain")

      entries = JSON.parse(resp.dig("result", "content", 0, "text"))
      expect(entries.size).to be > 1
      expect(entries.map { |e| e["id"] }).to include("call.undefined-method", "call.wrong-arity")
    end

    it "sets isError=true and exits with usage code for an unknown rule" do
      resp = tool_call("rigor_explain", { "rule" => "no.such.rule.xyz" })

      expect(resp["result"]["isError"]).to be(true)
    end
  end

  # ------------------------------------------------------------------ #
  # tools/call — rigor_check                                              #
  # ------------------------------------------------------------------ #

  describe "rigor_check" do
    it "returns a JSON diagnostic report for a clean file" do
      resp = tool_call("rigor_check", { "paths" => ["lib/rigor/version.rb"] })

      expect(resp["error"]).to be_nil
      result = resp["result"]
      expect(result["isError"]).to be(false)
      parsed = JSON.parse(result.dig("content", 0, "text"))
      expect(parsed).to have_key("diagnostics")
      expect(parsed["diagnostics"]).to be_an(Array)
    end
  end

  # ------------------------------------------------------------------ #
  # tools/call — rigor_type_of                                            #
  # ------------------------------------------------------------------ #

  describe "rigor_type_of" do
    it "returns missing-args error when file/line/col are absent" do
      resp = tool_call("rigor_type_of", { "file" => "lib/rigor/version.rb" })

      expect(resp.dig("error", "code")).to eq(-32_602)
    end

    it "returns the inferred type at a known location" do
      resp = tool_call("rigor_type_of",
                       { "file" => "lib/rigor/version.rb", "line" => 4, "col" => 15 })

      expect(resp["error"]).to be_nil
      result = resp["result"]
      expect(result["isError"]).to be(false)
      parsed = JSON.parse(result.dig("content", 0, "text"))
      expect(parsed["type"]).to be_a(String)
      expect(parsed["type"]).not_to be_empty
    end
  end

  # ------------------------------------------------------------------ #
  # tools/call — rigor_annotate                                           #
  # ------------------------------------------------------------------ #

  describe "rigor_annotate" do
    it "returns missing-arg error when file is absent" do
      resp = tool_call("rigor_annotate")

      expect(resp.dig("error", "code")).to eq(-32_602)
    end

    it "returns annotated source for a known file" do
      resp = tool_call("rigor_annotate", { "file" => "lib/rigor/version.rb" })

      expect(resp["error"]).to be_nil
      text = resp.dig("result", "content", 0, "text")
      expect(text).to include("VERSION")
    end
  end

  # ------------------------------------------------------------------ #
  # tools/call — rigor_triage                                             #
  # ------------------------------------------------------------------ #

  describe "rigor_triage" do
    it "returns a JSON triage report for a known path" do
      resp = tool_call("rigor_triage", { "paths" => ["lib/rigor/version.rb"] })

      expect(resp["error"]).to be_nil
      result = resp["result"]
      expect(result["isError"]).to be(false)
      parsed = JSON.parse(result.dig("content", 0, "text"))
      expect(parsed).to have_key("distribution")
    end

    it "threads --top= into argv when a top argument is provided" do
      argv = server.send(:build_argv, "rigor_triage", { "top" => 5 })
      expect(argv).to include("--top=5")
    end
  end

  # ------------------------------------------------------------------ #
  # tools/call — rigor_coverage                                           #
  # ------------------------------------------------------------------ #

  describe "rigor_coverage" do
    it "returns a JSON precision-coverage report for a known path" do
      resp = tool_call("rigor_coverage", { "paths" => ["lib/rigor/version.rb"] })

      expect(resp["error"]).to be_nil
      result = resp["result"]
      expect(result["isError"]).to be(false)
      parsed = JSON.parse(result.dig("content", 0, "text"))
      expect(parsed).to have_key("by_file")
    end
  end

  # ------------------------------------------------------------------ #
  # tools/call — rigor_sig_gen                                            #
  # ------------------------------------------------------------------ #

  describe "rigor_sig_gen" do
    it "threads --params= into argv when a params argument is provided" do
      argv = server.send(:build_argv, "rigor_sig_gen", { "params" => "observed" })
      expect(argv).to include("--params=observed")
    end
  end

  # ------------------------------------------------------------------ #
  # Session-level --config default propagation                            #
  # ------------------------------------------------------------------ #

  describe "config_path session default" do
    it "is threaded into build_argv as a --config flag" do
      s = described_class.new(config_path: "/tmp/fake.yml", err: StringIO.new)
      # We test the private helper directly to avoid needing a real config file.
      argv = s.send(:build_argv, "rigor_check", { "paths" => ["lib/"] })

      expect(argv).to include("--config=/tmp/fake.yml")
    end

    it "is overridden by a per-call config argument" do
      s = described_class.new(config_path: "/tmp/session.yml", err: StringIO.new)
      argv = s.send(:build_argv, "rigor_check",
                    { "paths" => ["lib/"], "config" => "/tmp/call.yml" })

      expect(argv).to include("--config=/tmp/call.yml")
      expect(argv).not_to include("--config=/tmp/session.yml")
    end
  end

  describe "build_argv exact argv (pins each args[...] read)" do
    it "builds the full rigor_check argv including config and every path" do
      expect(server.send(:build_argv, "rigor_check", { "config" => "custom.yml", "paths" => %w[lib app] }))
        .to eq(["check", "--format=json", "--no-stats", "--config=custom.yml", "lib", "app"])
    end

    it "builds rigor_type_of from file:line:col, nil when any is missing" do
      expect(server.send(:build_argv, "rigor_type_of", { "file" => "a.rb", "line" => 3, "col" => 5 }))
        .to eq(["type-of", "--format=json", "a.rb:3:5"])
      expect(server.send(:build_argv, "rigor_type_of", { "file" => "a.rb" })).to be_nil
    end

    it "builds the full rigor_triage argv including --top and every path" do
      expect(server.send(:build_argv, "rigor_triage", { "top" => 10, "paths" => ["lib"] }))
        .to eq(["triage", "--format=json", "--top=10", "lib"])
    end

    it "builds the full rigor_sig_gen argv including --params and every path" do
      expect(server.send(:build_argv, "rigor_sig_gen", { "params" => "observed", "paths" => ["lib"] }))
        .to eq(["sig-gen", "--print", "--format=json", "--params=observed", "lib"])
    end
  end

  describe "call_tool error handling" do
    it "returns an internal-error result and logs when the CLI raises" do
      err = StringIO.new
      s = described_class.new(err: err)
      allow(Rigor::CLI).to receive(:new).and_raise(StandardError.new("kaboom"))

      resp = JSON.parse(JSON.generate(s.handle(
                                        "id" => 1, "method" => "tools/call",
                                        "params" => { "name" => "rigor_check", "arguments" => { "paths" => ["lib"] } }
                                      )))

      expect(resp["result"]["isError"]).to be(true)
      expect(resp.dig("result", "content", 0, "text")).to include("kaboom")
      expect(err.string).to include("rigor mcp:").and include("kaboom")
      # The backtrace is logged on its own lines (newline-joined), so the
      # error output spans more than just the one "rigor mcp:" line.
      expect(err.string.lines.count).to be > 2
    end
  end
end
