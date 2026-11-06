# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "rigor/lens"

# Relative claim names whose two readings cannot be shown to agree stay unknown instead of proving a verdict.
RSpec.describe "rigor lens claim name guards" do
  let(:executable) { File.expand_path("../../exe/rigor", __dir__) }
  let(:builder_alias_source) { <<~RUBY }
    module Outer
      Built = Struct.new(:x) do
        def m = 1
        alias copied m
      end
    end
    class Outer::Built
      alias reopened copied
    end
  RUBY
  let(:builder_alias_signature) { <<~RBS }
    type id = ::String
    module Outer
      class Built < Struct[untyped]
        type id = ::Integer
        def m: () -> id
        alias copied m
        alias reopened copied
      end
    end
  RBS
  let(:unlocated_source) { <<~RUBY }
    class Outer
      def original = 1
      def original = 2
      alias copied original
    end
  RUBY
  let(:unlocated_signature) { <<~RBS }
    type t = ::String
    class Outer
      type t = ::Integer
      def original: () -> ::Integer
      alias copied original
    end
  RBS
  let(:opaque_source) { <<~RUBY }
    class Base
      class Helper; end
    end
    class Helper; end
    def pick = Base
    Made = Class.new(Base)
    class Made
      def m = Helper.new
    end
    class Picked < pick
      def m = Helper.new
    end
    Alias = Base
    class ViaAlias < Alias
      def m = Helper.new
    end
    class Plain
      def m = Helper.new
    end
  RUBY
  let(:opaque_signature) { <<~RBS }
    class Base
      class Helper
      end
    end
    class Helper
    end
    class Made < Base
      def m: () -> ::Helper
    end
    class Picked < Base
      def m: () -> ::Helper
    end
    class ViaAlias < Base
      def m: () -> ::Helper
    end
    class Plain
      def m: () -> ::Helper
    end
  RBS

  def unknown = { "verdict" => "unknown", "reason" => "ambiguous_name" }
  def compatible = { "verdict" => "compatible", "reason" => "proven_inclusion" }

  def invoke(*options)
    Open3.capture3(RbConfig.ruby, executable, "lens", "--format=json", "--workers=0", *options, "lib/probe.rb",
                   stdin_data: "")
  end

  def lens(*options)
    out, err, status = invoke(*options)
    expect(status.exitstatus).to eq(0), err
    JSON.parse(out)
  end

  def claim(site, text)
    { "id" => "#{site.fetch('owner')}##{site.fetch('name')}:#{text}", "file" => "lib/probe.rb",
      "declaration" => site.slice("kind", "owner", "scope", "name", "span"),
      "tag" => { "name" => "return", "subject" => nil, "span" => { "start_offset" => 0, "end_offset" => 0 } },
      "claim" => text }
  end

  # `claims` maps a claim text to the methods (`Owner#name`) it is checked on, as return claims.
  def request(ordinary, source, claims)
    sites = ordinary.fetch("files").first.fetch("sites").select { |site| site["kind"] == "method" }
    requested = claims.flat_map do |text, methods|
      methods.map { |method| claim(sites.find { |site| "#{site['owner']}##{site['name']}" == method }, text) }
    end
    { "schema" => "lens-claims-request/v0", "revision" => 1, "grammar" => "rbs",
      "files" => [{ "path" => "lib/probe.rb", "digest" => Rigor::Lens.digest(source.b) }], "claims" => requested }
  end

  def results(source, signature, claims)
    Dir.mktmpdir do |directory|
      Dir.chdir(directory) do
        FileUtils.mkdir_p(%w[lib sig])
        File.write("lib/probe.rb", source)
        File.write("sig/probe.rbs", signature)
        File.write("rigor.yml", "paths: [lib]\nsignature_paths: [sig]\nplugins: []\n")
        ordinary = lens
        File.write("request.json", JSON.generate(request(ordinary, source, claims)))
        checked = lens("--claims=request.json")
        expect(checked.merge("claims" => nil)).to eq(ordinary)
        checked.fetch("claims").fetch("results").to_h { |row| [row.fetch("id"), row.slice("verdict", "reason")] }
      end
    end
  end

  it "declines a relative type alias the builder block's scope and the builder class resolve differently" do
    methods = %w[Outer::Built#m Outer::Built#copied Outer::Built#reopened]
    rows = results(builder_alias_source, builder_alias_signature, "id" => methods, "::Outer::Built::id" => methods)
    methods.each do |method|
      expect(rows.fetch("#{method}:id")).to eq(unknown)
      expect(rows.fetch("#{method}:::Outer::Built::id")).to eq(compatible)
    end
  end

  it "declines a relative type alias on an alias whose original body cannot be located" do
    rows = results(unlocated_source, unlocated_signature, "t" => %w[Outer#copied], "::Outer::t" => %w[Outer#copied])
    expect(rows.fetch("Outer#copied:t")).to eq(unknown)
    expect(rows.fetch("Outer#copied:::Outer::t")).to eq(compatible)
  end

  it "declines a relative class name when an ancestor's superclass is not one the tables name" do
    methods = %w[Made#m Picked#m ViaAlias#m]
    rows = results(opaque_source, opaque_signature, "Helper" => methods + %w[Plain#m], "::Helper" => methods)
    methods.each do |method|
      expect(rows.fetch("#{method}:Helper")).to eq(unknown)
      expect(rows.fetch("#{method}:::Helper")).to eq(compatible)
    end
    expect(rows.fetch("Plain#m:Helper")).to eq(compatible)
  end

  it "matches Ruby, which reads those names through the unnamed superclass" do
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "probe.rb"), opaque_source)
      script = "puts [Made.new.m, ViaAlias.new.m].map { |value| value.class.name }"
      out, err, status = Open3.capture3(RbConfig.ruby, "-r#{directory}/probe", "-e", script, stdin_data: "")
      expect(status.exitstatus).to eq(0), err
      expect(out.split).to eq(%w[Base::Helper Base::Helper])
    end
  end
end
