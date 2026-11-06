# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "rigor/lens"

# A `Struct.new` / `Data.define` block is `class_eval`ed on the new class, so its defs belong to that class,
# but their constants resolve in the lexical scope that wrote the block (`Module.nesting` does not include the
# new class). A relative claim name must be read there, through aliases, chains and reopens alike.
RSpec.describe "rigor lens claim contexts in builder blocks" do
  let(:executable) { File.expand_path("../../exe/rigor", __dir__) }
  let(:source) do
    <<~RUBY
      module Outer
        class String; end
        Built = Struct.new(:x) do
          def original = String.new
          def self.build = String.new
          alias copied original
          alias_method :chained, :copied
        end
        Datum = Data.define(:x) do
          def original = String.new
          alias copied original
        end
      end
      class Outer::Built
        class String; end
        alias reopened chained
      end
      class Outer::Datum
        class String; end
        alias reopened copied
      end
      Top = Struct.new(:x) do
        def plain = String.new
      end
    RUBY
  end
  let(:signature) do
    <<~RBS
      module Outer
        class Built < Struct[untyped]
          class String
          end
          def original: () -> ::Outer::Built::String
          def self.build: () -> ::Outer::Built::String
          alias copied original
          alias chained copied
          alias reopened chained
        end
        class Datum < Data
          class String
          end
          def original: () -> ::Outer::Datum::String
          alias copied original
          alias reopened copied
        end
      end
      class Top < Struct[untyped]
        def plain: () -> ::String
      end
    RBS
  end
  let(:builder_methods) do
    { "Outer::Built" => %w[original build copied chained reopened], "Outer::Datum" => %w[original copied reopened] }
  end

  def invoke(*options)
    Open3.capture3(RbConfig.ruby, executable, "lens", "--format=json", "--workers=0", *options, "lib/probe.rb",
                   stdin_data: "")
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

  def claims_for(site)
    absolute = site.fetch("owner") == "Top" ? "::String" : "::#{site.fetch('owner')}::String"
    ["String", absolute].map do |type|
      { "id" => "#{site.fetch('owner')}.#{site.fetch('name')}:#{type}", "file" => "lib/probe.rb",
        "declaration" => site.slice("kind", "owner", "scope", "name", "span"),
        "tag" => { "name" => "return", "subject" => nil, "span" => { "start_offset" => 0, "end_offset" => 0 } },
        "claim" => type }
    end
  end

  def documents
    out, err, status = invoke
    expect(status.exitstatus).to eq(0), err
    ordinary = JSON.parse(out)
    sites = ordinary.fetch("files").first.fetch("sites").select { |site| site["kind"] == "method" }
    request = { "schema" => "lens-claims-request/v0", "revision" => 1, "grammar" => "rbs",
                "files" => [{ "path" => "lib/probe.rb", "digest" => Rigor::Lens.digest(source.b) }],
                "claims" => sites.flat_map { |site| claims_for(site) } }
    File.write("request.json", JSON.generate(request))
    out, err, status = invoke("--claims=request.json")
    expect(status.exitstatus).to eq(0), err
    [ordinary, JSON.parse(out)]
  end

  def rows
    _, checked = documents
    checked.fetch("claims").fetch("results").to_h { |row| [row.fetch("id"), row] }
  end

  it "reads a relative name in the block's lexical scope, not the builder class, for defs and their aliases" do
    results = rows
    builder_methods.each do |owner, names|
      names.each do |name|
        expect(results.fetch("#{owner}.#{name}:String")).to include("verdict" => "unknown", "reason" => "ambiguous_name")
        expect(results.fetch("#{owner}.#{name}:::#{owner}::String")).to include("verdict" => "compatible")
      end
    end
  end

  it "keeps a builder-block relative name comparable when both readings agree" do
    results = rows
    expect(results.fetch("Top.plain:String")).to include("verdict" => "compatible")
    expect(results.fetch("Top.plain:::String")).to include("verdict" => "compatible")
  end

  it "matches Ruby's own constant resolution for the builder bodies" do
    script = "puts [Outer::Built.new.original, Outer::Built.build, Outer::Built.new.copied, " \
             "Outer::Built.new.reopened, Outer::Datum.new(x: 1).original, Outer::Datum.new(x: 1).reopened]" \
             ".map { |value| value.class.name }.uniq"
    out, err, status = Open3.capture3(RbConfig.ruby, "-r./lib/probe", "-e", script, stdin_data: "")
    expect(status.exitstatus).to eq(0), err
    expect(out.split).to eq(["Outer::String"])
  end

  it "leaves all ordinary lens fields unchanged" do
    ordinary, checked = documents
    expect(checked.merge("claims" => nil)).to eq(ordinary)
  end
end
