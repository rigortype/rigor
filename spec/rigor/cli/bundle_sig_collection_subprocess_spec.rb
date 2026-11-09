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
  # The loader's "N RBS class definition(s) failed to build" warning, or the error class it names.
  let(:build_warning) { /failed to build|build failed|Duplicat|MixinClass/i }
  let(:gem_a) { "class Bar\n  def a: () -> Integer\nend\n" }

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

  def check_run(libraries, *flags)
    File.write(File.join(dir, ".rigor.yml"),
               "severity_profile: balanced\nlibraries: #{libraries}\nbundler:\n  bundle_path: bundle\n")
    out, err, = Open3.capture3("bundle", "exec", "ruby", exe, "check", "--no-ci-detect", "--no-stats",
                               "--no-baseline", *flags, "lib", chdir: dir, stdin_data: "")
    "#{out}#{err}".gsub(/^rigor: --incremental[^\n]*\n/, "")
  end

  {
    "identical" => ["class Bar\n  def a: () -> Integer\nend\n", %w[a]],
    "overlapping" => ["class Bar\n  def a: () -> String\n  def b: () -> Integer\nend\n", %w[a b]],
    "disjoint" => ["class Bar\n  def b: () -> Integer\nend\n", %w[a b]]
  }.each do |shape, (collection_rbs, members)|
    %w[[] [bargem]].each do |libraries|
      it "loads #{shape} declarations without a build error under libraries: #{libraries}" do
        install_gem("bargem", bundle_rbs: gem_a, collection_rbs: collection_rbs)
        File.write(File.join(dir, "lib", "a.rb"),
                   "#{members.map { |m| "Bar.new.#{m}.no_#{m}\n" }.join}Bar.new.zz\n")
        output = check_run(libraries)

        expect(output).not_to match(build_warning)
        # The gem's own `Bar#a` binds (`-> Integer`), not the collection's `-> String`.
        members.each do |m|
          expect(output).to include("undefined method `no_#{m}' for Integer")
          expect(output).not_to include("undefined method `#{m}'")
        end
        expect(output).to include("undefined method `zz'")
      end
    end
  end

  # A variable both copies declare: RBS raises `InstanceVariableDuplicationError` (`@x`) or
  # `ClassInstanceVariableDuplicationError` (`self.@y`) for two declarations of one.
  { "@x" => "@x: Integer", "self.@y" => "self.@y: Integer" }.each do |label, variable|
    %w[[] [bargem]].each do |libraries|
      it "stands down a #{label} both copies declare under libraries: #{libraries}" do
        install_gem("bargem", bundle_rbs: "class Bar\n  #{variable}\n  def a: () -> Integer\nend\n",
                              collection_rbs: "class Bar\n  #{variable}\n  def b: () -> Integer\nend\n")
        File.write(File.join(dir, "lib", "a.rb"), "Bar.new.a.no_a\nBar.new.zz\n")
        output = check_run(libraries)

        expect(output).not_to match(build_warning)
        expect(output).to include("undefined method `no_a' for Integer").and include("undefined method `zz'")
      end
    end
  end

  it "drops the copy's mixin of a module the gem's sig/ declares as a class" do
    copy = "module Helper\nend\nclass Bar\n  include Helper\n  def b: () -> Integer\nend\n"
    install_gem("bargem", bundle_rbs: "#{gem_a}class Helper\nend\n", collection_rbs: copy)
    File.write(File.join(dir, "lib", "a.rb"), "Bar.new.a.no_a\nBar.new.b.no_b\nBar.new.zz\n")
    output = check_run("[]")

    expect(output).not_to match(build_warning)
    expect(output).to include("undefined method `no_a' for Integer")
      .and include("undefined method `no_b' for Integer")
    expect(output).to include("undefined method `zz'")
  end

  it "does not report a gem whose name holds -<digit> (foo-2fa) as missing RBS when it ships sig/" do
    install_gem("foo-2fa", bundle_rbs: gem_a)
    File.write(File.join(dir, "lib", "a.rb"), "Bar.new.a.no_a\n")
    output = check_run("[]")

    expect(output).to include("undefined method `no_a' for Integer")
    expect(output).not_to include("no RBS available")
  end

  # #2987 — a libraries: name whose bundle sig/ loaded is not an unknown RBS library.
  it "does not warn that a bundle-sig gem named under libraries: is not an available RBS library" do
    install_gem("foo-2fa", bundle_rbs: gem_a)
    File.write(File.join(dir, "lib", "a.rb"), "Bar.new.a.no_a\n")
    output = check_run("[foo-2fa]")

    expect(output).to include("undefined method `no_a' for Integer")
    expect(output).not_to include("is not an available RBS library")
  end

  it "still warns about an rbs_collection.lock.yaml stdlib entry even when a bundle sig/ shares its name" do
    install_gem("foo-2fa", bundle_rbs: gem_a)
    File.write(File.join(dir, "rbs_collection.lock.yaml"),
               "---\npath: .gem_rbs_collection\ngems:\n- name: foo-2fa\n  version: '1.0'\n  " \
               "source:\n    type: stdlib\n")
    File.write(File.join(dir, "lib", "a.rb"), "x = 1\n")

    expect(check_run("[]")).to include("stdlib entry \"foo-2fa\" is not an available RBS library")
  end

  it "still warns about a libraries: name nothing provides" do
    install_gem("foo-2fa", bundle_rbs: gem_a)
    File.write(File.join(dir, "lib", "a.rb"), "Bar.new.a.no_a\n")

    expect(check_run("[foo-2fa, no_such_lib]")).to include("no_such_lib").and include("is not an available RBS library")
  end

  # #2987 — a gem gaining or losing its own sig/ while no analysed file changes: the warm run must answer as a
  # fresh --no-cache run does.
  describe "run cache across a bundle gem gaining or losing sig/" do
    let(:copy) { "class Bar\n  def a: () -> String\nend\n" }
    let(:gem_sig) { File.join(dir, "bundle", "ruby", "4.0.0", "gems", "bargem-1.0", "sig") }

    def stash_sig = FileUtils.mv(gem_sig, "#{gem_sig}.off")
    def restore_sig = FileUtils.mv("#{gem_sig}.off", gem_sig)

    before do
      install_gem("bargem", bundle_rbs: gem_a, collection_rbs: copy)
      stash_sig
      File.write(File.join(dir, "lib", "a.rb"), "Bar.new.a.no_a\n")
    end

    [[], ["--incremental"]].each do |flags|
      mode = flags.join

      it "re-analyses when the gem gains sig/ #{mode}" do
        expect(check_run("[]", *flags)).to include("undefined method `no_a' for String")
        restore_sig

        warm = check_run("[]", *flags)
        expect(warm).to include("undefined method `no_a' for Integer")
        expect(check_run("[]", *flags)).to eq(warm)
        expect(warm).to eq(check_run("[]", "--no-cache"))
      end

      it "re-analyses when the gem loses sig/ #{mode}" do
        restore_sig
        expect(check_run("[]", *flags)).to include("undefined method `no_a' for Integer")
        stash_sig

        warm = check_run("[]", *flags)
        expect(warm).to include("undefined method `no_a' for String")
        expect(warm).to eq(check_run("[]", "--no-cache"))
      end

      it "re-analyses when a .rbs inside the gem's sig/ is edited #{mode}" do
        restore_sig
        expect(check_run("[]", *flags)).to include("undefined method `no_a' for Integer")
        File.write(File.join(gem_sig, "bargem.rbs"), "class Bar\n  def a: () -> Symbol\nend\n")

        warm = check_run("[]", *flags)
        expect(warm).to include("undefined method `no_a' for Symbol")
        expect(warm).to eq(check_run("[]", "--no-cache"))
      end
    end

    # A warm HIT is served without the inference engine in $LOADED_FEATURES (run_cache_probe_spec); a MISS loads it.
    def engine_loaded?
      marker = File.join(dir, "engine_features.txt")
      File.write(File.join(dir, "probe.rb"),
                 "at_exit { File.write(#{marker.inspect}, $LOADED_FEATURES.grep(%r{/rigor/inference/}).size.to_s) }\n")
      File.write(File.join(dir, ".rigor.yml"),
                 "severity_profile: balanced\nlibraries: []\nbundler:\n  bundle_path: bundle\n")
      Open3.capture3("bundle", "exec", "ruby", "-r", File.join(dir, "probe.rb"), exe, "check", "--no-ci-detect",
                     "--no-stats", "--no-baseline", "lib", chdir: dir, stdin_data: "")
      File.read(marker).to_i.positive?
    end

    it "stays a hit when nothing changes" do
      expect(engine_loaded?).to be(true)
      expect(engine_loaded?).to be(false)
    end

    it "is a miss, not a hit, once the gem gains sig/" do
      expect(engine_loaded?).to be(true)
      restore_sig
      expect(engine_loaded?).to be(true)
    end
  end
end
