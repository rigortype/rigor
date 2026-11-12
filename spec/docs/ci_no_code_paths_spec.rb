# frozen_string_literal: true

# Guard for the `changes` job in `.github/workflows/ci.yml`: a pull request that changes only the paths
# `skip_re` matches skips the code suite (RSpec, self-check, lint, the RBS matrix) and runs this `spec/docs/`
# directory alone. That is safe only while the Ruby suite and the linters never read those paths, so a tracked
# file they would read must not land in the skipped set. The check runs the workflow's own `skip_re` assignments
# (everything from the first `skip_re=` to `non_code=`, so a `skip_re+=` line counts too) through bash over
# `git ls-files -z`, so the list it guards cannot drift from the one CI uses and every tracked path reaches the
# guard as its exact byte name — plain `git ls-files` quotes non-ASCII paths, and a quoted name matches none of
# the anchors (#3060). It also checks that the `push` trigger's `paths-ignore` skips nothing the PR-side list
# would run.
#
# The read check is an exclusion list, not a directory list: every tracked path counts as read unless it is a
# `.sh` outside the source trees or matches CI_NO_CODE_UNREAD, so a new `skip_re` term for a path the suite
# could read fails here until the path is added to that list on purpose, with its reason.
#
# Markdown is exempt from the read check, and that is a known gap, not a claim that nothing reads it: the specs
# `spec/rigor/analysis/check_rules/deprecated_ruby2_keywords_spec.rb`, `spec/rigor/cli/skill_command_spec.rb` and
# `spec/rigor/cli/docs_command_spec.rb` read `docs/manual`, `docs/handbook` and `skills/` Markdown, and a
# Markdown-only PR skips them. The `\.md` skip predates this spec; see #3050.
require "spec_helper"
require "open3"
require "tmpdir"
require "yaml"

CI_NO_CODE_REPO_ROOT = File.expand_path("../..", __dir__)
CI_NO_CODE_WORKFLOW = File.join(CI_NO_CODE_REPO_ROOT, ".github", "workflows", "ci.yml")

# A spec run from inside a git hook inherits GIT_DIR & friends, which would point the child `git` at the hook's
# repository — and `git add` in a temporary repo would write to the real index. Unset them for every call.
CI_NO_CODE_GIT_ENV = { "GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_INDEX_FILE" => nil }.freeze

# `.sh` files under these directories can be fixtures a spec reads; anywhere else a shell script is run by a
# workflow or a developer and never opened by the suite.
CI_NO_CODE_SH_SOURCE_DIRS = %w[spec/ lib/ sig/ exe/ plugins/ examples/ bin/ schemas/ data/].freeze

# The tracked paths `skip_re` may skip: nothing the code suite, `make lint` or the packaged gem opens them.
# `spec/docs/` does read a few of them, but the docs-check job runs `spec/docs/` even when the code suite is
# skipped, so the read is still covered. Each entry carries its reason. Anything else tracked — `docs/`,
# `skills/`, `agents/`, `.claude/`, `tool/` and whatever comes next — counts as read.
CI_NO_CODE_UNREAD = [
  # vscode-extension.yml builds and tests the extension; `spec/docs/` reads `editors/` files and still runs
  # through the docs-check job on no-code PRs.
  %r{\Aeditors/},
  # Only oss-sweep.yml reads the sweep corpus.
  %r{\Adata/oss-sweep/},
  # Steep and Sorbet bundles that no CI job runs.
  %r{\Atool/(?:steep|sorbet)/},
  # container.yml builds the image.
  /\ADockerfile(?:\.dockerignore)?\z/,
  # playground-wasm.yml builds the frontend and wasm pages that fly.io deploys.
  %r{\Aapps/rigor-playground/(?:frontend/[^/]*\.html|frontend/_(?:headers|redirects)|fly\.toml|Dockerfile)\z},
  %r{\Aapps/rigor-playground/wasm/.*\.(?:html|mjs|json)\z},
  # Each of these workflows has its own trigger; `spec/docs/`'s link check reads `.github/workflows/*.yml` and
  # still runs through the docs-check job on no-code PRs. The list mirrors `skip_re`'s workflow term exactly, so
  # a workflow added there fails this guard until it is exempted here on purpose. ci.yml is absent on purpose:
  # this spec and the link check read it, and changing it must run the suite.
  %r{\A\.github/workflows/(?:vscode-extension|playground-wasm|container|oss-sweep)\.yml\z},
  %r{\A\.github/workflows/(?:ruby-next|engine-warm|engine-wall|release-gate)\.yml\z}
].freeze

RSpec.describe "CI no-code path list (ci.yml `skip_re`)" do
  # `git ls-files -z` hands every tracked path over as its exact byte name; the default quoting would return
  # `"na\303\257ve.json"` for a non-ASCII path, which matches none of the anchors (#3060). Binary strings keep
  # byte-exact names safe to match: a name that is not valid UTF-8 would make a UTF-8-tagged string raise on
  # `match?`.
  def tracked_files(root = CI_NO_CODE_REPO_ROOT)
    out, err, status = Open3.capture3(CI_NO_CODE_GIT_ENV, "git", "ls-files", "-z", chdir: root)
    raise "`git ls-files -z` failed in #{root} (exit #{status.exitstatus}): #{err.strip}" unless status.success?

    out.b.split("\0")
  end

  def repo_files
    @repo_files ||= tracked_files
  end

  def git!(dir, *args)
    _out, err, status = Open3.capture3(CI_NO_CODE_GIT_ENV, "git", *args, chdir: dir)
    raise "git #{args.join(' ')} failed in #{dir} (exit #{status.exitstatus}): #{err.strip}" unless status.success?
  end

  # The workflow's own `skip_re=` ... `non_code=` assignments.
  def skip_re_block
    block = File.read(CI_NO_CODE_WORKFLOW)[/^\s*skip_re=.*?(?=^\s*non_code=)/m]
    raise "no `skip_re=` ... `non_code=` block in #{CI_NO_CODE_WORKFLOW}" unless block

    block
  end

  # The assignments evaluated by bash over `files`, so a `+=` or a reordering is honoured.
  def skipped_by_block(block, files)
    out, err, status = Open3.capture3("bash", "-c", "#{block}\ngrep -E \"$skip_re\" || true",
                                      stdin_data: files.join("\n"))
    return out.b.split("\n") if status.success?

    raise "evaluating `skip_re` through bash failed (exit #{status.exitstatus}): #{err.strip}"
  end

  def skipped_paths
    @skipped_paths ||= skipped_by_block(skip_re_block, repo_files)
  end

  # What the guard reports: skipped paths the suite, a linter or the packaged gem would read. Markdown is
  # exempt (the `\.md` skip predates this spec; see #3050).
  def read_but_skipped(block, files)
    skipped_by_block(block, files).reject { |path| path.end_with?(".md") }.select { |path| reads_it?(path) }
  end

  # Every tracked path counts as read unless it is a `.sh` outside the source trees or matches
  # CI_NO_CODE_UNREAD.
  def reads_it?(path)
    return false if path.end_with?(".sh") && CI_NO_CODE_SH_SOURCE_DIRS.none? { |dir| path.start_with?(dir) }

    CI_NO_CODE_UNREAD.none? { |re| re.match?(path) }
  end

  before do
    skip "not a git checkout" unless File.exist?(File.join(CI_NO_CODE_REPO_ROOT, ".git"))
  end

  it "matches what it should and never matches ci.yml (guards an extraction that yields nothing)" do
    expect(skipped_paths).to include("editors/vscode/package.json")
    expect(skipped_paths).not_to include(".github/workflows/ci.yml")
  end

  it "hands every tracked path to the guard as its exact byte name" do
    Dir.mktmpdir do |dir|
      git!(dir, "init", "--quiet")
      File.write(File.join(dir, "naïve.json"), "{}")
      git!(dir, "add", "--", "naïve.json")

      expect(tracked_files(dir)).to include("naïve.json".b)
    end
  end

  it "fails with the command, exit status and stderr when git fails" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".git"), "gitdir: /nonexistent-3060\n")

      expect { tracked_files(dir) }
        .to raise_error(/`git ls-files -z` failed in .* \(exit 128\): fatal: /)
    end
  end

  it "fails with the command and stderr when bash cannot evaluate skip_re" do
    expect { skipped_by_block("skip_re='unterminated", []) }
      .to raise_error(/evaluating `skip_re` through bash failed \(exit 2\): bash: -c:/)
  end

  # #3060 — the read check used to be a hand-kept directory list, so a tracked path under docs/, skills/,
  # agents/, .claude/ or tool/ that a suite file reads passed silently once a skip_re term matched it.
  it "flags a skipped path the suite reads wherever it sits, not only under the old directory list" do
    files = %w[docs/foo.json spec/x_spec.rb]

    expect(read_but_skipped("skip_re='^docs/'", files)).to eq(["docs/foo.json"])
  end

  it "skips no file the suite, a linter or the packaged gem would read, apart from Markdown" do
    escaped = read_but_skipped(skip_re_block, repo_files)

    expect(escaped).to be_empty, <<~MESSAGE
      These tracked files match `skip_re` in .github/workflows/ci.yml but are read by the Ruby suite, `make lint` or
      the packaged gem, so a pull request touching only them would skip the suite:
      #{escaped.map { |path| "  #{path}" }.join("\n")}
      Narrow `skip_re` (and the `push` trigger's `paths-ignore`), move the file, or — if nothing reads it —
      add it to CI_NO_CODE_UNREAD in this spec with the reason.
    MESSAGE
  end

  it "skips no Ruby source, which `make lint` and the self-check would otherwise miss" do
    ruby_files = skipped_paths.grep(/\.rb\z/)

    expect(ruby_files).to be_empty, <<~MESSAGE
      These Ruby files match `skip_re` in .github/workflows/ci.yml, so a change to them runs no lint or self-check:
      #{ruby_files.map { |path| "  #{path}" }.join("\n")}
    MESSAGE
  end

  it "decides on skip_re alone: one `non_code=` that is exactly `grep -vE \"$skip_re\"`" do
    # The guard evaluates the `skip_re` assignments, not the line that uses them, so a second filter there
    # (`grep -vE "$skip_re|^lib/"`, or a later `non_code=` rewrite) would skip the suite unseen.
    lines = File.readlines(CI_NO_CODE_WORKFLOW).grep(/^\s*non_code=/).map(&:strip)

    expect(lines.size).to eq(1)
    expect(lines.first).to end_with('| grep -vE "$skip_re" || true)')
    expect(lines.first).to eq(%q{non_code=$(printf '%s\n' "$changed" | grep -vE "$skip_re" || true)})
  end

  it "keeps the push trigger's paths-ignore inside the PR-side skip list" do
    workflow = YAML.load_file(CI_NO_CODE_WORKFLOW)
    globs = (workflow["on"] || workflow[true]).dig("push", "paths-ignore")
    expect(globs).not_to be_empty

    flags = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH
    # With FNM_PATHNAME a trailing `dir/**` matches only direct children, but GitHub's matches the whole subtree.
    globs = globs.map { |glob| glob.sub(%r{/\*\*\z}, "/**/*") }
    ignored = repo_files.select { |path| globs.any? { |glob| File.fnmatch(glob, path, flags) } }
    run_on_push_only = ignored - skipped_paths

    expect(run_on_push_only).to be_empty, <<~MESSAGE
      These tracked files are ignored by the `push` trigger's `paths-ignore` in .github/workflows/ci.yml but would
      still run the suite in a pull request (`skip_re` does not match them). Keep the two lists in step:
      #{run_on_push_only.map { |path| "  #{path}" }.join("\n")}
    MESSAGE
  end
end
