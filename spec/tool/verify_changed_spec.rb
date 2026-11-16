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
require "fileutils"
require "open3"
require "tmpdir"
require "spec_helper"

RSpec.describe "bin/verify-changed spec selection" do
  let(:script) { File.expand_path("../../bin/verify-changed", __dir__) }
  let(:root) { File.expand_path("../..", __dir__) }

  # A GIT_DIR-free environment, so a temporary repository cannot reach this one.
  def clean_env
    ENV.keys.grep(/\AGIT_/).to_h { |key| [key, nil] }.merge("VERIFY_BASE" => nil, "VERIFY_CHANGED_PATHS" => nil)
  end

  # Yields a committed temporary repository holding the script and `files`.
  def with_temp_repo(files)
    Dir.mktmpdir("verify-changed-spec") do |dir|
      FileUtils.mkdir_p(File.join(dir, "bin"))
      FileUtils.cp(script, File.join(dir, "bin/verify-changed"))
      files.each do |path, text|
        FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
        File.write(File.join(dir, path), text)
      end
      git = ["git", "-c", "user.name=t", "-c", "user.email=t@t.invalid", "-c", "commit.gpgsign=false"]
      [["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "x"]].each do |cmd|
        _, err, status = Open3.capture3(clean_env, *git, *cmd, chdir: dir)
        raise err unless status.success?
      end
      yield dir
    end
  end

  # [selected spec paths, uncovered fixture paths] for the given changed paths.
  def selection_for(*paths, quick: false)
    env = { "VERIFY_CHANGED_PATHS" => paths.join("\n") }
    args = ["HEAD", *("--quick" if quick), "--list-specs"]
    out, err, status = Bundler.with_unbundled_env do
      Open3.capture3(env, script, *args, chdir: root)
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
    # Round 4: once a directory has matched, the basename route must not also
    # run. `loud.rb` is the basename of fixtures in other trees, so without that
    # guard it adds this non-reader on top of the precise selection.
    expect(specs).not_to include("spec/integration/refinement_using_scope_spec.rb")
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

  # #3277: a module with a spec directory and no same-named spec. Before the
  # directory rule, check_rules.rb selected none of spec/rigor/analysis/check_rules/.
  describe "the directory mirror rule" do
    it "selects every spec under the mirror directory when there is no same-named spec" do
      expect(File.exist?(File.join(root, "spec/rigor/analysis/check_rules_spec.rb"))).to be(false)
      expected = Dir.glob("spec/rigor/analysis/check_rules/**/*_spec.rb", base: root)
      expect(expected.length).to be > 5
      [false, true].each do |quick|
        specs, = selection_for("lib/rigor/analysis/check_rules.rb", quick: quick)
        expect(specs).to include(*expected), "quick=#{quick}"
      end
    end

    it "does not pull in a sibling module's directory" do
      specs, = selection_for("lib/rigor/analysis/check_rules.rb", quick: true)
      expect(specs.grep(%r{\Aspec/rigor/analysis/(?!check_rules/)})).to be_empty
    end

    # The bound, on a temporary repository so the counts are exact: the real
    # directories drift (cli 49, check_rules 21 at the time of writing).
    describe "its bound" do
      def spec_files(dir, count, nested: false)
        count.times.to_h { |i| ["#{dir}#{'/deep/er' if nested && i.odd?}/s#{i}_spec.rb", "# spec\n"] }
      end

      def list_in_temp_repo(files, path, quick:)
        with_temp_repo(files) do |dir|
          env = { "VERIFY_CHANGED_PATHS" => path }
          args = ["HEAD", *("--quick" if quick), "--list-specs"]
          out, err, status = Open3.capture3(clean_env.merge(env), "bin/verify-changed", *args, chdir: dir)
          expect(status.exitstatus).to eq(0), err
          # The default tier also names the drift specs, which this repository lacks.
          [out.lines.map(&:strip).reject(&:empty?).select { |spec| File.exist?(File.join(dir, spec)) }, err]
        end
      end

      [false, true].each do |quick|
        context "with quick=#{quick}" do
          it "selects nothing for the unit-spec root" do
            files = { "lib/rigor.rb" => "", "spec/rigor/a_spec.rb" => "# spec\n" }
            specs, err = list_in_temp_repo(files, "lib/rigor.rb", quick: quick)
            expect(specs).to be_empty
            expect(err).not_to include("bound")
          end

          it "selects every spec of a directory at the bound, nested ones included" do
            files = { "lib/rigor/mod.rb" => "" }.merge(spec_files("spec/rigor/mod", 30, nested: true))
            specs, err = list_in_temp_repo(files, "lib/rigor/mod.rb", quick: quick)
            expect(specs.length).to eq(30)
            expect(specs.grep(%r{/deep/er/}).length).to eq(15)
            expect(err).not_to include("bound")
          end

          it "selects none from a directory over the bound and says so, naming the directory and the count" do
            files = { "lib/rigor/mod.rb" => "" }.merge(spec_files("spec/rigor/mod", 31, nested: true))
            specs, err = list_in_temp_repo(files, "lib/rigor/mod.rb", quick: quick)
            expect(specs).to be_empty
            expect(err).to include("spec/rigor/mod/ (31 specs")
            expect(err).to include("run the ones your change touches yourself")
          end

          it "applies to a tool/ file's mirror directory" do
            files = { "tool/x.rb" => "" }.merge(spec_files("spec/tool/x", 2))
            specs, = list_in_temp_repo(files, "tool/x.rb", quick: quick)
            expect(specs).to eq(["spec/tool/x/s0_spec.rb", "spec/tool/x/s1_spec.rb"])
          end

          it "adds the directory to a same-named spec" do
            files = { "lib/rigor/mod.rb" => "", "spec/rigor/mod_spec.rb" => "# spec\n" }
                    .merge(spec_files("spec/rigor/mod", 2))
            specs, = list_in_temp_repo(files, "lib/rigor/mod.rb", quick: quick)
            expect(specs).to include("spec/rigor/mod_spec.rb", "spec/rigor/mod/s0_spec.rb", "spec/rigor/mod/s1_spec.rb")
          end
        end
      end
    end

    it "selects nothing for a path with no spec and no spec directory" do
      specs, = selection_for("lib/rigor/zz_no_such_module_3277.rb", quick: true)
      expect(specs).to be_empty
    end
  end

  # #3277: the quick tier is the edit-loop check; the default mode keeps every
  # selection it had.
  describe "--quick" do
    let(:engine_path) { "lib/rigor/inference/statement_evaluator.rb" }
    let(:drift) do
      %w[spec/integration/precision_snapshot_spec.rb spec/rigor/public_api_drift_spec.rb
         spec/rigor/sig_gen/provenance_spec.rb spec/rigor/scope/ancestry_walker_detection_spec.rb]
    end

    it "selects only the mirror spec for an engine path, where the default adds the drift set" do
      quick, = selection_for(engine_path, quick: true)
      expect(quick).to eq(["spec/rigor/inference/statement_evaluator_spec.rb"])
      full, = selection_for(engine_path)
      expect(full).to include("spec/rigor/inference/statement_evaluator_spec.rb", *drift)
    end

    it "omits the incremental not-re-checked specs that a dependency-recording edit adds by default" do
      path = "lib/rigor/analysis/dependency_recorder.rb"
      quick, = selection_for(path, quick: true)
      full, = selection_for(path)
      incremental = full.grep(/incremental/)
      expect(incremental).not_to be_empty
      expect(quick.grep(/incremental/)).to be_empty
    end

    it "still runs a changed spec file" do
      spec = "spec/rigor/inference/statement_evaluator_spec.rb"
      quick, = selection_for(spec, quick: true)
      expect(quick).to eq([spec])
    end

    it "keeps the fixture selection, and drops only the two all-plugin conformance specs for a plugin" do
      path = "spec/integration/fixtures/and_assign_narrowing.rb"
      expect(selection_for(path, quick: true)).to eq(selection_for(path))
      plugin = Dir.glob("plugins/rigor-*/lib/**/*.rb", base: root).first
      quick, = selection_for(plugin, quick: true)
      full, = selection_for(plugin)
      conformance = %w[spec/integration/all_plugins_load_spec.rb spec/integration/plugin_contract_conformance_spec.rb]
      expect(full).to include(*conformance)
      expect(quick).not_to include(*conformance)
      expect(quick).to eq(full - conformance)
    end

    # A real run in a throwaway repository: with nothing changed it executes only
    # the whitespace checks, so no rspec or RuboCop starts.
    it "runs, labels itself the edit-loop tier, lists what it adds none of, and fails when a check fails" do
      with_temp_repo({}) do |dir|
        run = lambda do
          Open3.capture3(clean_env, "bin/verify-changed", "--quick", "HEAD", chdir: dir)
        end
        out, err, status = run.call
        expect(status.exitstatus).to eq(0), "#{out}\n#{err}"
        expect(out).to include("verify-changed --quick: the EDIT-LOOP tier, not the pre-push gate.")
        expect(out).to include("adds none of these on its own")
        %w[drift pinned incremental spec/docs/ self-check conformance].each { |word| expect(out).to include(word) }
        expect(out).to include("run `make verify-changed` before pushing.")
        expect(out).to include("the checks it ran passed. Not the pre-push gate.")
        expect(out).not_to include("verify-changed: OK.")

        File.write(File.join(dir, "bad.txt"), "trailing \n")
        out, err, status = run.call
        expect(status.exitstatus).to eq(1), "#{out}\n#{err}"
        expect(out).to include("verify-changed: FAILED")
        expect(out).to include("whitespace (untracked files)")
        expect(out).to include("run `make verify-changed` before pushing.")
        expect(out).not_to include("the checks it ran passed")
      end
    end

    it "is not accepted or forwarded by bin/lane-push" do
      expect(File.read(File.join(root, "bin/lane-push"))).not_to include("--quick")
    end

    it "still refuses the stand-in diff outside --list-specs" do
      _, err, status = Bundler.with_unbundled_env do
        Open3.capture3({ "VERIFY_CHANGED_PATHS" => "docs/nonexistent.md" }, script, "HEAD", "--quick", chdir: root)
      end
      expect(status.exitstatus).to eq(2)
      expect(err).to include("--list-specs only")
    end
  end
end
