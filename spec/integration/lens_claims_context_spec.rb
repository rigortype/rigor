# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "rigor/lens"

RSpec.describe "rigor lens claim source contexts" do
  let(:executable) { File.expand_path("../../exe/rigor", __dir__) }
  let(:source) do
    <<~RUBY
      module Shadow
        class String; end
      end
      module Outer
        class String; end
        class Probe
          def original = String.new
          alias copied original
        end
      end
      class Outer::Probe
        alias chained copied
      end
      module Other
        class ::Outer::Probe
          alias reopened chained
        end
      end
      class API
        def self.direct = String.new
        class << self
          include Shadow
          def singleton = String.new
        end
      end
      class Unbound
        alias copied inherited
      end
    RUBY
  end
  let(:signature) do
    <<~RBS
      module Outer
        class Probe
          def original: () -> ::String
          alias copied original
          alias chained copied
          alias reopened chained
        end
      end
      class API
        def self.direct: () -> ::String
        def self.singleton: () -> ::String
      end
      class Unbound
        def inherited: () -> ::String
        alias copied inherited
      end
    RBS
  end

  def invoke(*options)
    Open3.capture3(RbConfig.ruby, executable, "lens", "--format=json", "--workers=0", *options, "lib/probe.rb")
  end

  around do |example|
    Dir.mktmpdir do |directory|
      Dir.chdir(directory) do
        FileUtils.mkdir_p(%w[lib sig])
        File.write("lib/probe.rb", source)
        File.write("sig/probe.rbs", signature)
        File.write("rigor.yml", "paths: [lib]\nsignature_paths: [sig]\nplugins: []\n")
        example.run
      end
    end
  end

  def request_for(ordinary)
    sites = ordinary.fetch("files").first.fetch("sites").select { |site| site["kind"] == "method" }
    claims = sites.flat_map do |site|
      %w[String ::String].map do |type|
        { "id" => "#{site.fetch('owner')}.#{site.fetch('name')}:#{type}", "file" => "lib/probe.rb",
          "declaration" => site.slice("kind", "owner", "scope", "name", "span"),
          "tag" => { "name" => "return", "subject" => nil, "span" => { "start_offset" => 0, "end_offset" => 0 } },
          "claim" => type }
      end
    end
    { "schema" => "lens-claims-request/v0", "revision" => 1, "grammar" => "rbs",
      "files" => [{ "path" => "lib/probe.rb", "digest" => Rigor::Lens.digest(source.b) }], "claims" => claims }
  end

  def documents
    out, err, status = invoke
    expect(status.exitstatus).to eq(0), err
    ordinary = JSON.parse(out)
    File.write("request.json", JSON.generate(request_for(ordinary)))
    out, err, status = invoke("--claims=request.json")
    expect(status.exitstatus).to eq(0), err
    [ordinary, JSON.parse(out)]
  end

  it "keeps the original lexical namespace through aliases, chains and differently nested reopens" do
    _, checked = documents
    rows = checked.fetch("claims").fetch("results").to_h { |row| [row.fetch("id"), row] }
    %w[original copied chained reopened].each do |name|
      expect(rows.fetch("Outer::Probe.#{name}:String")).to include("verdict" => "unknown", "reason" => "ambiguous_name")
      expect(rows.fetch("Outer::Probe.#{name}:::String")).to include("verdict" => "compatible")
    end
    expect(rows.fetch("Unbound.copied:String")).to include("verdict" => "unknown", "reason" => "ambiguous_name")
    expect(rows.fetch("Unbound.copied:::String")).to include("verdict" => "compatible")
  end

  it "distinguishes singleton-class nesting from a singleton def and preserves absolute-name controls" do
    _, checked = documents
    rows = checked.fetch("claims").fetch("results").to_h { |row| [row.fetch("id"), row] }
    expect(rows.fetch("API.singleton:String")).to include("verdict" => "unknown", "reason" => "ambiguous_name")
    expect(rows.fetch("API.singleton:::String")).to include("verdict" => "compatible")
    expect(rows.fetch("API.direct:String")).to include("verdict" => "compatible")
    expect(rows.fetch("API.direct:::String")).to include("verdict" => "compatible")
  end

  it "leaves all ordinary lens fields unchanged" do
    ordinary, checked = documents
    expect(checked.merge("claims" => nil)).to eq(ordinary)
  end
end
