# frozen_string_literal: true

require "spec_helper"
require "open3"
require "bundler"

# ADR-27 — the packaging-level guardrails against a Gemfile install. Rigor is a tool, not a library, and
# the gemspec's `required_ruby_version` (`>= 4.0.0, < 4.1`) makes a root-Gemfile entry outright
# unresolvable for the Ruby version almost every analyzed project runs. The remaining hazard is the
# narrow case where it *does* resolve — a Ruby 4.0 project — because there `bundle add` succeeds and the
# damage lands later, at the next `Bundler.require`.
#
# These specs pin the three surfaces that carry the counter-instruction to the reader (increasingly
# often an agent) who was told only "install https://rubygems.org/gems/rigortype", whose own page leads
# with `bundle add rigortype`.
RSpec.describe "packaging guardrails (ADR-27)" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:install_doc_url) { "https://github.com/rigortype/rigor/blob/master/docs/install.md" }

  describe "the `rigortype` require shim" do
    # A real subprocess, because the assertion is about what `require "rigortype"` does to a process that
    # has never loaded Rigor — exactly what `Bundler.require` does at an application's boot.
    #
    # The bundler env is stripped for the same reason: this suite runs under `bundle exec`, whose
    # `RUBYOPT=-rbundler/setup` the child would inherit, and this repo's own Gemfile carries a `gemspec`
    # directive — so setting up the bundle evaluates `rigortype.gemspec`, whose `require_relative
    # "lib/rigor/version"` defines `Rigor` before the child runs a line of its own. An analyzed
    # application's boot has none of that.
    def run_ruby(source)
      Bundler.with_unbundled_env do
        Open3.capture3("ruby", "-I", File.join(root, "lib"), "-e", source)
      end
    end

    def require_rigortype
      run_ruby('require "rigortype"')
    end

    it "does not raise, so a Gemfile entry cannot kill an application's boot" do
      _stdout, _stderr, status = require_rigortype

      expect(status.exitstatus).to eq(0)
    end

    it "warns that Rigor is a tool rather than a library, and routes to the install doc" do
      _stdout, stderr, _status = require_rigortype

      expect(stderr).to include("not a library")
      expect(stderr).to include("Gemfile")
      expect(stderr).to include(install_doc_url)
    end

    it "names `require: false` as the way to silence it without removing the entry" do
      _stdout, stderr, _status = require_rigortype

      expect(stderr).to include("require: false")
    end

    it "defines nothing — it is a guardrail, not an entry point" do
      # `require "rigor"` is the library entry; the shim must not become a second one, or it would
      # quietly make the Gemfile install *work* and undo the whole point.
      stdout, _stderr, status = run_ruby('require "rigortype"; puts defined?(Rigor).inspect')

      expect(status.exitstatus).to eq(0)
      expect(stdout.strip).to eq("nil")
    end
  end

  describe "the gem metadata" do
    let(:spec) do
      # Loaded rather than `require`d so the constant-heavy gemspec body stays out of this process.
      Gem::Specification.load(File.join(root, "rigortype.gemspec"))
    end

    it "tells the rubygems.org reader not to add Rigor to a Gemfile" do
      # The gem page renders `description`, and that page is what an agent fetches when handed the
      # rubygems.org URL — the one moment it decides between `bundle add` and a standalone install.
      expect(spec.description).to include("Gemfile")
      expect(spec.description).to include(install_doc_url)
    end

    it "repeats the routing after install, where `bundle add` has already succeeded" do
      expect(spec.post_install_message).to include("Gemfile")
      expect(spec.post_install_message).to include(install_doc_url)
    end

    it "keeps the require shim in the packaged files" do
      expect(spec.files).to include("lib/rigortype.rb")
    end
  end
end
