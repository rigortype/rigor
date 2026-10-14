# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

# Issue #1576 — a relative `exclude:` pattern is matched against the path relative to the config file's directory
# and never sees a directory above it; an absolute pattern is matched against the absolute path.
RSpec.describe "exclude: pattern base (#1576)" do
  let(:tmp) { File.realpath(Dir.mktmpdir("rigor-exclude-base-")) }

  after { FileUtils.remove_entry(tmp) }

  def project(dir, yaml, extra: {})
    FileUtils.mkdir_p(File.join(dir, "lib"))
    File.write(File.join(dir, ".rigor.yml"), yaml)
    File.write(File.join(dir, "lib/ok.rb"), "y = nil\ny.upcase\n")
    extra.each do |rel, body|
      FileUtils.mkdir_p(File.dirname(File.join(dir, rel)))
      File.write(File.join(dir, rel), body)
    end
  end

  def reported(config: nil, paths: nil)
    configuration = Rigor::Configuration.load(config)
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    guarded_run(runner, paths).diagnostics.map { |d| d.path.to_s.delete_prefix("#{Dir.pwd}/") }.uniq.sort
  end

  %w[tmp node_modules].each do |above|
    it "still analyses a project placed under a `#{above}` directory (unanchored user pattern)" do
      dir = File.join(tmp, above, "proj")
      project(dir, "paths:\n  - lib\nexclude:\n  - \"**/#{above}/**\"\n")
      Dir.chdir(dir) do
        expect(reported).to include(a_string_ending_with("lib/ok.rb"))
        expect(reported(paths: %w[lib])).to include(a_string_ending_with("lib/ok.rb"))
      end
    end
  end

  it "still analyses a project placed under vendor/bundle (built-in pattern)" do
    dir = File.join(tmp, "vendor/bundle/proj")
    project(dir, "paths:\n  - lib\n")
    Dir.chdir(dir) do
      expect(reported).to include(a_string_ending_with("lib/ok.rb"))
      expect(reported(paths: %w[lib])).to include(a_string_ending_with("lib/ok.rb"))
    end
  end

  it "matches `**/tmp/**` against a top-level tmp/ directory under the base" do
    project(tmp, "paths:\n  - lib\n  - tmp\nexclude:\n  - \"**/tmp/**\"\n",
            extra: { "tmp/x.rb" => "z = nil\nz.upcase\n" })
    Dir.chdir(tmp) do
      expect(reported.grep(/tmp/)).to be_empty
      expect(reported).to include(a_string_ending_with("lib/ok.rb"))
    end
  end

  it "resolves relative patterns against the --config file's directory" do
    project(File.join(tmp, "sub"), "paths:\n  - lib\nexclude:\n  - \"lib/gen/**\"\n",
            extra: { "lib/gen/x.rb" => "z = nil\nz.upcase\n" })
    Dir.chdir(tmp) do
      rows = reported(config: "sub/.rigor.yml")
      expect(rows).to include(a_string_ending_with("sub/lib/ok.rb"))
      expect(rows).not_to include(a_string_ending_with("gen/x.rb"))
    end
  end

  it "keeps matching when the working directory is reached through a symlink" do
    project(File.join(tmp, "real"), "paths:\n  - lib\nexclude:\n  - \"lib/gen/**\"\n",
            extra: { "lib/gen/x.rb" => "z = nil\nz.upcase\n" })
    File.symlink(File.join(tmp, "real"), File.join(tmp, "link"))
    Dir.chdir(File.join(tmp, "link")) do
      expect(reported).to include(a_string_ending_with("lib/ok.rb"))
      expect(reported).not_to include(a_string_ending_with("gen/x.rb"))
      expect(reported(paths: %w[lib])).not_to include(a_string_ending_with("gen/x.rb"))
    end
  end

  it "matches through a symlinked --config directory" do
    project(File.join(tmp, "real"), "paths:\n  - lib\nexclude:\n  - \"lib/gen/**\"\n",
            extra: { "lib/gen/x.rb" => "z = nil\nz.upcase\n" })
    File.symlink(File.join(tmp, "real"), File.join(tmp, "link"))
    Dir.chdir(tmp) do
      rows = reported(config: "link/.rigor.yml")
      expect(rows).to include(a_string_ending_with("lib/ok.rb"))
      expect(rows).not_to include(a_string_ending_with("gen/x.rb"))
    end
  end

  it "excludes a file through a physical path when the base is spelled through a symlink" do
    project(File.join(tmp, "real"), "paths:\n  - lib\nexclude:\n  - \"lib/gen/**\"\n",
            extra: { "lib/gen/x.rb" => "z = nil\nz.upcase\n" })
    File.symlink(File.join(tmp, "real"), File.join(tmp, "link"))
    Dir.chdir(tmp) do
      rows = reported(config: "link/.rigor.yml", paths: [File.join(tmp, "real/lib")])
      expect(rows).to include(a_string_ending_with("lib/ok.rb"))
      expect(rows).not_to include(a_string_ending_with("gen/x.rb"))
    end
  end

  it "excludes through a symlinked lib for both `rigor check` and `rigor check lib`" do
    FileUtils.mkdir_p(File.join(tmp, "shared/lib/gen"))
    File.write(File.join(tmp, "shared/lib/ok.rb"), "y = nil\ny.upcase\n")
    File.write(File.join(tmp, "shared/lib/gen/x.rb"), "z = nil\nz.upcase\n")
    FileUtils.mkdir_p(File.join(tmp, "proj"))
    File.write(File.join(tmp, "proj/.rigor.yml"), "paths:\n  - lib\nexclude:\n  - \"lib/gen/**\"\n")
    File.symlink(File.join(tmp, "shared/lib"), File.join(tmp, "proj/lib"))
    Dir.chdir(File.join(tmp, "proj")) do
      [nil, %w[lib]].each do |paths|
        rows = reported(paths: paths)
        expect(rows).to include(a_string_ending_with("lib/ok.rb"))
        expect(rows).not_to include(a_string_ending_with("gen/x.rb"))
      end
    end
  end

  context "with a sibling project at ../shared" do
    before do
      project(File.join(tmp, "proj"), "paths:\n  - lib\nexclude:\n  - \"lib/gen/**\"\n")
      FileUtils.mkdir_p(File.join(tmp, "shared/lib/gen"))
      File.write(File.join(tmp, "shared/lib/ok.rb"), "y = nil\ny.upcase\n")
      File.write(File.join(tmp, "shared/lib/gen/x.rb"), "z = nil\nz.upcase\n")
    end

    it "does not apply the project's `lib/gen/**` to `rigor check ../shared`" do
      Dir.chdir(File.join(tmp, "proj")) do
        expect(reported(paths: %w[../shared])).to include(a_string_ending_with("shared/lib/gen/x.rb"))
      end
    end

    it "applies `../shared/lib/gen/**` to a sibling directory that paths: names" do
      File.write(File.join(tmp, "proj/.rigor.yml"),
                 "paths:\n  - lib\n  - ../shared/lib\nexclude:\n  - \"../shared/lib/gen/**\"\n")
      Dir.chdir(File.join(tmp, "proj")) do
        rows = reported
        expect(rows).to include(a_string_ending_with("shared/lib/ok.rb"))
        expect(rows).not_to include(a_string_ending_with("gen/x.rb"))
      end
    end

    it "still applies the built-in vendor/bundle pattern to `rigor check ../shared`" do
      FileUtils.mkdir_p(File.join(tmp, "shared/vendor/bundle"))
      File.write(File.join(tmp, "shared/vendor/bundle/v.rb"), "q = nil\nq.upcase\n")
      Dir.chdir(File.join(tmp, "proj")) do
        rows = reported(paths: %w[../shared])
        expect(rows).to include(a_string_ending_with("shared/lib/ok.rb"))
        expect(rows).not_to include(a_string_ending_with("bundle/v.rb"))
      end
    end
  end

  it "ignores a leading ./ in a relative pattern" do
    project(tmp, "paths:\n  - lib\nexclude:\n  - \"./lib/gen/**\"\n",
            extra: { "lib/gen/x.rb" => "z = nil\nz.upcase\n" })
    Dir.chdir(tmp) do
      expect(reported).not_to include(a_string_ending_with("gen/x.rb"))
      expect(reported(paths: %w[lib])).not_to include(a_string_ending_with("gen/x.rb"))
    end
  end

  it "keeps an absolute pattern working" do
    project(tmp, "paths:\n  - lib\nexclude:\n  - \"#{tmp}/lib/gen/**\"\n",
            extra: { "lib/gen/x.rb" => "z = nil\nz.upcase\n" })
    Dir.chdir(tmp) do
      expect(reported).not_to include(a_string_ending_with("gen/x.rb"))
      expect(reported(paths: %w[lib])).not_to include(a_string_ending_with("gen/x.rb"))
    end
  end
end
