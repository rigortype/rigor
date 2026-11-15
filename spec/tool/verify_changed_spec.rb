# frozen_string_literal: true

# Gates `bin/verify-changed`'s fixture→spec selection (#3171). A changed file
# under a fixtures/ tree is matched by the directory path that identifies it:
# `demo.rb` sits in dozens of fixture directories, and matching its basename
# stem selected ~97 spec files for a one-file change. `--list-specs` prints the
# selection without running the checks; VERIFY_CHANGED_PATHS stands the diff in,
# so the examples read the real tree and never run RSpec through the script.
#
# The nonexistent fixture names below are spelled apart so a ghost path stays
# unmatched: every literal here is text the selection greps for. The real
# fixture paths in the other examples do select this file, which is why their
# size assertions leave room for it.
require "open3"
require "spec_helper"

RSpec.describe "bin/verify-changed spec selection" do
  let(:script) { File.expand_path("../../bin/verify-changed", __dir__) }
  let(:root) { File.expand_path("../..", __dir__) }

  # [selected spec paths, uncovered fixture paths] for the given changed paths.
  def selection_for(*paths)
    env = { "VERIFY_CHANGED_PATHS" => paths.join("\n") }
    out, err, status = Bundler.with_unbundled_env do
      Open3.capture3(env, script, "HEAD", "--list-specs", chdir: root)
    end
    expect(status.exitstatus).to eq(0), "#{out}\n#{err}"
    specs = out.lines.map(&:strip).reject(&:empty?)
    uncovered = err.scan(/^ {2}- (\S+) \(/).flatten
    [specs, uncovered]
  end

  it "selects few specs for one fixture's demo.rb, by its directory" do
    specs, uncovered = selection_for("spec/integration/fixtures/block_content_ivar_capture/demo.rb")
    expect(uncovered).to be_empty
    expect(specs.length).to be <= 10
    expect(specs).to include("spec/integration/type_construction_spec.rb")
    # The stem match this replaces also selected every spec that merely says "demo".
    expect(specs).not_to include("spec/rigor/plugin_spec.rb")
  end

  # Round 2: capping the bare stem dropped the one spec that names four flat
  # fixtures by file, and the uncovered line then said nothing named them. A
  # spec addresses a fixture as a file, so the extension is part of the
  # identifier. The other three are spelled apart in the example below so this
  # file does not join their selections.
  it "selects the specs that name a flat fixture by its file name" do
    specs, uncovered = selection_for("spec/integration/fixtures/hash_shape.rb")
    expect(uncovered).to be_empty
    expect(specs).to include("spec/integration/type_construction_spec.rb")
    expect(specs).to include("spec/rigor/inference/method_dispatcher/overload_selector_spec.rb")
    %w[assertions each_with_index parity].each do |stem|
      named, bare = selection_for("spec/integration/fixtures/#{stem}.rb")
      expect(bare).to be_empty, stem
      expect(named).to include("spec/integration/type_construction_spec.rb"), stem
    end
    # Six: this file, the three specs that name the fixture, and the two gates
    # that enumerate the tree (see "runs the enumerating gates" below).
    expect(specs.length).to be <= 6
  end

  # The directory below is one `.` away from a real fixture directory, and it is
  # assembled here so this file does not carry it as a literal. Unescaped, that
  # `.` matches any character and the path selects interface_parity_spec.rb —
  # and because a coincidental hit counts as a match, it would also suppress
  # the basename route.
  it "matches a fixture directory literally, not as a pattern" do
    dir = %w[interfac _parity].join(".")
    ghost = %w[unique_name 3171].join("_")
    specs, uncovered = selection_for("spec/integration/fixtures/#{dir}/joins/#{ghost}.rb")
    expect(specs).to be_empty
    expect(uncovered).not_to be_empty
  end

  it "keeps the basename match for a flat fixture with a distinctive name" do
    specs, uncovered = selection_for("spec/integration/fixtures/and_assign_narrowing.rb")
    expect(uncovered).to be_empty
    expect(specs).to include("spec/integration/type_construction_spec.rb")
  end

  it "matches a nested fixture by the directory prefix specs name" do
    specs, uncovered = selection_for("spec/integration/fixtures/interface_parity/joins/sig/joins.rbs")
    expect(uncovered).to be_empty
    expect(specs).to include("spec/integration/interface_parity_spec.rb")
    expect(specs.length).to be <= 5
  end

  it "reaches a container fixture's own specs, not the whole container" do
    specs, uncovered = selection_for("spec/integration/fixtures/effects/tracer/loud.rb")
    expect(uncovered).to be_empty
    expect(specs).to include("spec/rigor/effects/tracer_collection_spec.rb")
    expect(specs).not_to include("spec/rigor/effects/rails_layer_spec.rb")
  end

  it "keeps the basename when no directory names a spec but it is distinctive" do
    ghost = %w[no_such_fixture 3171].join("_")
    specs, uncovered = selection_for("spec/integration/fixtures/#{ghost}/and_assign_narrowing.rb")
    expect(uncovered).to be_empty
    expect(specs).to include("spec/integration/type_construction_spec.rb")
  end

  # The directory match alone left #3171's symptom for the fixture directories no
  # spec names: the stem fallback still ran, and `demo` is the basename of dozens
  # of them, so those kept selecting ~113 files and ~18 minutes.
  it "keeps every demo.rb fixture's selection small" do
    demos = Dir.glob("spec/**/fixtures/**/demo.rb", base: root)
    expect(demos.length).to be > 20
    oversized = demos.filter_map do |path|
      specs, = selection_for(path)
      [path, specs.length] if specs.length > 10
    end
    expect(oversized).to be_empty
  end

  # Its basename is `.rigor.yml`, which 111 specs mention, so the cap refuses it.
  it "selects nothing for a dotfile no directory names" do
    path = "spec/integration/fixtures/.rigor.yml"
    specs, uncovered = selection_for(path)
    expect(specs).to be_empty
    expect(uncovered).to include(path)
  end

  # Round 3: without a boundary the basename matched inside a longer one, so this
  # fixture selected the spec that merely mentions `self_core_prepend.rb`. The
  # directory is a ghost, so the basename route is the one under test. Both
  # parts are assembled, so this file names neither: a directory it named would
  # answer first and the basename would never be reached.
  #
  # The ghost directory also carries no entry file, so this example is what pins
  # the snapshot gate's discriminator: were the gate named for every path under
  # `fixtures/`, rather than only for a flat `.rb` or a directory carrying
  # `demo.rb`, the selection here would not be empty.
  it "does not match a basename inside a longer one" do
    dir = %w[no_such_fixture 3171].join("_")
    base = %w[prepend rb].join(".")
    specs, uncovered = selection_for("spec/integration/fixtures/#{dir}/#{base}")
    expect(specs).to be_empty
    expect(uncovered).not_to be_empty
  end

  # Round 3: these went to zero and were told nothing names them, while their
  # one consumer enumerates the directory and so is named by no rule at all.
  it "runs the snapshot gate for a changed snapshot" do
    specs, uncovered = selection_for("spec/integration/snapshots/always_raises.yml")
    expect(uncovered).to be_empty
    expect(specs).to eq(["spec/integration/precision_snapshot_spec.rb"])
  end

  # Round 4: the basename site was anchored and pinned while its twin at the
  # directory site was not. This ghost directory sits inside a longer real
  # identifier (`self_core_prepend`) and nowhere on its own, so unanchored it
  # selects that spec and suppresses the basename route; anchored, nothing names
  # it. Assembled, so this file carries neither name.
  it "does not match a fixture directory inside a longer identifier" do
    dir = %w[ore prepend].join("_")
    ghost = %w[unique_name 3171].join("_")
    specs, uncovered = selection_for("spec/integration/fixtures/#{dir}/#{ghost}.rb")
    expect(specs).to be_empty
    expect(uncovered).not_to be_empty
  end

  # Round 4, the mirror of the snapshot finding on the fixtures side: both gates
  # take this tree by enumerating it, so no identifier rule reaches either, and
  # a fixture with no golden FAILS. A flat `.rb` is an input to both.
  it "runs the enumerating gates for a flat fixture nothing else names" do
    ghost = %w[unique_name 3171].join("_")
    specs, uncovered = selection_for("spec/integration/fixtures/#{ghost}.rb")
    expect(uncovered).to be_empty
    expect(specs).to eq(["spec/integration/precision_snapshot_spec.rb",
                         "spec/rigor/typing_state_reachability_spec.rb"])
  end

  # A project fixture is an input to the snapshot gate only, which discriminates
  # on the harness entry file; the reachability audit globs the flat `*.rb` only.
  it "runs the snapshot gate for a project fixture, and not the flat-fixture audit" do
    specs, uncovered = selection_for("spec/integration/fixtures/always_raises/demo.rb")
    expect(uncovered).to be_empty
    expect(specs).to include("spec/integration/precision_snapshot_spec.rb")
    expect(specs).not_to include("spec/rigor/typing_state_reachability_spec.rb")
  end

  # The gate hard-codes the entry file name the snapshot gate reads through
  # `FixtureHarness::DEFAULT_ENTRY`; a change there would silently stop the gate
  # naming project fixtures.
  it "hard-codes the entry file name the harness declares" do
    harness = File.read(File.join(root, "spec/integration/support/fixture_harness.rb"))
    entry = harness[/DEFAULT_ENTRY = "(.+)"/, 1]
    expect(entry).to eq("demo.rb")
    expect(File.read(script)).to include("/#{entry}\" ]]")
  end

  it "refuses the stand-in diff outside --list-specs, rather than reporting OK" do
    out, err, status = Bundler.with_unbundled_env do
      Open3.capture3({ "VERIFY_CHANGED_PATHS" => "docs/nonexistent.md" }, script, "HEAD", chdir: root)
    end
    expect(status.exitstatus).to eq(2), "#{out}\n#{err}"
    expect(err).to include("--list-specs only")
  end

  it "refuses an unknown option rather than reading it as a base ref" do
    _, err, status = Bundler.with_unbundled_env { Open3.capture3(script, "--list-spec", chdir: root) }
    expect(status.exitstatus).to eq(2)
    expect(err).to include("unknown option --list-spec")
  end

  it "reports a fixture nothing names instead of selecting silently" do
    dir = %w[no_such_fixture 3171].join("_")
    file = %w[unique_name 3171].join("_")
    path = "spec/integration/fixtures/#{dir}/#{file}.rb"
    specs, uncovered = selection_for(path)
    expect(specs).to be_empty
    expect(uncovered).to include(path)
  end
end
