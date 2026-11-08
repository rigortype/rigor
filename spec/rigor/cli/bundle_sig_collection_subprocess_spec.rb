# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"
require "fileutils"

# #2978 — a gem that ships its own `sig/` in the bundle and also has an `rbs collection` copy. Each member the gem's
# `sig/` declares stands down from the collection copy; the rest of the copy loads. Each example runs `rigor check`
# as a subprocess, as collection_library_subprocess_spec does.
RSpec.describe "bundle sig/ beside its rbs collection copy (subprocess)" do
  let(:exe) { File.join(File.expand_path("../../..", __dir__), "exe", "rigor") }

  around do |example|
    Dir.mktmpdir("rigor-bundle-sig-collection-spec-") do |dir|
      @dir = dir
      FileUtils.mkdir_p(File.join(dir, "lib"))
      example.run
    end
  end

  attr_reader :dir

  def install_gem(name, bundle_rbs:, collection_rbs: nil)
    sig = File.join(dir, "bundle", "ruby", "4.0.0", "gems", "#{name}-1.0", "sig")
    FileUtils.mkdir_p(sig)
    File.write(File.join(sig, "#{name}.rbs"), bundle_rbs)
    File.write(File.join(dir, "Gemfile.lock"),
               "GEM\n  remote: https://rubygems.org/\n  specs:\n    #{name} (1.0)\n\n" \
               "PLATFORMS\n  ruby\n\nDEPENDENCIES\n  #{name}\n")
    return if collection_rbs.nil?

    FileUtils.mkdir_p(File.join(dir, ".gem_rbs_collection", name, "1.0"))
    File.write(File.join(dir, ".gem_rbs_collection", name, "1.0", "#{name}.rbs"), collection_rbs)
    File.write(File.join(dir, "rbs_collection.lock.yaml"),
               "---\npath: .gem_rbs_collection\ngems:\n- name: #{name}\n  version: '1.0'\n  source:\n    type: git\n")
  end

  def check_run(libraries)
    File.write(File.join(dir, ".rigor.yml"),
               "severity_profile: balanced\nlibraries: #{libraries}\nbundler:\n  bundle_path: bundle\n")
    out, err, = Open3.capture3("bundle", "exec", "ruby", exe, "check", "--no-ci-detect", "--no-stats",
                               "--no-baseline", "lib", chdir: dir, stdin_data: "")
    "#{out}#{err}"
  end

  gem_a = "class Bar\n  def a: () -> Integer\nend\n"
  rows = {
    "identical" => [gem_a, %w[a]],
    "overlapping" => ["class Bar\n  def a: () -> String\n  def b: () -> Integer\nend\n", %w[a b]],
    "disjoint" => ["class Bar\n  def b: () -> Integer\nend\n", %w[a b]]
  }

  rows.each do |shape, (collection_rbs, members)|
    %w[[] [bargem]].each do |libraries|
      it "loads #{shape} declarations without a build error under libraries: #{libraries}" do
        install_gem("bargem", bundle_rbs: gem_a, collection_rbs: collection_rbs)
        File.write(File.join(dir, "lib", "a.rb"),
                   "#{members.map { |m| "Bar.new.#{m}.no_#{m}\n" }.join}Bar.new.zz\n")
        output = check_run(libraries)

        expect(output).not_to match(/build failed|Duplicated/i)
        # The gem's own `Bar#a` binds (`-> Integer`), not the collection's `-> String`.
        members.each { |m| expect(output).to include("undefined method `no_#{m}' for Integer") }
        members.each { |m| expect(output).not_to include("undefined method `#{m}'") }
        expect(output).to include("undefined method `zz'")
      end
    end
  end

  it "drops the copy's mixin of a module the gem's sig/ declares as a class" do
    install_gem("bargem", bundle_rbs: "#{gem_a}class Helper\nend\n",
                          collection_rbs: "module Helper\nend\nclass Bar\n  include Helper\n  def b: () -> Integer\nend\n")
    File.write(File.join(dir, "lib", "a.rb"), "Bar.new.a.no_a\nBar.new.b.no_b\nBar.new.zz\n")
    output = check_run("[]")

    expect(output).not_to match(/build failed|MixinClass/i)
    expect(output).to include("undefined method `no_a' for Integer").and include("undefined method `no_b' for Integer")
    expect(output).to include("undefined method `zz'")
  end

  it "does not report a gem whose name holds -<digit> (foo-2fa) as missing RBS when it ships sig/" do
    install_gem("foo-2fa", bundle_rbs: gem_a)
    File.write(File.join(dir, "lib", "a.rb"), "Bar.new.a.no_a\n")
    output = check_run("[]")

    expect(output).to include("undefined method `no_a' for Integer")
    expect(output).not_to include("no RBS available")
  end
end
