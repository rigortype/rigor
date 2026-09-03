# frozen_string_literal: true

# Issue #672 — when an ADR-72 gem overlay must stand down.
#
# `rigor-activesupport-core-ext` ships one RBS surface twice by design: as the auto-applied overlay in
# `data/gem_overlay/activesupport/`, and as the plugin's own `sig/`. They must never both load, and the
# stand-down that guaranteed that keyed on the plugin REGISTRY — so a project that wired the twin's
# signatures through `signature_paths:` instead of `plugins:` got no stand-down at all. Both halves
# loaded, `RBS::DefinitionBuilder` raised `DuplicatedMethodDefinitionError` for every class they share,
# and `class_known?` kept answering true while the definition was gone: every call into `Time`, `Integer`,
# `String` — and, transitively, into the project's OWN classes whose signatures name them — degraded to
# `Dynamic[top]`, on a run that exited 0.
#
# **That failure mode is why the assertions here are positive.** A collapsed class produces ZERO
# diagnostics, so every "does not fire" assertion passes on it; on master `Widget#ttl.to_i` read
# `Dynamic[top]` rather than the declared `Integer`, and nothing in an absence-only gate could tell that
# from a clean run. Each example below pins a type that must still RESOLVE alongside the diagnostic that
# must still FIRE.
require "spec_helper"
require "tmpdir"

unless defined?(AS_STAND_DOWN_PLUGIN_LIB)
  AS_STAND_DOWN_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-activesupport-core-ext/lib", __dir__)
end
$LOAD_PATH.unshift(AS_STAND_DOWN_PLUGIN_LIB) unless $LOAD_PATH.include?(AS_STAND_DOWN_PLUGIN_LIB)
require "rigor-activesupport-core-ext"

RSpec.describe "ADR-72 gem-overlay stand-down" do
  # The engine's own bundled copy of the overlay's plugin twin — the directory a project reaches when it
  # points `signature_paths:` at the plugin instead of listing it under `plugins:`.
  def twin_sig
    File.expand_path("../../../plugins/rigor-activesupport-core-ext/sig", __dir__)
  end

  def gemfile_lock
    <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          activesupport (7.1.3)

      PLATFORMS
        ruby

      DEPENDENCIES
        activesupport

      BUNDLED WITH
         2.5.6
    LOCK
  end

  # `ttl` names `ActiveSupport::Duration` from the project's own signature — the only way a real `Duration`
  # receiver arises without the plugin's `dynamic_return` rule, and therefore the shape that exercises both
  # halves of the fix at once.
  def write_project(dir)
    FileUtils.mkdir_p(File.join(dir, "sig"))
    File.write(File.join(dir, "Gemfile.lock"), gemfile_lock)
    File.write(File.join(dir, "widget.rb"), "class Widget\nend\n")
    File.write(File.join(dir, "sig", "widget.rbs"), "class Widget\n  def ttl: () -> ActiveSupport::Duration\nend\n")
    File.write(File.join(dir, "code.rb"), <<~RUBY)
      Rigor.dump_type("user_account".camelize)
      Rigor.dump_type(3.minutes)
      Rigor.dump_type(Widget.new.ttl.to_i)
      Widget.new.ttl.round
      Time.no_such_method_at_all
    RUBY
  end

  def run_project(dir, signature_paths:, plugins: [])
    Dir.chdir(dir) do
      configuration = Rigor::Configuration.new(
        "paths" => [File.join(dir, "widget.rb"), File.join(dir, "code.rb")],
        "signature_paths" => signature_paths,
        "plugins" => plugins,
        "bundler" => { "lockfile" => "Gemfile.lock", "auto_detect" => true }
      )
      guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil))
    end
  end

  def dumps(result)
    result.diagnostics.select { |d| d.qualified_rule == "dump.type" }.map { |d| d.message.sub("dump_type: ", "") }
  end

  def undefined_methods(result)
    result.diagnostics.select { |d| d.rule == "call.undefined-method" }.map(&:method_name)
  end

  around do |example|
    Dir.mktmpdir("rigor-overlay-stand-down-") do |dir|
      write_project(dir)
      @project = dir
      example.run
    end
  end

  attr_reader :project

  describe "the twin's signatures wired through `signature_paths:`" do
    let(:result) { run_project(project, signature_paths: [File.join(project, "sig"), twin_sig]) }

    it "reports a genuinely undefined method instead of collapsing the class that declares it" do
      expect(undefined_methods(result)).to eq(["no_such_method_at_all"])
      expect(result).not_to be_success
    end

    # The half an absence-only gate cannot see. On master all three of these read `Dynamic[top]`, because
    # `String`, `Integer` and (through `Widget`'s signature) the project's own class had all collapsed.
    it "keeps the declared surface resolving, not merely quiet" do
      expect(dumps(result)).to eq(["String", "Dynamic[top]", "Integer"])
    end

    # `Duration` forwards anything it does not define to the wrapped numeric via `method_missing`, so the
    # twin's necessarily-partial declaration must not make `round` "undefined". The plugin manifest's
    # `open_receivers:` cannot say so here — no plugin is loaded — and with the overlay standing down the
    # #632 overlay gate is false too, so this is the route's own protection under test.
    it "protects Duration's method_missing surface, which no plugin manifest is present to declare open" do
      # Paired locally, not just with the example above: `round` staying quiet is what a collapsed
      # `Duration` looks like too, so the declared half of the same receiver has to be seen resolving in
      # the same run for the absence to mean anything.
      expect(dumps(result)).to include("Integer")
      expect(undefined_methods(result)).not_to include("round")
    end
  end

  describe "the routes that must not change" do
    it "leaves the overlay-only project alone — no signature_paths naming the twin" do
      result = run_project(project, signature_paths: [File.join(project, "sig")])

      expect(dumps(result)).to eq(["String", "Dynamic[top]", "Integer"])
      expect(undefined_methods(result)).to eq(["no_such_method_at_all"])
    end

    # The stand-down must key on the twin, not on "the project declared any signature_paths at all": a
    # project with its own unrelated `sig/` still needs the overlay, and dropping it would turn every
    # ActiveSupport selector into a false `call.undefined-method`.
    it "keeps the overlay for a signature_paths: entry that is not the twin" do
      FileUtils.mkdir_p(File.join(project, "other_sig"))
      result = run_project(project, signature_paths: [File.join(project, "sig"), File.join(project, "other_sig")])

      expect(dumps(result)).to eq(["String", "Dynamic[top]", "Integer"])
      expect(undefined_methods(result)).to eq(["no_such_method_at_all"])
    end

    # The regression the adversarial review of the first cut caught, and the reason the stand-down asks
    # what an entry LOADS rather than what it looks like. Both of these MATCH the twin as strings while
    # the loader reads nothing from them (`SignaturePathAudit` calls them `:not_directory` / `:missing`),
    # so standing the overlay down for either left the project with NEITHER copy of the RBS: ordinary
    # `"user_account".camelize` and `3.minutes` fired `call.undefined-method` on correct Rails code.
    #
    # The positive half is what makes these non-vacuous: the overlay has to be seen still WORKING, not
    # merely seen not-crashing, which is why the dump triple is pinned rather than the error list alone.
    it "keeps the overlay for an entry naming the twin's .rbs file, which loads nothing" do
      entry = File.join(twin_sig, "active_support", "core_ext.rbs")
      result = run_project(project, signature_paths: [File.join(project, "sig"), entry])

      expect(dumps(result)).to eq(["String", "Dynamic[top]", "Integer"])
      expect(undefined_methods(result)).to eq(["no_such_method_at_all"])
    end

    it "keeps the overlay for an entry naming a subdirectory of the twin that does not exist" do
      result = run_project(project, signature_paths: [File.join(project, "sig"), File.join(twin_sig, "nope")])

      expect(dumps(result)).to eq(["String", "Dynamic[top]", "Integer"])
      expect(undefined_methods(result)).to eq(["no_such_method_at_all"])
    end

    # The other direction: a symlink reaches the twin's declarations while matching no prefix, so the
    # string test left BOTH copies loaded and the class collapsed. `dumps` proves it did not.
    it "stands the overlay down for a symlink to the twin" do
      link = File.join(project, "twinlink")
      File.symlink(twin_sig, link)
      result = run_project(project, signature_paths: [File.join(project, "sig"), link])

      expect(dumps(result)).to eq(["String", "Dynamic[top]", "Integer"])
      expect(undefined_methods(result)).to eq(["no_such_method_at_all"])
    end

    # `3.minutes` reads `ActiveSupport::Duration` here and `Dynamic[top]` everywhere else in this file:
    # naming the class on a multiplier is the plugin's `dynamic_return` rule (#534), which no RBS route
    # carries. That difference is the reason the `plugins:` route stays the recommended one, and pinning it
    # keeps this example from passing on a run that merely resembled the plugin being loaded.
    it "leaves the `plugins:` route alone" do
      entry = { "gem" => "rigor-activesupport-core-ext", "id" => Rigor::Plugin::ActivesupportCoreExt.manifest.id }
      result = run_project(project, signature_paths: [File.join(project, "sig")], plugins: [entry])

      expect(dumps(result)).to eq(["String", "ActiveSupport::Duration", "Integer"])
      expect(undefined_methods(result)).to eq(["no_such_method_at_all"])
    end
  end

  # The seam the stand-down asks its question through. Both halves of a bundled plugin resolve off one
  # `ENGINE_ROOT`, so the `sig/` answer cannot drift from the `lib/` one {Loader.bundled_plugin_path} gives.
  describe "Rigor::Plugin::Loader.bundled_plugin_sig_path" do
    it "resolves the bundled plugin's own sig directory" do
      expect(Rigor::Plugin::Loader.bundled_plugin_sig_path("rigor-activesupport-core-ext")).to eq(twin_sig)
    end

    it "is nil for a gem the engine does not bundle" do
      expect(Rigor::Plugin::Loader.bundled_plugin_sig_path("rigor-no-such-plugin")).to be_nil
    end
  end

  # The predicate both the stand-down and `CheckRules#gem_overlay_loaded?` ask. Its contract is "would the
  # RBS loader read one of the twin's `.rbs` files from these entries", NOT "does one of these strings look
  # like the twin" — the four cases below are exactly where those two answers differ.
  describe "Rigor::Environment.bundled_overlay_twin_signatures?" do
    def wired?(*paths)
      Rigor::Environment.bundled_overlay_twin_signatures?(paths)
    end

    it "recognises the twin directory itself" do
      expect(wired?(twin_sig)).to be(true)
    end

    # RBS walks a signature directory recursively, so an entry either side of the twin reaches its `.rbs`.
    it "recognises an entry that contains the twin, and one that sits inside it" do
      expect(wired?(File.dirname(twin_sig))).to be(true)
      expect(wired?(File.join(twin_sig, "active_support"))).to be(true)
    end

    it "is false for an unrelated signature directory, and for a sibling sharing the twin's prefix" do
      expect(wired?("/some/project/sig")).to be(false)
      expect(wired?("#{twin_sig}_vendored")).to be(false)
    end

    # Matches the twin as a string, loads nothing: the loader `add`s directories only, which is what
    # `SignaturePathAudit` reports as `:not_directory` and `:missing`. Standing the overlay down for
    # either is the false-positive regression the review caught.
    it "is false for the twin's .rbs file itself, and for a nonexistent subdirectory of it" do
      expect(wired?(File.join(twin_sig, "active_support", "core_ext.rbs"))).to be(false)
      expect(wired?(File.join(twin_sig, "nope"))).to be(false)
    end

    # Loads the twin without matching it as a string — the residue the ADR would otherwise be wrong about.
    it "is true for a symlink to the twin, and for a case-variant spelling where the filesystem folds case" do
      link = File.join(project, "twinlink")
      File.symlink(twin_sig, link)
      expect(wired?(link)).to be(true)

      shouted = File.join(File.dirname(twin_sig), File.basename(twin_sig).upcase)
      expect(wired?(shouted)).to be(true) if File.directory?(shouted)
    end
  end
end
