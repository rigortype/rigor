# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "rigor/cli/check_command"

# #1956 — `rigor check` globbed each `paths:` directory as `"<dir>/**/*.rb"`, so the directory's own characters
# were read as glob syntax: a project at `ds [x]` or `ds{a}` analysed nothing, `ds*` analysed its siblings,
# `fx[1]` analysed `fx1`, and a `paths:` directory named `{..,zz}` walked its parent.
RSpec.describe "rigor check under a project path with glob metacharacters (#1956)" do
  let(:parent) { File.realpath(Dir.mktmpdir("rigor-glob-path-")) }

  after { FileUtils.rm_rf(parent) }

  def project(name, paths: "lib", files: { "lib/a.rb" => "\"a\".no_such_method_here\n" })
    dir = File.join(parent, name)
    files.each do |relative, source|
      FileUtils.mkdir_p(File.dirname(File.join(dir, relative)))
      File.write(File.join(dir, relative), source)
    end
    File.write(File.join(dir, ".rigor.yml"), "paths:\n  - #{paths.inspect}\n")
    dir
  end

  # The analysed paths and rules, relative to `dir`; a path outside it keeps its `../` spelling.
  def check(dir, *flags)
    out = StringIO.new
    argv = ["--no-ci-detect", "--no-stats", "--no-baseline", "--format", "json", *flags]
    Dir.chdir(dir) { Rigor::CLI::CheckCommand.new(argv: argv, out: out, err: StringIO.new).run }
    JSON.parse(out.string).fetch("diagnostics").map do |diagnostic|
      path = Pathname.new(File.expand_path(diagnostic.fetch("path"), dir)).relative_path_from(dir).to_s
      "#{path} #{diagnostic.fetch('rule')}"
    end
  end

  it "analyses a metacharacter project path the same as a plain one" do
    expected = check(project("plain"), "--no-cache")
    expect(expected).to eq(["lib/a.rb call.undefined-method"])

    ["ds [x]", "ds{a}", "ds*", "ds?q", "fx[1]"].each do |name|
      expect(check(project(name), "--no-cache")).to eq(expected), name
    end
  end

  it "does not analyse a sibling `fx1` for a project at `fx[1]`" do
    project("fx1", files: { "lib/b.rb" => "\"b\".sibling_method\n" })

    expect(check(project("fx[1]"), "--no-cache")).to eq(["lib/a.rb call.undefined-method"])
  end

  it "keeps a `paths:` directory named `{..,zz}` inside the project" do
    project("other", files: { "lib/b.rb" => "\"b\".outside_method\n" })
    dir = project("proj", paths: "{..,zz}", files: { "{..,zz}/a.rb" => "\"a\".inside_method\n" })

    expect(check(dir, "--no-cache")).to eq(["{..,zz}/a.rb call.undefined-method"])
  end

  it "answers a warm run like a cold one after a file is added and removed" do
    dir = project("ds [x]{a}")
    2.times { check(dir) }
    File.write(File.join(dir, "lib", "new.rb"), "\"n\".another_missing_method\n")
    expect(check(dir)).to eq(check(dir, "--no-cache"))
    expect(check(dir)).to include("lib/new.rb call.undefined-method")

    File.delete(File.join(dir, "lib", "new.rb"))
    expect(check(dir)).to eq(check(dir, "--no-cache"))
  end
end
