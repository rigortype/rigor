# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require "rigor/lens"
require "rigor/lens/claims/request"

RSpec.describe Rigor::Lens::Claims::Request do
  let(:directory) { Dir.mktmpdir("lens-claims-request") }
  let(:root) { File.join(directory, "project") }
  let(:source) { "# @return [Integer]\ndef value = 1\n" }
  let(:request_path) { File.join(root, "claims.json") }
  let(:source_path) { File.join(root, "x.rb") }
  let(:data) do
    {
      "schema" => "lens-claims-request/v0", "revision" => 1, "grammar" => "rbs",
      "files" => [{ "path" => "x.rb", "digest" => Rigor::Lens.digest(source) }],
      "claims" => [{
        "id" => "value:return", "file" => "x.rb", "claim" => "Integer",
        "declaration" => { "kind" => "method", "owner" => "Object", "scope" => "instance", "name" => "value",
                           "span" => { "start_offset" => 20, "end_offset" => source.bytesize - 1 } },
        "tag" => { "name" => "return", "subject" => nil,
                   "span" => { "start_offset" => 0, "end_offset" => 19 } }
      }]
    }
  end

  before do
    Dir.mkdir(root)
    File.binwrite(source_path, source)
  end

  after { FileUtils.remove_entry(directory) }

  def read_request(document = data, arguments: ["x.rb"])
    File.binwrite(request_path, JSON.generate(document))
    described_class.read(request_path, root: root, arguments: arguments)
  end

  def target(status: "ok", reader: nil)
    Rigor::Lens::Run::Target.new(argument: "x.rb", path: "x.rb", absolute: source_path,
                                 status: status, reason: nil, reader: reader, diagnostics: [], inputs: [])
  end

  def reader_for(bytes)
    Rigor::Lens::FileReader.new(path: "x.rb", parse_result: Prism.parse(bytes), index: {}.compare_by_identity,
                                spell: ->(type, _owner) { type.erase_to_rbs }).read
  end

  it "retains claim order and hashes the exact request bytes" do
    data["claims"] << data["claims"].first.merge("id" => "second")
    bytes = "#{JSON.pretty_generate(data)}\n"
    File.binwrite(request_path, bytes)

    request = described_class.read(request_path, root: root, arguments: ["x.rb"])

    expect(request.claims.map { |claim| claim.fetch("id") }).to eq(["value:return", "second"])
    expect(request.digest).to eq(Rigor::Lens.digest(bytes))
    expect(request.paths).to eq("x.rb" => source_path)
  end

  it "rejects an unreadable request path" do
    expect { described_class.read(request_path, root: root, arguments: ["x.rb"]) }
      .to raise_error(Rigor::Lens::Claims::IntegrityError, /cannot read claims request/)
  end

  { "invalid UTF-8" => "\xFF".b, "invalid JSON" => "{" }.each do |description, bytes|
    it "rejects #{description}" do
      File.binwrite(request_path, bytes)

      expect { described_class.read(request_path, root: root, arguments: ["x.rb"]) }
        .to raise_error(Rigor::Lens::Claims::IntegrityError)
    end
  end

  [nil, [], "request", 1, true].each do |value|
    it "rejects the non-object root #{value.inspect}" do
      expect { read_request(value) }.to raise_error(Rigor::Lens::Claims::IntegrityError, /must be an object/)
    end
  end

  { "schema" => "lens-claims-request/v1", "revision" => 2, "grammar" => "yard" }.each do |field, value|
    it "rejects unsupported #{field}" do
      data[field] = value

      expect { read_request }.to raise_error(Rigor::Lens::Claims::IntegrityError, /unsupported claims #{field}/)
    end
  end

  ["1", 1.0, true].each do |revision|
    it "rejects revision #{revision.inspect} even when coercible to one" do
      data["revision"] = revision

      expect { read_request }.to raise_error(Rigor::Lens::Claims::IntegrityError, /unsupported claims revision/)
    end
  end

  {
    [] => %w[schema revision grammar files claims],
    ["files", 0] => %w[path digest],
    ["claims", 0] => %w[id file claim declaration tag],
    ["claims", 0, "declaration"] => %w[kind owner scope name span],
    ["claims", 0, "tag"] => %w[name subject span],
    ["claims", 0, "declaration", "span"] => %w[start_offset end_offset],
    ["claims", 0, "tag", "span"] => %w[start_offset end_offset]
  }.each do |path, fields|
    fields.each do |field|
      it "rejects missing #{(path + [field]).join('.')}" do
        entry = path.empty? ? data : data.dig(*path)
        entry.delete(field)

        expect { read_request }.to raise_error(Rigor::Lens::Claims::IntegrityError)
      end
    end
  end

  %w[files claims].each do |field|
    it "rejects a non-array #{field}" do
      data[field] = {}

      expect { read_request }.to raise_error(Rigor::Lens::Claims::IntegrityError, /#{field} must be an array/)
    end
  end

  [["files", 0], ["claims", 0], ["claims", 0, "declaration"], ["claims", 0, "tag"],
   ["claims", 0, "declaration", "span"], ["claims", 0, "tag", "span"]].each do |path|
    it "rejects a non-object #{path.join('.')}" do
      data.dig(*path[0...-1])[path.last] = []

      expect { read_request }.to raise_error(Rigor::Lens::Claims::IntegrityError, /must be an object/)
    end
  end

  {
    ["files", 0] => %w[path digest],
    ["claims", 0] => %w[id file claim],
    ["claims", 0, "declaration"] => %w[kind owner scope name],
    ["claims", 0, "tag"] => %w[name]
  }.each do |path, fields|
    fields.each do |field|
      it "rejects a non-string #{(path + [field]).join('.')}" do
        data.dig(*path)[field] = 1

        expect { read_request }.to raise_error(Rigor::Lens::Claims::IntegrityError, /must be a string/)
      end
    end
  end

  it "rejects a tag subject that is neither a string nor null" do
    data["claims"].first["tag"]["subject"] = false

    expect { read_request }.to raise_error(Rigor::Lens::Claims::IntegrityError, /subject must be a string or null/)
  end

  it "accepts an empty request" do
    data["files"] = []
    data["claims"] = []

    request = read_request

    expect(request.claims).to eq([])
    expect(request.paths).to eq({})
  end

  it "rejects duplicate claim ids" do
    data["claims"] << data["claims"].first.dup

    expect { read_request }.to raise_error(Rigor::Lens::Claims::IntegrityError, /duplicate claim id/)
  end

  it "rejects duplicate file paths" do
    data["files"] << data["files"].first.dup

    expect { read_request }.to raise_error(Rigor::Lens::Claims::IntegrityError, /duplicate claims file/)
  end

  it "rejects a claim whose file is not listed" do
    data["claims"].first["file"] = "other.rb"

    expect { read_request }.to raise_error(Rigor::Lens::Claims::IntegrityError, /missing from files/)
  end

  it "rejects a listed file absent from the invocation targets" do
    expect { read_request(arguments: ["other.rb"]) }
      .to raise_error(Rigor::Lens::Claims::IntegrityError, /not a target/)
  end

  it "accepts repeated invocation targets for the same listed path" do
    expect(read_request(arguments: ["x.rb", "./x.rb", source_path]).paths).to eq("x.rb" => source_path)
  end

  it "accepts a canonical root-relative target outside the project directory" do
    outside = File.expand_path("../x.rb", root)
    File.binwrite(outside, source)
    data["files"].first["path"] = "../x.rb"
    data["claims"].first["file"] = "../x.rb"

    expect(read_request(arguments: [outside]).paths).to eq("../x.rb" => outside)
  end

  it "rejects a noncanonical root-relative spelling" do
    data["files"].first["path"] = "./x.rb"
    data["claims"].first["file"] = "./x.rb"

    expect { read_request }.to raise_error(Rigor::Lens::Claims::IntegrityError, /root-relative/)
  end

  it "rejects a malformed file digest" do
    data["files"].first["digest"] = "xxh3-64:bad"

    expect { read_request }.to raise_error(Rigor::Lens::Claims::IntegrityError, /invalid claims file digest/)
  end

  it "rejects stale readable-file bytes during preflight" do
    File.binwrite(source_path, "def value = 2\n")

    expect { read_request }.to raise_error(Rigor::Lens::Claims::IntegrityError, /stale claims digest/)
  end

  %w[declaration tag].each do |field|
    it "rejects an out-of-bounds #{field} span during preflight" do
      data["claims"].first[field]["span"]["end_offset"] = source.bytesize + 1

      expect { read_request }.to raise_error(Rigor::Lens::Claims::IntegrityError, /#{field} span outside/)
    end

    [[-1, 0], [5, 4], [0, "1"], [0, 1.0]].each do |start, finish|
      it "rejects invalid #{field} offsets #{[start, finish].inspect}" do
        data["claims"].first[field]["span"] = { "start_offset" => start, "end_offset" => finish }

        expect { read_request }.to raise_error(Rigor::Lens::Claims::IntegrityError, /invalid byte span/)
      end
    end
  end

  it "accepts an end-exclusive span at the byte boundary, including multibyte text" do
    bytes = "# 日本語\ndef value = 1\n"
    File.binwrite(source_path, bytes)
    data["files"].first["digest"] = Rigor::Lens.digest(bytes)
    data["claims"].first["declaration"]["span"] = { "start_offset" => 0, "end_offset" => bytes.bytesize }

    expect { read_request }.not_to raise_error
  end

  it "ignores unknown fields at every request level" do
    [data, data["files"].first, data["claims"].first, data["claims"].first["declaration"],
     data["claims"].first["tag"], data["claims"].first["declaration"]["span"],
     data["claims"].first["tag"]["span"]].each do |entry|
      entry["future"] = { "arbitrary" => [nil, true] }
    end

    expect(read_request.claims).to eq(data["claims"])
  end

  it "accepts an unknown tag name for a per-claim answer" do
    data["claims"].first["tag"]["name"] = "yieldreturn"

    expect(read_request.claims.first.fetch("tag").fetch("name")).to eq("yieldreturn")
  end

  it "leaves an empty claim and a missing param subject for per-claim answers" do
    data["claims"].first["claim"] = ""
    data["claims"].first["tag"]["name"] = "param"

    expect(read_request.claims).to eq(data["claims"])
  end

  describe "source verification after analysis" do
    it "accepts unchanged bytes and the matching analysis reader" do
      request = read_request

      expect { request.verify_sources!([target(reader: reader_for(source))]) }.not_to raise_error
    end

    it "rejects bytes modified after preflight" do
      request = read_request
      File.binwrite(source_path, source.sub("= 1", "= 2"))

      expect { request.verify_sources!([target(reader: reader_for(source))]) }
        .to raise_error(Rigor::Lens::Claims::IntegrityError, /stale claims digest/)
    end

    it "rejects a reader of different bytes even when disk contents have been restored" do
      request = read_request
      changed_reader = reader_for(source.sub("= 1", "= 2"))

      expect { request.verify_sources!([target(reader: changed_reader)]) }
        .to raise_error(Rigor::Lens::Claims::IntegrityError, /source changed during analysis/)
    end

    it "rejects deletion of an initially readable file even without an analysis reader" do
      request = read_request
      File.unlink(source_path)

      expect { request.verify_sources!([target(status: "not_found")]) }
        .to raise_error(Rigor::Lens::Claims::IntegrityError, /source became unreadable/)
    end

    it "allows an initially missing file and unchecked spans for an unavailable target" do
      File.unlink(source_path)
      data["claims"].first["tag"]["span"]["end_offset"] = 10_000
      request = read_request

      expect(request.paths).to eq("x.rb" => source_path)
      expect { request.verify_sources!([target(status: "not_found")]) }.not_to raise_error
    end

    it "rejects an initially missing file if analysis read it before it disappeared again" do
      File.unlink(source_path)
      request = read_request

      expect { request.verify_sources!([target(reader: reader_for(source))]) }
        .to raise_error(Rigor::Lens::Claims::IntegrityError, /source became unreadable/)
    end

    it "accepts an initially missing file that becomes readable with the requested bytes" do
      File.unlink(source_path)
      request = read_request
      File.binwrite(source_path, source)

      expect { request.verify_sources!([target(reader: reader_for(source))]) }.not_to raise_error
    end

    it "rejects an initially missing file that becomes readable with different bytes" do
      File.unlink(source_path)
      request = read_request
      File.binwrite(source_path, source.sub("= 1", "= 2"))

      expect { request.verify_sources!([target(status: "failed")]) }
        .to raise_error(Rigor::Lens::Claims::IntegrityError, /stale claims digest/)
    end

    it "checks the first target reader when later arguments name the same file" do
      request = read_request(arguments: ["x.rb", "./x.rb"])

      expect do
        request.verify_sources!([target(reader: reader_for(source.sub("= 1", "= 2"))), target(status: "duplicate")])
      end.to raise_error(Rigor::Lens::Claims::IntegrityError, /source changed during analysis/)
    end

    %w[not_ruby outside_project parse_error failed].each do |status|
      it "accepts matching readable-file bytes for #{status} targets" do
        request = read_request

        expect { request.verify_sources!([target(status: status)]) }.not_to raise_error
      end

      it "checks readable-file digests even for #{status} targets" do
        request = read_request
        File.binwrite(source_path, source.sub("= 1", "= 2"))

        expect { request.verify_sources!([target(status: status)]) }
          .to raise_error(Rigor::Lens::Claims::IntegrityError, /stale claims digest/)
      end

      %w[declaration tag].each do |field|
        it "checks #{field} bounds when an initially missing #{status} target becomes readable" do
          File.unlink(source_path)
          data["claims"].first[field]["span"]["end_offset"] = source.bytesize + 1
          request = read_request
          File.binwrite(source_path, source)

          expect { request.verify_sources!([target(status: status)]) }
            .to raise_error(Rigor::Lens::Claims::IntegrityError, /#{field} span outside/)
        end
      end
    end
  end
end
