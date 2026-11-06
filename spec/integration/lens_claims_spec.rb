# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "rigor/lens"

RSpec.describe "rigor lens documentation claims conformance" do
  let(:fixture) { File.expand_path("fixtures/lens_claims", __dir__) }
  let(:executable) { File.expand_path("../../exe/rigor", __dir__) }
  let(:targets) { %w[lib/formatter.rb lib/library.rb lib/inline.rb lib/broken.rb lib/missing.rb README.txt outside.rb] }

  def invoke(*options)
    out, err, status = Open3.capture3(RbConfig.ruby, executable, "lens", "--format=json", "--workers=0", *options,
                                      *targets)
    [out, err, status.exitstatus]
  end

  def normalize(document)
    document["producer"].merge!("version" => "<version>", "engine_source" => "<engine>")
    document["context"].merge!("rbs_version" => "<rbs>", "digest" => "<digest>")
    document["context"]["plugins"].each do |plugin|
      plugin["version"] = "<version>" if plugin["version"] == Rigor::VERSION
    end
    document
  end

  around do |example|
    Dir.mktmpdir do |directory|
      FileUtils.cp_r(File.join(fixture, "project", "."), directory)
      FileUtils.cp(File.join(fixture, "request.json"), directory)
      Dir.chdir(directory) { example.run }
    end
  end

  it "matches the checked-in document, stderr, status and independent verdict expectations" do
    out, err, status = invoke("--claims=request.json")
    document = normalize(JSON.parse(out))
    if ENV["RIGOR_CLAIMS_FIXTURE_WRITE"]
      File.write(File.join(fixture, "expected.json"), "#{JSON.pretty_generate(document)}\n")
      File.write(File.join(fixture, "stderr.txt"), err)
      File.write(File.join(fixture, "exit-status.txt"), "#{status}\n")
    end
    expected = JSON.parse(File.read(File.join(fixture, "verdicts.json")))
    actual = document.fetch("claims").fetch("results").to_h do |row|
      [row.fetch("id"), row.values_at("verdict", "reason")]
    end
    expect(actual).to eq(expected)
    second_param = document.fetch("claims").fetch("results").find { |row| row["id"] == "second-identical-param" }
    expect(second_param.fetch("slot")).to include("name" => "second", "param_kind" => "required", "index" => 1)
    unknown_reasons = actual.values.filter_map { |verdict, reason| reason if verdict == "unknown" }
    expect(unknown_reasons.uniq).to match_array(
      %w[no_such_declaration unsupported_declaration declaration_mismatch unsupported_subject
         no_authored_contract unsupported_contract_source extrbs_contract refined_contract
         unsupported_overloads no_such_parameter unsupported_parameter_kind unmatched_parameter
         unsupported_grammar_feature unresolved_name ambiguous_name dynamic_type unsupported_type unproven]
    )
    expect(status).to eq(Integer(File.read(File.join(fixture, "exit-status.txt"))))
    expect(err).to eq(File.read(File.join(fixture, "stderr.txt")))
    expect(document).to eq(JSON.parse(File.read(File.join(fixture, "expected.json"))))
  end

  it "leaves every lens field and warm-run answer unchanged apart from claims" do
    ordinary, = invoke
    first, = invoke("--claims=request.json")
    second, = invoke("--claims=request.json")
    document = JSON.parse(first)
    expect(document.merge("claims" => nil)).to eq(JSON.parse(ordinary))
    expect(second).to eq(first)
    expect(document.fetch("claims").fetch("request_digest")).to eq(Rigor::Lens.digest(File.binread("request.json")))
  end

  it "rejects each checked-in integrity error before analysis with no document" do
    directory = File.join(fixture, "integrity")
    FileUtils.cp_r(directory, ".")
    cases = JSON.parse(File.read(File.join(directory, "cases.json")))
    expect(cases.size).to eq(15)
    cases.each do |entry|
      out, err, status = invoke("--claims=integrity/#{entry.fetch('request')}")
      expect(status).to eq(64), entry.fetch("request")
      expect(out).to eq(""), entry.fetch("request")
      expect(err).to include(entry.fetch("reason"))
      expect(File).not_to exist(".rigor/cache")
      capture = { "stdout" => out, "stderr" => err, "exit_status" => status }
      expected_path = File.join(directory, "#{entry.fetch('request')}.expected.json")
      File.write(expected_path, "#{JSON.pretty_generate(capture)}\n") if ENV["RIGOR_CLAIMS_FIXTURE_WRITE"]
      expect(capture).to eq(JSON.parse(File.read(expected_path)))
    end
  end

  it "answers unavailable when the target fails analysis" do
    out, err, status = invoke("--config=failed.yml", "--claims=request.json")
    document = normalize(JSON.parse(out))
    results = document.fetch("claims").fetch("results")
    expect(status).to eq(1)
    expect(results.first).to include("verdict" => "unavailable", "reason" => "failed")
    expect(results).to all(include("verdict" => "unavailable"))
    capture = { "document" => document, "stderr" => err, "exit_status" => status }
    expected_path = File.join(fixture, "failed.expected.json")
    File.write(expected_path, "#{JSON.pretty_generate(capture)}\n") if ENV["RIGOR_CLAIMS_FIXTURE_WRITE"]
    expect(capture).to eq(JSON.parse(File.read(expected_path)))
  end
end
