# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require "rigor/mcp"
require "rigor/cli"

RSpec.describe Rigor::MCP::Server do
  subject(:server) { described_class.new(err: StringIO.new) }

  # Convenience: send a request and round-trip through JSON so all hash accesses use string keys (mirrors the wire
  # format).
  def request(id:, method:, params: nil)
    req = { "id" => id, "method" => method }
    req["params"] = params if params
    JSON.parse(JSON.generate(server.handle(req)))
  end

  def tool_call(name, arguments = {})
    request(id: 1, method: "tools/call",
            params: { "name" => name, "arguments" => arguments })
  end

  # ------------------------------------------------------------------ # Protocol lifecycle #
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

  describe "tools/list" do
    it "lists the eight expected tool names" do
      resp = request(id: 2, method: "tools/list")

      names = resp.dig("result", "tools").map { |t| t["name"] }
      expect(names).to contain_exactly(
        "rigor_check", "rigor_type_of", "rigor_triage", "rigor_lens",
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

  describe "tools/call with an unknown name" do
    it "returns a -32602 error" do
      resp = tool_call("rigor_nonexistent")

      expect(resp["result"]).to be_nil
      expect(resp.dig("error", "code")).to eq(-32_602)
    end
  end

  # Catalogue-only: no file I/O, so this block stays fast.
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

  describe "rigor_lens" do
    it "returns missing-arg error when files is absent or empty" do
      expect(tool_call("rigor_lens").dig("error", "code")).to eq(-32_602)
      expect(tool_call("rigor_lens", { "files" => [] }).dig("error", "code")).to eq(-32_602)
    end

    it "rejects a files value that is not a list of strings" do
      expect(tool_call("rigor_lens", { "files" => [5] }).dig("error", "code")).to eq(-32_602)
      expect(tool_call("rigor_lens", { "files" => { "a" => "b" } }).dig("error", "code")).to eq(-32_602)
    end

    it "returns the lens/v0 document for a known file" do
      resp = tool_call("rigor_lens", { "files" => ["lib/rigor/version.rb"] })

      expect(resp["error"]).to be_nil
      expect(resp.dig("result", "isError")).to be(false)
      document = JSON.parse(resp.dig("result", "content", 0, "text"))
      expect(document["schema"]).to eq("lens/v0")
      expect(document["files"].first["status"]).to eq("ok")
    end

    it "keeps a command's SystemExit off the JSON-RPC channel and stays up" do
      cli = instance_double(Rigor::CLI)
      allow(cli).to receive(:run) do
        puts "usage" # rubocop:disable RSpec/Output -- writing to stdout is the point: the capture must hold it
        exit(3)
      end
      allow(Rigor::CLI).to receive(:new).and_return(cli)
      resp = nil
      expect { resp = tool_call("rigor_check", { "paths" => ["lib"] }) }.not_to output.to_stdout

      expect(resp.dig("result", "isError")).to be(true)
      expect(request(id: 10, method: "ping")["result"]).to eq({})
    end

    it "reports an error a command printed only to stderr as an error" do
      resp = tool_call("rigor_annotate", { "file" => "no/such/file.rb" })

      expect(resp.dig("result", "isError")).to be(true)
      expect(resp.dig("result", "content", 0, "text")).to include("no/such/file.rb")
    end

    it "reads a file named like a flag as a file, and stays up" do
      resp = tool_call("rigor_lens", { "files" => ["--version"] })

      expect(resp.dig("result", "isError")).to be(false)
      expect(JSON.parse(resp.dig("result", "content", 0, "text"))["files"].first["status"]).to eq("not_found")
      expect(request(id: 9, method: "ping")["result"]).to eq({})
    end
  end

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

  describe "rigor_sig_gen" do
    def text_of(resp)
      resp.dig("result", "content", 0, "text")
    end

    it "threads --params= into argv when a params argument is provided" do
      argv = server.send(:build_argv, "rigor_sig_gen", { "params" => "observed" })
      expect(argv).to include("--params=observed")
    end

    # #1398 — an MCP client never sees stderr, so the "no test root observed" reason rides in the response.
    it "carries the observation report in the response under params=observed" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".rigor.yml"), "paths:\n  - lib\ntest_paths:\n  - tests\n")
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib", "calc.rb"), "class Calc\n  def m(x) = 1\nend\n")

        resp = tool_call("rigor_sig_gen", { "params" => "observed", "paths" => [File.join(dir, "lib")],
                                            "config" => File.join(dir, ".rigor.yml") })

        expect(JSON.parse(text_of(resp)).fetch("observation"))
          .to eq("paths" => [], "missing" => [File.join(dir, "tests")])
      end
    end

    # #2078 — the server runs wherever its client started it; the test roots are found under the config file's
    # directory, not the server's working directory.
    it "auto-detects the test roots under the config file's directory, not the server's working directory" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".rigor.yml"), "paths:\n  - lib\n")
        FileUtils.mkdir_p([File.join(dir, "lib"), File.join(dir, "spec")])
        File.write(File.join(dir, "lib", "calc.rb"), "class Calc\n  def m(x) = 1\nend\n")
        File.write(File.join(dir, "spec", "calc_spec.rb"), "Calc.new.m(42)\n")

        resp = Dir.mktmpdir do |elsewhere|
          Dir.chdir(elsewhere) do
            tool_call("rigor_sig_gen", { "params" => "observed", "config" => File.join(dir, ".rigor.yml") })
          end
        end

        payload = JSON.parse(text_of(resp))
        expect(payload.fetch("observation")).to eq("paths" => [File.join(dir, "spec")], "missing" => [])
        expect(payload.fetch("candidates").map { it["rbs"] }).to include("def m: (42) -> 1")
      end
    end

    it "omits the observation report under the default params policy" do
      resp = tool_call("rigor_sig_gen", { "paths" => ["lib"] })

      expect(JSON.parse(text_of(resp))).not_to have_key("observation")
    end

    # #1991 — sig-gen read a missing path as empty and returned `{"candidates": []}` with nothing to say why.
    # The entry must match the one rigor_check gives the same path.
    it "reports a missing path the way rigor_check does" do
      sig_gen = JSON.parse(text_of(tool_call("rigor_sig_gen", { "paths" => ["missing.rb"] })))
      check = JSON.parse(text_of(tool_call("rigor_check", { "paths" => ["missing.rb"] })))
      entry = { "path" => "missing.rb", "line" => 1, "column" => 1, "severity" => "error",
                "message" => "no such file or directory" }

      expect(sig_gen.fetch("diagnostics")).to include(include(entry))
      expect(check.fetch("diagnostics")).to include(include(entry))
    end

    # Positive control: an existing path has no diagnostics key at all.
    it "omits diagnostics for an existing path" do
      Dir.mktmpdir do |dir|
        file = File.join(dir, "calc.rb")
        File.write(file, "class Calc\n  def m(x) = 1\nend\n")

        resp = tool_call("rigor_sig_gen", { "paths" => [file] })

        expect(resp.dig("result", "isError")).to be(false)
        expect(JSON.parse(text_of(resp))).not_to have_key("diagnostics")
      end
    end
  end

  # #1992 — a `config` naming no file ran with the default configuration and said nothing. Every tool that takes a
  # `config` argument is a row here; a tool added to TOOLS with a `config` belongs in this table too.
  describe "config argument naming no file" do
    def text_of(resp)
      resp.dig("result", "content", 0, "text")
    end

    # Each tool's minimal arguments for one existing Ruby file, so the only thing that can fail is the config.
    config_tool_args = {
      "rigor_check" => ->(file) { { "paths" => [file] } },
      "rigor_type_of" => ->(file) { { "file" => file, "line" => 1, "col" => 1 } },
      "rigor_triage" => ->(file) { { "paths" => [file] } },
      "rigor_lens" => ->(file) { { "files" => [file] } },
      "rigor_annotate" => ->(file) { { "file" => file } },
      "rigor_sig_gen" => ->(file) { { "paths" => [file] } },
      "rigor_coverage" => ->(file) { { "paths" => [file] } }
    }

    config_tool_args.each do |tool, args_for|
      it "reports a missing config as an error for #{tool}" do
        Dir.mktmpdir do |dir|
          file = File.join(dir, "calc.rb")
          File.write(file, "class Calc\n  def m(x) = 1\nend\n")

          ["missing.yml", "--help"].each do |config|
            resp = tool_call(tool, args_for.call(file).merge("config" => config))

            expect(resp.dig("result", "isError")).to be(true), "config #{config.inspect}: #{resp.inspect}"
            expect(text_of(resp)).to include("config file not found: #{config}")
          end
        end
      end

      # Positive control: an existing config file is read and the tool runs.
      it "still runs #{tool} with an existing config file" do
        Dir.mktmpdir do |dir|
          file = File.join(dir, "calc.rb")
          config = File.join(dir, "rigor.yml")
          File.write(file, "class Calc\n  def m(x) = 1\nend\n")
          File.write(config, "paths:\n  - #{dir}\n")

          resp = tool_call(tool, args_for.call(file).merge("config" => config))

          expect(text_of(resp)).not_to include("config file not found")
          expect(resp.dig("result", "isError")).to be(false)
        end
      end
    end
  end

  describe "config_path session default" do
    # A blank per-call `config` names no file: the session default applies, and `--config=` never reaches the CLI.
    it "is used when the per-call config is blank" do
      s = described_class.new(config_path: "/tmp/session.yml", err: StringIO.new)

      ["", "   "].each do |blank|
        argv = s.send(:build_argv, "rigor_check", { "paths" => ["lib/"], "config" => blank })
        expect(argv).to include("--config=/tmp/session.yml")
        expect(argv).not_to include("--config=")
      end
    end

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
        .to eq(["check", "--format=json", "--no-stats", "--config=custom.yml", "--", "lib", "app"])
    end

    it "builds rigor_type_of from file:line:col, nil when any is missing" do
      expect(server.send(:build_argv, "rigor_type_of", { "file" => "a.rb", "line" => 3, "col" => 5 }))
        .to eq(["type-of", "--format=json", "--", "a.rb:3:5"])
      expect(server.send(:build_argv, "rigor_type_of", { "file" => "a.rb" })).to be_nil
    end

    it "builds the full rigor_triage argv including --top and every path" do
      expect(server.send(:build_argv, "rigor_triage", { "top" => 10, "paths" => ["lib"] }))
        .to eq(["triage", "--format=json", "--top=10", "--", "lib"])
    end

    it "builds the full rigor_sig_gen argv including --params and every path" do
      expect(server.send(:build_argv, "rigor_sig_gen", { "params" => "observed", "paths" => ["lib"] }))
        .to eq(["sig-gen", "--print", "--format=json", "--params=observed", "--", "lib"])
    end
  end

  describe "flag-shaped arguments are operands, not options" do
    def text_of(resp)
      resp.dig("result", "content", 0, "text")
    end

    it "ends the options before the paths of every path-taking tool" do
      {
        "rigor_check" => %w[check --format=json --no-stats],
        "rigor_triage" => %w[triage --format=json],
        "rigor_sig_gen" => %w[sig-gen --print --format=json],
        "rigor_coverage" => %w[coverage --format=json]
      }.each do |tool, head|
        expect(server.send(:build_argv, tool, { "paths" => ["--format=text", "--workers=4"] }))
          .to eq([*head, "--", "--format=text", "--workers=4"])
      end
    end

    it "ends the options before the file, the position and the rule" do
      expect(server.send(:build_argv, "rigor_annotate", { "file" => "--x.rb" }))
        .to eq(["annotate", "--no-color", "--", "--x.rb"])
      expect(server.send(:build_argv, "rigor_type_of", { "file" => "--x.rb", "line" => 1, "col" => 2 }))
        .to eq(["type-of", "--format=json", "--", "--x.rb:1:2"])
      expect(server.send(:build_argv, "rigor_explain", { "rule" => "--foo" }))
        .to eq(["explain", "--format=json", "--", "--foo"])
      expect(server.send(:build_argv, "rigor_explain", {})).to eq(["explain", "--format=json"])
    end

    it "does not let rigor_check read a path as --format" do
      resp = tool_call("rigor_check", { "paths" => ["--format=text"] })

      expect(JSON.parse(text_of(resp))).to have_key("diagnostics")
    end

    it "does not let rigor_triage read a path as --format" do
      resp = tool_call("rigor_triage", { "paths" => ["--format=text"] })

      expect(JSON.parse(text_of(resp))).to have_key("distribution")
    end

    it "does not let rigor_sig_gen read a path as --format" do
      resp = tool_call("rigor_sig_gen", { "paths" => ["--format=text"] })

      expect(JSON.parse(text_of(resp))).to have_key("candidates")
    end

    it "reports a flag-shaped rigor_coverage path as a missing path" do
      resp = tool_call("rigor_coverage", { "paths" => ["--workers=4"] })

      expect(resp.dig("result", "isError")).to be(true)
      expect(text_of(resp)).to include("not a file or directory: --workers=4")
    end

    it "reports a flag-shaped rigor_annotate file as a missing file" do
      resp = tool_call("rigor_annotate", { "file" => "--format=text" })

      expect(text_of(resp)).to include("file not found: --format=text")
    end

    it "reports a flag-shaped rigor_type_of file as a missing file" do
      resp = tool_call("rigor_type_of", { "file" => "--x.rb", "line" => 1, "col" => 1 })

      expect(text_of(resp)).to include("file not found: --x.rb")
    end

    it "reports a flag-shaped rigor_explain rule as an unknown rule" do
      resp = tool_call("rigor_explain", { "rule" => "--foo" })

      expect(resp.dig("result", "isError")).to be(true)
      expect(text_of(resp)).to include("Unknown rule: --foo")
    end

    # Guard: it passes with the fix removed; it only asserts the server survives such operands.
    it "survives paths named - and --" do
      %w[- --].each do |path|
        resp = tool_call("rigor_check", { "paths" => [path] })

        expect(resp["error"]).to be_nil
      end
      expect(request(id: 11, method: "ping")["result"]).to eq({})
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
      # The backtrace is logged on its own lines (newline-joined), so the error output spans more than just the one
      # "rigor mcp:" line.
      expect(err.string.lines.count).to be > 2
    end
  end
end
