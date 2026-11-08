# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"
require "fileutils"

# #2971 — a collection-installed gem named under `libraries:` must keep its collection signatures and must not be
# reported by the library audit. Each example runs `rigor check` as a subprocess, as library_audit_subprocess_spec does.
RSpec.describe "collection gem listed in libraries: (subprocess)" do
  let(:exe) { File.join(File.expand_path("../../..", __dir__), "exe", "rigor") }

  around do |example|
    Dir.mktmpdir("rigor-collection-libs-spec-") do |dir|
      @dir = dir
      FileUtils.mkdir_p(File.join(dir, "lib"))
      FileUtils.mkdir_p(File.join(dir, ".gem_rbs_collection", "foogem", "1.0"))
      File.write(File.join(dir, ".gem_rbs_collection", "foogem", "1.0", "foogem.rbs"),
                 "class Foo\n  def bar: () -> Integer\nend\n")
      File.write(File.join(dir, "rbs_collection.lock.yaml"),
                 "---\npath: .gem_rbs_collection\ngems:\n- name: foogem\n  version: '1.0'\n  source:\n    type: git\n")
      File.write(File.join(dir, "lib", "a.rb"), "Foo.new.bar.no_such\n")
      example.run
    end
  end

  attr_reader :dir

  def check_run(libraries)
    File.write(File.join(dir, ".rigor.yml"), "severity_profile: balanced\nlibraries: #{libraries}\n")
    out, err, = Open3.capture3("bundle", "exec", "ruby", exe, "check", "--no-ci-detect", "--no-stats",
                               "--no-baseline", "lib", chdir: dir, stdin_data: "")
    "#{out}#{err}"
  end

  it "keeps the collection signatures when the gem is listed" do
    output = check_run("[foogem]")

    expect(output).to include("no_such").and include("Integer")
  end

  it "does not audit-warn about the collection-provided name" do
    expect(check_run("[foogem]")).not_to include("is not an available RBS library")
  end

  it "still warns about a truly unknown name" do
    output = check_run("[foogem, no_such_lib]")

    expect(output).to include("no_such_lib").and include("is not an available RBS library")
    expect(output).not_to include("\"foogem\" is not")
  end

  it "behaves as before with libraries: []" do
    output = check_run("[]")

    expect(output).to include("no_such")
    expect(output).not_to include("is not an available RBS library")
  end
end
