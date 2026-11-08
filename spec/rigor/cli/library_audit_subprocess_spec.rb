# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"
require "fileutils"

# #2961 — the library audit runs in a fresh CLI process where `rbs` is not loaded yet. In-process specs cannot see
# that (the spec process already has RBS), so each example here runs `rigor check` as a subprocess.
RSpec.describe "library audit warnings from a fresh CLI process" do
  let(:exe) { File.join(File.expand_path("../../..", __dir__), "exe", "rigor") }

  around do |example|
    Dir.mktmpdir("rigor-library-audit-spec-") do |dir|
      @dir = dir
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "lib", "a.rb"), "class Widget\n  def price\n    10\n  end\nend\n")
      example.run
    end
  end

  attr_reader :dir

  # Returns [stdout + stderr, the environment_loader.rb path if rbs loaded it (else ""), exit status].
  def check_run(config, command: "check")
    File.write(File.join(dir, ".rigor.yml"), "severity_profile: balanced\n#{config}")
    marker = File.join(dir, "rbs_loaded.txt")
    preload = File.join(dir, "probe.rb")
    File.write(preload, <<~RUBY)
      at_exit { File.write(#{marker.inspect}, $LOADED_FEATURES.grep(%r{/gems/rbs-[^/]+/lib/rbs/environment_loader\\.rb\\z}).join(",")) }
    RUBY
    out, err, status = Open3.capture3("bundle", "exec", "ruby", "-r", preload, exe, *cli_args(command),
                                      chdir: dir, stdin_data: "")
    ["#{out}#{err}", File.read(marker), status.exitstatus]
  end

  def cli_args(command)
    command == "check" ? %w[check --no-ci-detect --no-stats --no-baseline lib] : [command]
  end

  def write_stdlib_lockfile(*names)
    gems = names.map { |name| "- name: #{name}\n  version: '0'\n  source:\n    type: stdlib\n" }.join
    File.write(File.join(dir, "rbs_collection.lock.yaml"), "---\npath: .gem_rbs_collection\ngems:\n#{gems}")
  end

  it "warns about an unknown libraries: entry" do
    output, = check_run("libraries: [no_such_lib]\n")

    expect(output).to include("no_such_lib").and include("is not an available RBS library")
  end

  it "warns about an unknown lockfile stdlib entry" do
    write_stdlib_lockfile("no_such_lib")
    output, = check_run("")

    expect(output).to include("no_such_lib").and include("rbs_collection.lock.yaml")
  end

  it "does not warn about real stdlib libraries, from either source" do
    write_stdlib_lockfile("ripper")
    output, = check_run("libraries: [json, rbs]\n") # rbs ships its own sig/

    expect(output).not_to include("is not an available RBS library")
  end

  it "does not audit a vendored library name (prime), and doctor exits 0" do
    output, = check_run("libraries: [prime]\n")
    expect(output).not_to include("is not an available RBS library")

    output, _, status = check_run("libraries: [prime]\n", command: "doctor")
    expect(output).not_to include("is not an available RBS library")
    expect(status).to eq(0)
  end

  it "keeps rbs unloaded on a warm run-cache hit" do
    check_run("libraries: [json]\n") # cold run primes the run cache
    output, rbs_features = check_run("libraries: [json]\n")

    expect(output).not_to include("is not an available RBS library")
    expect(rbs_features).to eq("")
  end
end
