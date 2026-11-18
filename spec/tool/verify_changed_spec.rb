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

  # Issue #3298 — a script under bin/. The identifier rules match a basename WITH its extension, and a
  # script has none, so `land-pr` could never reach `land_pr_spec.rb`: a change to any such script ran
  # no spec locally and no uncovered line said so. The selection's own script was included in that, which
  # is why this file could not have caught it before. The rule is the specs that NAME the script, not a
  # mirror of its name — the mirror misses a script run only by another's spec, and on this tree it finds
  # nothing the search does not.
  #
  # Every script name below is spelled APART, as the ghost fixture names further down are, because the
  # arm also selects the specs that NAME the script and this file is part of the corpus it greps. Written
  # whole, the `setup` script would select this very file and stop being the uncovered row it is here.
  describe "a script under bin/" do
    def bin(*parts) = "bin/#{parts.join}"

    it "selects the spec of a script that has its own" do
      specs, uncovered = selection_for(bin("land", "-", "pr"))
      expect(uncovered).to be_empty
      expect(specs).to eq(["spec/tool/land_pr_spec.rb", "spec/tool/land_when_green_spec.rb"])
    end

    it "selects this file for a change to the selection's own script" do
      specs, = selection_for(bin("verify", "-", "changed"))
      expect(specs).to include("spec/tool/verify_changed_spec.rb")
    end

    # The `rigor-worktree` script's spec is spec/tool/rigor_worktree_reference_clone_spec.rb, which no
    # mirror of the script's own name reaches. The rule is the specs that name the script, so it does.
    it "selects a spec whose name is not a mirror of the script's" do
      specs, uncovered = selection_for(bin("rigor", "-", "worktree"))
      expect(uncovered).to be_empty
      expect(specs).to eq(["spec/tool/rigor_worktree_reference_clone_spec.rb"])
    end

    # The mirror misses a script that has no spec of its own but is RUN by another's: the `land-pr`
    # script shells out to `ci-required`, and both land_pr_spec and land_when_green_spec drive it for
    # real.
    # Reporting it as uncovered would say CI is the only check where two specs would catch a break.
    it "selects the specs that name a script with no mirror spec of its own" do
      specs, uncovered = selection_for(bin("ci", "-", "required"))
      expect(uncovered).to be_empty
      expect(specs).to eq(["spec/tool/land_pr_spec.rb", "spec/tool/land_when_green_spec.rb"])
    end

    # The other half of the gate: a script no spec names at all is REPORTED, not silently covered.
    it "reports a script no spec names on the uncovered line" do
      specs, uncovered = selection_for(bin("set", "up"))
      expect(specs).to be_empty
      expect(uncovered).to eq([bin("set", "up")])
    end
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
  # directory rule, check_rules.rb selected none of spec/rigor/analysis/check_rules/; it did select them
  # when the rule landed, lost them again when it grew past the old 30-file bound, and since #3289 takes as
  # many as fit a time budget. These examples build their tree and its cost table in a temporary
  # repository rather than lean on a real directory's size or measured costs.
  describe "the directory mirror rule" do
    def spec_files(dir, count, nested: false)
      count.times.to_h { |i| ["#{dir}#{'/deep/er' if nested && i.odd?}/s#{i}_spec.rb", "# spec\n"] }
    end

    # The cost table the script reads, with the given rows ({ path => seconds }).
    def cost_table(rows)
      { "tool/spec_costs.tsv" => "# header\n#{rows.sort.map { |path, seconds| "#{seconds}\t#{path}\n" }.join}" }
    end

    # Every spec of `files` priced at `seconds` in the cost table.
    def priced(files, seconds) = files.merge(cost_table(files.keys.grep(/_spec\.rb\z/).to_h { |path| [path, seconds] }))

    def script_number(name) = Float(File.read(script)[/^#{name}=([\d.]+)$/, 1])

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

    it "selects every spec under the mirror directory when there is no same-named spec" do
      files = priced({ "lib/rigor/a/b.rb" => "" }.merge(spec_files("spec/rigor/a/b", 6, nested: true)), 0.01)
      [false, true].each do |quick|
        specs, = list_in_temp_repo(files, "lib/rigor/a/b.rb", quick: quick)
        expect(specs).to match_array(files.keys.grep(%r{\Aspec/}).sort), "quick=#{quick}"
      end
    end

    it "does not pull in a sibling module's directory" do
      files = priced({ "lib/rigor/a/b.rb" => "" }.merge(spec_files("spec/rigor/a/b", 2))
                                                 .merge(spec_files("spec/rigor/a/c", 2)), 0.01)
      specs, = list_in_temp_repo(files, "lib/rigor/a/b.rb", quick: true)
      expect(specs).not_to be_empty
      expect(specs.grep(%r{\Aspec/rigor/a/(?!b/)})).to be_empty
    end

    # The bound is estimated time (#3289), on a temporary repository so the costs
    # are exact. It replaced a 30-file count, which dropped a cheap directory whole
    # once it grew and kept a dear one that stayed small.
    describe "its time budget" do
      [false, true].each do |quick|
        context "with quick=#{quick}" do
          let(:budget) { script_number(quick ? "mirror_dir_budget_quick" : "mirror_dir_budget_default") }

          it "selects nothing for the unit-spec root" do
            files = { "lib/rigor.rb" => "", "spec/rigor/a_spec.rb" => "# spec\n" }
            specs, err = list_in_temp_repo(files, "lib/rigor.rb", quick: quick)
            expect(specs).to be_empty
            expect(err).not_to include("budget")
          end

          # Sixty files, twice the old count bound, cost next to nothing.
          it "selects every spec of a cheap directory however many files it holds, nested ones included" do
            files = priced({ "lib/rigor/mod.rb" => "" }.merge(spec_files("spec/rigor/mod", 60, nested: true)), 0.01)
            specs, err = list_in_temp_repo(files, "lib/rigor/mod.rb", quick: quick)
            expect(specs.length).to eq(60)
            expect(specs.grep(%r{/deep/er/}).length).to eq(30)
            expect(err).not_to include("budget")
          end

          it "takes the cheapest specs that fit and names the rest with the command that runs them" do
            files = { "lib/rigor/mod.rb" => "" }.merge(spec_files("spec/rigor/mod", 4))
            files.merge!(cost_table("spec/rigor/mod/s0_spec.rb" => (budget * 0.5).round(2),
                                    "spec/rigor/mod/s1_spec.rb" => (budget * 0.4).round(2),
                                    "spec/rigor/mod/s2_spec.rb" => (budget * 0.3).round(2),
                                    "spec/rigor/mod/s3_spec.rb" => 0.01))
            specs, err = list_in_temp_repo(files, "lib/rigor/mod.rb", quick: quick)
            expect(specs).to eq(%w[spec/rigor/mod/s1_spec.rb spec/rigor/mod/s2_spec.rb spec/rigor/mod/s3_spec.rb])
            shown = budget.to_s.delete_suffix(".0")
            expect(err).to include("  - spec/rigor/mod/ (4 specs, ~#{(budget * 1.2).round}s estimated, " \
                                   "over the #{shown}s mirror-directory budget; cheapest first, " \
                                   "1 left out — run them with: bundle exec rspec spec/rigor/mod/s0_spec.rb)")
          end

          # Ties go by path, and a spec the table does not list is charged the default.
          it "charges an unlisted spec the default cost and breaks ties by path" do
            default = script_number("spec_cost_default")
            fits = (budget / default).floor
            files = { "lib/rigor/mod.rb" => "" }.merge(spec_files("spec/rigor/mod", fits + 2))
            specs, err = list_in_temp_repo(files, "lib/rigor/mod.rb", quick: quick)
            expected = (0...(fits + 2)).map { |i| "spec/rigor/mod/s#{i}_spec.rb" }.sort
            expect(specs).to eq(expected.first(fits))
            expect(err).to include("#{expected.last(2).join(' ')})")
          end

          it "does not report a left-out spec that another rule selected" do
            files = { "lib/rigor/mod.rb" => "" }.merge(spec_files("spec/rigor/mod", 2))
                                                .merge(cost_table("spec/rigor/mod/s0_spec.rb" => budget * 2,
                                                                  "spec/rigor/mod/s1_spec.rb" => 0.01))
            specs, err = list_in_temp_repo(files, "lib/rigor/mod.rb\nspec/rigor/mod/s0_spec.rb", quick: quick)
            expect(specs).to eq(%w[spec/rigor/mod/s0_spec.rb spec/rigor/mod/s1_spec.rb])
            expect(err).not_to include("budget")
          end

          it "applies to a tool/ file's mirror directory" do
            files = priced({ "tool/x.rb" => "" }.merge(spec_files("spec/tool/x", 2)), 0.01)
            specs, = list_in_temp_repo(files, "tool/x.rb", quick: quick)
            expect(specs).to eq(["spec/tool/x/s0_spec.rb", "spec/tool/x/s1_spec.rb"])
          end

          # A deleted or renamed spec leaves its row behind until the next refresh;
          # no lookup reaches it, so it changes nothing and warns about nothing.
          it "ignores a row naming a spec that no longer exists" do
            files = { "lib/rigor/mod.rb" => "" }.merge(spec_files("spec/rigor/mod", 1))
                                                .merge(cost_table("spec/rigor/mod/s0_spec.rb" => 0.01,
                                                                  "spec/rigor/mod/gone_spec.rb" => budget * 5))
            specs, err = list_in_temp_repo(files, "lib/rigor/mod.rb", quick: quick)
            expect(specs).to eq(["spec/rigor/mod/s0_spec.rb"])
            expect(err).not_to include("spec_costs.tsv")
          end

          it "adds the directory to a same-named spec" do
            files = priced({ "lib/rigor/mod.rb" => "", "spec/rigor/mod_spec.rb" => "# spec\n" }
                    .merge(spec_files("spec/rigor/mod", 2)), 0.01)
            specs, err = list_in_temp_repo(files, "lib/rigor/mod.rb", quick: quick)
            expect(specs).to eq(%w[spec/rigor/mod/s0_spec.rb spec/rigor/mod/s1_spec.rb
                                   spec/rigor/mod_spec.rb])
            expect(err).not_to include("budget")
          end

          # The same-named spec runs whatever it costs, so it is charged first: `cli_spec.rb`
          # alone takes minutes, and an uncharged one let `--quick` for cli.rb run for four.
          it "charges the same-named spec first, always runs it, and gives the directory what it leaves" do
            files = { "lib/rigor/mod.rb" => "", "spec/rigor/mod_spec.rb" => "# spec\n" }
                    .merge(spec_files("spec/rigor/mod", 2))
            files.merge!(cost_table("spec/rigor/mod_spec.rb" => (budget * 0.4).round(2),
                                    "spec/rigor/mod/s0_spec.rb" => (budget * 0.05).round(2),
                                    "spec/rigor/mod/s1_spec.rb" => (budget * 0.6).round(2)))
            specs, err = list_in_temp_repo(files, "lib/rigor/mod.rb", quick: quick)
            expect(specs).to eq(%w[spec/rigor/mod/s0_spec.rb spec/rigor/mod_spec.rb])
            expect(err).to include("budget less ~#{(budget * 0.4).round}s for spec/rigor/mod_spec.rb; " \
                                   "cheapest first, 1 left out — run them with: " \
                                   "bundle exec rspec spec/rigor/mod/s1_spec.rb)")
          end

          # Past half the budget the run is over budget anyway; charging the spec whole
          # dropped a cheap directory whole (runner/: 11 specs, ~4 s, behind a ~33 s
          # runner_spec). The directory keeps at least half.
          it "charges the same-named spec at most half the budget, and says when it alone is over the budget" do
            files = { "lib/rigor/mod.rb" => "", "spec/rigor/mod_spec.rb" => "# spec\n" }
                    .merge(spec_files("spec/rigor/mod", 3))
            files.merge!(cost_table("spec/rigor/mod_spec.rb" => budget * 3,
                                    "spec/rigor/mod/s0_spec.rb" => (budget * 0.2).round(2),
                                    "spec/rigor/mod/s1_spec.rb" => (budget * 0.2).round(2),
                                    "spec/rigor/mod/s2_spec.rb" => (budget * 0.2).round(2)))
            specs, err = list_in_temp_repo(files, "lib/rigor/mod.rb", quick: quick)
            expect(specs).to eq(%w[spec/rigor/mod/s0_spec.rb spec/rigor/mod/s1_spec.rb spec/rigor/mod_spec.rb])
            expect(err).to include("budget less ~#{(budget / 2).round}s for spec/rigor/mod_spec.rb, which alone is " \
                                   "estimated at ~#{(budget * 3).round}s, so this run takes at least that long; " \
                                   "cheapest first, 1 left out — run them with: " \
                                   "bundle exec rspec spec/rigor/mod/s2_spec.rb)")
          end
        end
      end

      # The default tier is the pre-push gate and spends more: a spec that fits its
      # budget and not the edit loop's runs before a push and is named in --quick.
      it "gives the default tier the larger budget" do
        quick_budget = script_number("mirror_dir_budget_quick")
        full_budget = script_number("mirror_dir_budget_default")
        expect(full_budget).to be > quick_budget
        between = (quick_budget + full_budget) / 2
        files = { "lib/rigor/mod.rb" => "" }.merge(spec_files("spec/rigor/mod", 1))
                                            .merge(cost_table("spec/rigor/mod/s0_spec.rb" => between))
        full, = list_in_temp_repo(files, "lib/rigor/mod.rb", quick: false)
        quick, err = list_in_temp_repo(files, "lib/rigor/mod.rb", quick: true)
        expect(full).to eq(["spec/rigor/mod/s0_spec.rb"])
        expect(quick).to be_empty
        expect(err).to include("bundle exec rspec spec/rigor/mod/s0_spec.rb")
      end
    end

    # The table only orders and bounds the selection, so a broken one never fails
    # the gate; but it must not change the selection silently either. Each case
    # warns on stderr and prices what it cannot read at the default.
    describe "a cost table it cannot fully read" do
      let(:budget) { script_number("mirror_dir_budget_quick") }
      let(:default) { script_number("spec_cost_default") }
      let(:tree) { { "lib/rigor/mod.rb" => "" }.merge(spec_files("spec/rigor/mod", 2)) }
      let(:dear) { "spec/rigor/mod/s0_spec.rb" }
      let(:cheap) { "spec/rigor/mod/s1_spec.rb" }

      def table(text) = { "tool/spec_costs.tsv" => text }

      it "warns when the table is missing, and prices every spec at the default" do
        specs, err = list_in_temp_repo(tree, "lib/rigor/mod.rb", quick: true)
        expect(err).to include("verify-changed: tool/spec_costs.tsv is missing; " \
                               "every mirror-directory spec is priced at the default " \
                               "#{default.to_s.delete_suffix('.0')}s")
        expect(specs).to eq([dear, cheap].first((budget / default).floor))
      end

      it "warns when the table has no usable row" do
        _, err = list_in_temp_repo(tree.merge(table("# only a header\n\n")), "lib/rigor/mod.rb", quick: true)
        expect(err).to include("verify-changed: tool/spec_costs.tsv has no usable row")
      end

      it "reads a table written with CRLF line ends as if it had LF" do
        text = "# header\r\n#{budget * 2}\t#{dear}\r\n0.01\t#{cheap}\r\n"
        specs, err = list_in_temp_repo(tree.merge(table(text)), "lib/rigor/mod.rb", quick: true)
        expect(specs).to eq([cheap])
        expect(err).not_to include("spec_costs.tsv")
      end

      it "prices a non-numeric cost at the default and names the row" do
        text = "# header\nslow\t#{dear}\n0.01\t#{cheap}\n"
        _, err = list_in_temp_repo(tree.merge(table(text)), "lib/rigor/mod.rb", quick: true)
        expect(err).to include("verify-changed: tool/spec_costs.tsv line 2 (slow\t#{dear}) is not")
        expect(err).to include("its spec is priced at the default")
      end

      # Read as written, a negative cost would make its spec free and let the next one in too.
      it "prices a negative cost at the default and names the row" do
        text = "# header\n-#{budget * 2}\t#{dear}\n#{budget - 0.5}\t#{cheap}\n"
        specs, err = list_in_temp_repo(tree.merge(table(text)), "lib/rigor/mod.rb", quick: true)
        expect(err).to include("tool/spec_costs.tsv line 2 (-#{budget * 2}\t#{dear}) is not")
        expect(specs).to eq([dear])
      end
    end

    it "selects the cost table's own gate and this file for a changed cost table" do
      specs, uncovered = selection_for("tool/spec_costs.tsv", quick: true)
      expect(uncovered).to be_empty
      expect(specs).to eq(%w[spec/tool/spec_costs_spec.rb spec/tool/verify_changed_spec.rb])
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
      # The mirror spec and the specs named for the modules under `statement_evaluator/`.
      expect(quick).to eq(%w[spec/rigor/inference/statement_evaluator/def_arguments_and_assertions_spec.rb
                             spec/rigor/inference/statement_evaluator/pattern_bindings_spec.rb
                             spec/rigor/inference/statement_evaluator_spec.rb])
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
