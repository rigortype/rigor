# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

require "rigor"
require "rigor/cli/check_command"

# Issue #428 — `effect.envelope-exceeded` must survive a cache hit.
#
# It did not: `rigor check`'s ADR-87 WD4 boot-slimming probe serves the ADR-45 `analysis.run-diagnostics`
# slot without booting the engine, and ADR-103 WD12 deliberately keeps the envelope judgment OUT of that
# slot (the `effects:` block is absent from its identity, so a finding stored there would outlive the
# configuration that produced it). Every warm run therefore skipped the judgment entirely and printed
# nothing — on a real project, 343 warnings cold and 0 warm with byte-identical configuration.
#
# The property under test is equality: a warm run and a cold run over the same tree and the same
# configuration produce the SAME diagnostics. That equality is trivially satisfiable by a warm run that
# quietly re-analysed, so every example also asserts the warm run really was served from cache — the
# `check-mutation-cache` gate's non-vacuity move. The signal is the run-stats block: `Runner#stats_for_run`
# returns nil for a cache-served run and the probe reports `stats: nil`, so "the warm arm printed no stats"
# is the CLI-visible proof that nothing was analysed. The day the cache silently disables itself, the warm
# arm re-analyses, the stats block comes back and these examples go red instead of passing for free.
RSpec.describe "effect envelope diagnostics across a cache hit" do
  around do |example|
    Dir.mktmpdir("rigor-envelope-cache-") do |dir|
      @dir = dir
      Dir.chdir(dir) { example.run }
    end
  end

  attr_reader :dir

  # The single unit under judgment: one method that provably performs `io.fs.read`.
  def write_project
    FileUtils.mkdir_p(File.join(dir, "app"))
    File.write(File.join(dir, "app", "reader.rb"), <<~RUBY)
      class Reader
        def read_it
          File.read("/etc/hosts")
        end
      end
    RUBY
  end

  def write_config(body)
    File.write(File.join(dir, ".rigor.yml"), body)
  end

  def write_signature(body)
    FileUtils.mkdir_p(File.join(dir, "sig"))
    File.write(File.join(dir, "sig", "reader.rbs"), body)
  end

  # One `rigor check`, stats ON, through the real CLI — the probe lives in `CheckCommand`, so an in-process
  # `Runner` would not exercise the path this issue is about. Returns `[diagnostic lines, analysed?]`.
  def check
    out = StringIO.new
    err = StringIO.new
    Rigor::CLI::CheckCommand.new(argv: ["--no-ci-detect", "--no-baseline"], out: out, err: err).run
    diagnostics = out.string.lines.map(&:chomp).grep(/: (warning|error|info): /)
    [diagnostics, err.string.include?("Wall time:")]
  end

  # The two lanes an envelope can be declared in, judged over the same Ruby file, so a lane difference can
  # only come from where the declaration was written.
  def envelope_config
    <<~YML
      paths:
        - app
      effects:
        envelopes:
          - match: "app/**/*.rb"
            effect: []
    YML
  end

  def annotation_config
    "paths:\n  - app\neffects: {}\n"
  end

  def pure_signature
    <<~RBS
      class Reader
        %a{pure}
        def read_it: () -> String
      end
    RBS
  end

  shared_examples "a declared envelope that survives a cache hit" do
    it "reports the same exceedance cold and warm, and the warm run really was cache-served" do
      cold, cold_analysed = check
      warm, warm_analysed = check

      expect(cold).to include(a_string_matching(/exceeds the envelope/))
      expect(warm).to eq(cold)

      # Non-vacuity, both directions: the cold arm analysed and the warm arm did not.
      expect(cold_analysed).to be(true)
      expect(warm_analysed).to be(false)
    end
  end

  context "with an `effects.envelopes:` stanza" do
    before do
      write_project
      write_config(envelope_config)
    end

    it_behaves_like "a declared envelope that survives a cache hit"

    # The configuration is absent from the diagnostics cache identity by design, so an `effects:` edit that
    # answers the finding invalidates nothing the probe can see. Getting this wrong turns one silent false
    # negative into two — a stale warning that outlives the stanza that raised it.
    it "re-judges a configuration-only edit with no Ruby file touched" do
      check
      before = File.mtime(File.join(dir, "app", "reader.rb"))

      write_config(envelope_config.sub("effect: []", 'effect: ["io.fs.read"]'))
      widened, = check
      expect(widened).to be_empty

      write_config(envelope_config)
      restored, = check
      expect(restored).to include(a_string_matching(/exceeds the envelope/))

      expect(File.mtime(File.join(dir, "app", "reader.rb"))).to eq(before)
    end

    it "re-judges an `effects.tolerated:` edit with no Ruby file touched" do
      check
      # The warm arm still fires BEFORE the edit — without it, "the finding is gone" would be satisfied by
      # a warm run that never judged anything, which is precisely the bug.
      warm, = check
      expect(warm).to include(a_string_matching(/exceeds the envelope/))

      write_config(envelope_config.sub("effects:\n", "effects:\n  tolerated: [\"io.fs.read\"]\n"))
      discharged, = check
      expect(discharged).to be_empty
    end
  end

  context "with an `%a{pure}` annotation in the project's own RBS" do
    before do
      write_project
      write_config(annotation_config)
      write_signature(pure_signature)
    end

    it_behaves_like "a declared envelope that survives a cache hit"

    it "re-judges an annotation-only edit with no Ruby file touched" do
      check
      # Every step below invalidates the cache by touching a signature file, so without this the example
      # would pass over three cold runs and prove nothing about the warm path.
      warm, = check
      expect(warm).to include(a_string_matching(/exceeds the envelope/))

      write_signature(pure_signature.sub("%a{pure}", "%a{rigor:v1:effect io.fs.read}"))
      widened, = check
      expect(widened).to be_empty

      write_signature(pure_signature)
      restored, = check
      expect(restored).to include(a_string_matching(/exceeds the envelope/))
    end
  end

  # `effect.annotations-unchecked` — the mirror-image pass, on the effects-OFF surface. It went the same way
  # for the same reason, and comes back by a different route: the probe reproduces it rather than declining,
  # because it was built to cost a glob and a regex.
  context "with annotations and no `effects:` block" do
    before do
      write_project
      write_config("paths:\n  - app\n")
      write_signature(pure_signature)
    end

    it "reports the residual `:info` cold and warm alike" do
      cold, cold_analysed = check
      warm, warm_analysed = check

      expect(cold).to include(a_string_matching(/effect collection never runs/))
      expect(warm).to eq(cold)
      expect(cold_analysed).to be(true)
      expect(warm_analysed).to be(false)
    end

    it "stops reporting it once the annotation is removed, with no Ruby file touched" do
      check
      warm, = check
      expect(warm).to include(a_string_matching(/effect collection never runs/))

      write_signature("class Reader\n  def read_it: () -> String\nend\n")
      answered, = check
      expect(answered).to be_empty
    end
  end
end
