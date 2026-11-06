# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "rigor/lens"

# Relative claim names whose two readings cannot be shown to agree stay unknown instead of proving a verdict.
RSpec.describe "rigor lens claim name guards" do
  let(:executable) { File.expand_path("../../exe/rigor", __dir__) }

  def invoke(*options)
    Open3.capture3(RbConfig.ruby, executable, "lens", "--format=json", "--workers=0", *options, "lib/probe.rb",
                   stdin_data: "")
  end

  # `claims` maps a claim text to the methods (`Owner#name`) it is checked on, as return claims.
  def results(source, signature, claims)
    Dir.mktmpdir do |directory|
      Dir.chdir(directory) do
        FileUtils.mkdir_p(%w[lib sig])
        File.write("lib/probe.rb", source)
        File.write("sig/probe.rbs", signature)
        File.write("rigor.yml", "paths: [lib]\nsignature_paths: [sig]\nplugins: []\n")
        out, err, status = invoke
        expect(status.exitstatus).to eq(0), err
        ordinary = JSON.parse(out)
        sites = ordinary.fetch("files").first.fetch("sites").select { |site| site["kind"] == "method" }
        requested = claims.flat_map do |text, methods|
          methods.map do |method|
            site = sites.find { |entry| "#{entry.fetch('owner')}##{entry.fetch('name')}" == method }
            { "id" => "#{method}:#{text}", "file" => "lib/probe.rb",
              "declaration" => site.slice("kind", "owner", "scope", "name", "span"),
              "tag" => { "name" => "return", "subject" => nil, "span" => { "start_offset" => 0, "end_offset" => 0 } },
              "claim" => text }
          end
        end
        request = { "schema" => "lens-claims-request/v0", "revision" => 1, "grammar" => "rbs",
                    "files" => [{ "path" => "lib/probe.rb", "digest" => Rigor::Lens.digest(source.b) }],
                    "claims" => requested }
        File.write("request.json", JSON.generate(request))
        out, err, status = invoke("--claims=request.json")
        expect(status.exitstatus).to eq(0), err
        checked = JSON.parse(out)
        expect(checked.merge("claims" => nil)).to eq(ordinary)
        checked.fetch("claims").fetch("results").to_h { |row| [row.fetch("id"), row.slice("verdict", "reason")] }
      end
    end
  end

  it "declines a relative type alias the builder block's scope and the builder class resolve differently" do
    source = <<~RUBY
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
    signature = <<~RBS
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
    methods = %w[Outer::Built#m Outer::Built#copied Outer::Built#reopened]
    rows = results(source, signature, "id" => methods, "::Outer::Built::id" => methods)
    methods.each do |method|
      expect(rows.fetch("#{method}:id")).to eq("verdict" => "unknown", "reason" => "ambiguous_name")
      expect(rows.fetch("#{method}:::Outer::Built::id")).to eq("verdict" => "compatible", "reason" => "proven_inclusion")
    end
  end

  it "declines a relative type alias on an alias whose original body cannot be located" do
    source = <<~RUBY
      class Outer
        def original = 1
        def original = 2
        alias copied original
      end
    RUBY
    signature = <<~RBS
      type t = ::String
      class Outer
        type t = ::Integer
        def original: () -> ::Integer
        alias copied original
      end
    RBS
    rows = results(source, signature, "t" => %w[Outer#copied], "::Outer::t" => %w[Outer#copied])
    expect(rows.fetch("Outer#copied:t")).to eq("verdict" => "unknown", "reason" => "ambiguous_name")
    expect(rows.fetch("Outer#copied:::Outer::t")).to eq("verdict" => "compatible", "reason" => "proven_inclusion")
  end

  it "declines a relative class name when an ancestor's superclass is not one the tables name" do
    source = <<~RUBY
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
    signature = <<~RBS
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
    methods = %w[Made#m Picked#m ViaAlias#m]
    rows = results(source, signature, "Helper" => methods + %w[Plain#m], "::Helper" => methods)
    methods.each do |method|
      expect(rows.fetch("#{method}:Helper")).to eq("verdict" => "unknown", "reason" => "ambiguous_name")
      expect(rows.fetch("#{method}:::Helper")).to eq("verdict" => "compatible", "reason" => "proven_inclusion")
    end
    expect(rows.fetch("Plain#m:Helper")).to eq("verdict" => "compatible", "reason" => "proven_inclusion")
  end

  it "matches Ruby, which reads those names through the unnamed superclass" do
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "probe.rb"), <<~RUBY)
        class Base; class Helper; end; end
        class Helper; end
        Made = Class.new(Base)
        class Made; def m = Helper.new; end
        Alias = Base
        class ViaAlias < Alias; def m = Helper.new; end
      RUBY
      out, err, status = Open3.capture3(RbConfig.ruby, "-r#{directory}/probe", "-e",
                                        "puts [Made.new.m, ViaAlias.new.m].map { |value| value.class.name }",
                                        stdin_data: "")
      expect(status.exitstatus).to eq(0), err
      expect(out.split).to eq(%w[Base::Helper Base::Helper])
    end
  end
end
