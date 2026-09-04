# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Rigor::Environment::MissingGemConstantIndex do
  def write_gem(root, name, entry_relative, source)
    dir = File.join(root, name)
    path = File.join(dir, entry_relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, source)
    dir
  end

  def build(gems, dirs)
    described_class.build(gems, spec_resolver: ->(name, _version) { dirs[name] })
  end

  # Lays out a `<bundle>/ruby/X.Y.Z/gems/<name>-<version>/lib/<name>.rb` tree and returns the bundle root.
  def write_bundle(root, gems)
    gems.each do |name, version, source|
      path = File.join(root, "ruby", "4.0.0", "gems", "#{name}-#{version}", "lib", "#{name}.rb")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source)
    end
    root
  end

  it "maps a gem's top-level declarations to the gem, by reading — not by camelizing the gem name" do
    Dir.mktmpdir do |root|
      dirs = {
        "faraday" => write_gem(root, "faraday", "lib/faraday.rb", <<~RUBY),
          module Faraday
            class Connection
            end
          end
        RUBY
        # The declared constant does not match a camelization of the gem name — reading gets it right.
        "activesupport" => write_gem(root, "activesupport", "lib/activesupport.rb", <<~RUBY)
          module ActiveSupport
          end
          CoreExt = ActiveSupport
        RUBY
      }
      index = build([["faraday", "2.0.0"], ["activesupport", "7.0.0"]], dirs)

      expect(index).to eq(
        "Faraday" => "faraday",
        "ActiveSupport" => "activesupport",
        "CoreExt" => "activesupport"
      )
    end
  end

  it "roots a namespaced top-level declaration at its first segment" do
    Dir.mktmpdir do |root|
      dirs = { "money" => write_gem(root, "money", "lib/money.rb", "class Money::Error < StandardError; end\n") }
      expect(build([["money", "1.0.0"]], dirs)).to eq("Money" => "money")
    end
  end

  it "follows the dash -> directory entry-file convention" do
    Dir.mktmpdir do |root|
      dirs = {
        "rack-attack" => write_gem(root, "rack-attack", "lib/rack/attack.rb", "module Rack\nend\n")
      }
      expect(build([["rack-attack", "6.0.0"]], dirs)).to eq("Rack" => "rack-attack")
    end
  end

  it "fails open on a missing gem, a missing entry file, and an unparseable entry file" do
    Dir.mktmpdir do |root|
      dirs = {
        "no-entry" => write_gem(root, "no-entry", "lib/elsewhere.rb", "module NoEntry; end\n"),
        "broken" => write_gem(root, "broken", "lib/broken.rb", "class <%= oops %>\n")
      }
      index = build([["not-installed", "1.0.0"], ["no-entry", "1.0.0"], ["broken", "1.0.0"]], dirs)
      expect(index).to eq({})
    end
  end

  it "keeps the first gem on a top-level-constant collision" do
    Dir.mktmpdir do |root|
      dirs = {
        "aaa" => write_gem(root, "aaa", "lib/aaa.rb", "module Util; end\n"),
        "bbb" => write_gem(root, "bbb", "lib/bbb.rb", "module Util; end\n")
      }
      expect(build([["aaa", "1.0.0"], ["bbb", "1.0.0"]], dirs)).to eq("Util" => "aaa")
    end
  end

  it "resolves a gem's entry file from the target bundle, keyed on name-version" do
    Dir.mktmpdir do |root|
      bundle = write_bundle(File.join(root, "vendor", "bundle"), [
                              ["faraday", "2.0.0", "module Faraday; end\n"],
                              ["grape", "2.1.0", "module Grape; end\n"]
                            ])
      # spec_resolver returns nil so ONLY the bundle path is exercised.
      index = described_class.build(
        [["faraday", "2.0.0"], ["grape", "2.1.0"]],
        bundle_path: bundle, spec_resolver: ->(_n, _v) {}
      )
      expect(index).to eq("Faraday" => "faraday", "Grape" => "grape")
    end
  end

  it "prefers the bundle copy over the Gem::Specification fallback" do
    Dir.mktmpdir do |root|
      bundle = write_bundle(File.join(root, "b"), [["i18n", "1.14.0", "module I18n; end\n"]])
      fallback = write_gem(root, "i18n", "lib/i18n.rb", "module WrongVersion; end\n")
      index = described_class.build(
        [["i18n", "1.14.0"]], bundle_path: bundle, spec_resolver: ->(_n, _v) { fallback }
      )
      expect(index).to eq("I18n" => "i18n")
    end
  end

  it "falls back to Gem::Specification for a gem the bundle lacks (no-bundle project)" do
    Dir.mktmpdir do |root|
      fallback = write_gem(root, "i18n", "lib/i18n.rb", "module I18n; end\n")
      index = described_class.build(
        [["i18n", "1.14.0"]], bundle_path: nil, spec_resolver: ->(name, _v) { name == "i18n" ? fallback : nil }
      )
      expect(index).to eq("I18n" => "i18n")
    end
  end
end

# Issue #763 — the git-sourced bundler layout.
#
# `bundle_gem_dirs` walked `<bundle>/ruby/*/gems/*` only, so a `git:`-sourced gem owned none of its
# constants and every reference into it recorded the generic engine-gap cause instead of the honest
# add-RBS one. The assertions are positive (a constant maps to its gem) because the failure being fixed
# is an ABSENT mapping, which every "does not include" assertion also passes on.
RSpec.describe Rigor::Environment::MissingGemConstantIndex, "git-sourced layout (#763)" do
  # Writes a bundle tree with one rubygems-layout gem and one git-layout gem, and returns the root.
  def bundle_with(dir, git_repo_dirname:, git_gemspec_name:)
    rubygems = File.join(dir, "ruby", "4.0.0", "gems", "plain_gem-1.2.3", "lib")
    git = File.join(dir, "ruby", "4.0.0", "bundler", "gems", git_repo_dirname, "lib")
    FileUtils.mkdir_p(rubygems)
    FileUtils.mkdir_p(git)
    File.write(File.join(rubygems, "plain_gem.rb"), "module PlainGemConst; end\n")
    File.write(File.join(git, "#{git_gemspec_name}.rb"), "module GitGemConst; end\n")
    File.write(File.join(File.dirname(git), "#{git_gemspec_name}.gemspec"), "# not evaluated\n")
    dir
  end

  it "indexes a git-sourced gem's constants, keyed by the name its gemspec declares" do
    Dir.mktmpdir do |dir|
      # The repository directory name deliberately differs from the gem name — a fork, or a monorepo.
      bundle_with(dir, git_repo_dirname: "some-fork-abcdef123456", git_gemspec_name: "git_gem")
      index = described_class.build(
        [["plain_gem", "1.2.3"], ["git_gem", "9.9.9"]],
        bundle_path: dir, spec_resolver: ->(_n, _v) { nil }
      )
      expect(index["GitGemConst"]).to eq("git_gem")
      # The must-still-work half: the rubygems layout is untouched.
      expect(index["PlainGemConst"]).to eq("plain_gem")
    end
  end

  it "contributes nothing for a checkout with no gemspec rather than guessing from the directory name" do
    Dir.mktmpdir do |dir|
      bundle_with(dir, git_repo_dirname: "git_gem-abcdef123456", git_gemspec_name: "git_gem")
      FileUtils.rm(Dir.glob(File.join(dir, "ruby", "4.0.0", "bundler", "gems", "*", "*.gemspec")))
      index = described_class.build(
        [["git_gem", "9.9.9"]], bundle_path: dir, spec_resolver: ->(_n, _v) { nil }
      )
      expect(index).not_to have_key("GitGemConst")
    end
  end
end
