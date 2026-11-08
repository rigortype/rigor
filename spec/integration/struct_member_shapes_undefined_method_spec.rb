# frozen_string_literal: true

# Issue #2968 — a Struct with splatted members (`Struct.new(*F)`) or a leading class-name String
# (`Struct.new("Named", :a)`) was not read as a class at constant-write position: the constant typed as a `Struct`
# instance, so `P.new(1)` reported `undefined method 'new' for Struct`. Each row runs the calls in the defining file
# and in another file. Every row's Ruby behaviour was witnessed on Ruby 4.0.5.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "Struct and Data member shapes and call.undefined-method (#2968)" do
  def write_project(source, calls, in_file:)
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "types.rbs"), source.include?("class Q") ? "class Q\nend\n" : "")
    body = "def run\n#{calls.map { |c| "  #{c}" }.join("\n")}\nend\n"
    if in_file
      File.write(File.join("lib", "defs.rb"), "#{source}#{body}")
    else
      File.write(File.join("lib", "defs.rb"), source)
      File.write(File.join("lib", "caller.rb"), body)
    end
  end

  def undefined_messages
    settings = { "paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0 }
    configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge(settings))
    result = guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
    result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message).sort
  end

  around do |example|
    Dir.mktmpdir("rigor-struct-member-shapes-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:splat) do
    <<~RUBY
      F = %i[sp_url]
      P = Struct.new(*F) do
        def go = sp_url
      end
      PK = Struct.new(*F, keyword_init: true)
      module A
        class B
          PN = Struct.new(*F)
        end
      end
      DS = Data.define(*F)
    RUBY
  end
  let(:splat_calls) { ["P.new(1).sp_url", "PK.new(sp_url: 1).sp_url", "A::B::PN.new(1).sp_url", "DS.new(sp_url: 1).sp_url"] }

  let(:named) do
    <<~RUBY
      N = Struct.new("Named", :n_url) do
        def go = n_url
      end
      NK = Struct.new("NamedK", :k_url, keyword_init: true)
      module Outer
        NN = Struct.new("Named3", :o_url)
      end
    RUBY
  end
  let(:named_calls) { ["N.new(1).n_url", "NK.new(k_url: 1).k_url", "Outer::NN.new(1).o_url"] }

  [true, false].each do |in_file|
    where = in_file ? "in the defining file" : "from another file"

    it "reads a splatted member list as a class, keyword_init: and nested included, #{where}" do
      write_project(splat, splat_calls, in_file: in_file)
      expect(undefined_messages).to be_empty
    end

    it "reads a Struct.new with a leading class-name String as a class, #{where}" do
      write_project(named, named_calls, in_file: in_file)
      expect(undefined_messages).to be_empty
    end
  end

  # Guard: `call.undefined-method` reports no member name on any Struct or Data class, a literal member list's
  # included (`L.new(1).zz` is quiet on master too), so this file has no reporting row on a struct; the reporting
  # rows for #2968 are `unknown-helper`'s in `rails_routes_plugin_spec.rb`. This row shows the project here still
  # reports an unknown name on a plain class.
  it "still reports an unknown name on a plain class beside the struct shapes" do
    write_project("#{splat}#{named}class Q\nend\n", %w[Q.new.zz P.new(1).zz N.new(1).zz], in_file: false)
    expect(undefined_messages).to eq(["undefined method `zz' for Q"])
  end
end
