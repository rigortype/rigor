# frozen_string_literal: true

# A gem Bundler installed as a platform build — `<name>-<version>-<platform>/` — owned none of its constants
# in ADR-82 WD9's index, so every read of one kept the generic `unsupported_syntax` cause and
# `coverage --protection` reported the boundary as engine-gap. Measured on redmine, whose lockfile locks
# `commonmarker (2.10.0)` plus seven platform builds while the host installs
# `commonmarker-2.10.0-arm64-darwin/`: `Commonmarker.to_html` reported engine-gap where the honest story is
# add-RBS. Both resolvers had the gap — the lockfile-driven one and the lockfile-less #530 fallback.

require "spec_helper"
require "fileutils"
require "prism"
require "tmpdir"

require "rigor/environment"
require "rigor/inference/protection_scanner"
require "rigor/scope"

RSpec.describe "gem provenance through a platform-tagged install directory" do
  # A gem with no `sig/`, installed only as its platform build. The entry file is real because the index
  # establishes ownership by reading it.
  def write_project
    entry = File.join("vendor/bundle/ruby/4.0.0/gems/nativegem-1.0.0-arm64-darwin", "lib", "nativegem.rb")
    FileUtils.mkdir_p(File.dirname(entry))
    File.write(entry, "module Nativegem\n  class Document\n  end\nend\n")
    FileUtils.mkdir_p("lib")
    File.write(File.join("lib", "a.rb"), "def run\n  Nativegem::Document.new.render\nend\n")
  end

  def write_lockfile(platform_specs)
    File.write("Gemfile.lock", <<~LOCK)
      GEM
        remote: https://rubygems.org/
        specs:
      #{platform_specs.map { |spec| "    nativegem (#{spec})" }.join("\n")}

      PLATFORMS
        arm64-darwin
        ruby
        x86_64-linux

      DEPENDENCIES
        nativegem

      BUNDLED WITH
         2.6.0
    LOCK
  end

  def origins(lockfile: nil)
    environment = Rigor::Environment.for_project(
      root: Dir.pwd, bundler_bundle_path: "vendor/bundle", bundler_auto_detect: false, bundler_lockfile: lockfile
    )
    root = Prism.parse(File.read(File.join("lib", "a.rb"))).value
    scanner = Rigor::Inference::ProtectionScanner.new(scope: Rigor::Scope.empty(environment: environment))
    scanner.scan(root).sites.to_h { |site| [site.method_name, site.dynamic_origin] }
  end

  around do |example|
    Dir.mktmpdir("rigor-platform-gem-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "attributes the constant through the lockfile's platform variant, though its representative is `ruby`" do
    write_project
    write_lockfile(%w[1.0.0 1.0.0-x86_64-linux 1.0.0-arm64-darwin])
    expect(origins(lockfile: "Gemfile.lock")).to include("render" => :external_gem_without_rbs)
  end

  it "keeps the generic cause when the lockfile never locked the installed platform" do
    # The must-still-decline arm: the directory is found through a locked variant, not by its name prefix.
    write_project
    write_lockfile(%w[1.0.0 1.0.0-x86_64-linux])
    expect(origins(lockfile: "Gemfile.lock")).to include("render" => :unsupported_syntax)
  end

  it "attributes the constant without a lockfile, from the platform-tagged directory name (#530 fallback)" do
    write_project
    expect(origins).to include("render" => :external_gem_without_rbs)
  end
end
