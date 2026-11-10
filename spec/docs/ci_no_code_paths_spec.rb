# frozen_string_literal: true

# Guard for the `changes` job in `.github/workflows/ci.yml`: a pull request that changes only the paths
# `skip_re` matches skips the code suite (RSpec, self-check, lint, the RBS matrix) and runs this `spec/docs/`
# directory alone. That is safe only while the Ruby suite and the linters never read those paths, so a tracked
# file they would read must not land in the skipped set. The check runs the workflow's own `skip_re` assignments
# (everything from the first `skip_re=` to `non_code=`, so a `skip_re+=` line counts too) through bash over
# `git ls-files`, so the list it guards cannot drift from the one CI uses. It also checks that the `push`
# trigger's `paths-ignore` skips nothing the PR-side list would run.
#
# Markdown is exempt from the read check, and that is a known gap, not a claim that nothing reads it: the specs
# `spec/rigor/analysis/check_rules/deprecated_ruby2_keywords_spec.rb`, `spec/rigor/cli/skill_command_spec.rb` and
# `spec/rigor/cli/docs_command_spec.rb` read `docs/manual`, `docs/handbook` and `skills/` Markdown, and a
# Markdown-only PR skips them. The `\.md` skip predates this spec; see #3050.
require "spec_helper"
require "open3"
require "yaml"
require "rubygems"

CI_NO_CODE_REPO_ROOT = File.expand_path("../..", __dir__)
CI_NO_CODE_WORKFLOW = File.join(CI_NO_CODE_REPO_ROOT, ".github", "workflows", "ci.yml")

# Directories the Ruby suite, `make lint`, an analysis or the packaged gem read. `data/oss-sweep/` is the one
# tooling-only subtree and is allowed to be skipped.
CI_NO_CODE_READ_DIRS = %w[spec/ lib/ sig/ exe/ plugins/ examples/ bin/ schemas/ data/].freeze
CI_NO_CODE_TOOLING_ONLY = ["data/oss-sweep/"].freeze
# Root files that configure the suite, the linters, the bundle or the gem.
CI_NO_CODE_ROOT_FILES = %w[
  .rubocop.yml .rspec .ruby-version .rigor.dist.yml binpacker.yml Gemfile Gemfile.lock Rakefile Makefile Steepfile
].freeze
# Ruby that `make lint` reaches through `apps/` without a `.rb` extension.
CI_NO_CODE_APPS_RUBY = %r{\Aapps/.*(\.rb|\.gemspec|/Gemfile|/Rakefile|/config\.ru)\z}

RSpec.describe "CI no-code path list (ci.yml `skip_re`)" do
  def tracked_files
    out, status = Open3.capture2("git", "ls-files", chdir: CI_NO_CODE_REPO_ROOT)
    raise "git ls-files failed" unless status.success?

    out.split("\n")
  end

  # The workflow's own assignments, evaluated by bash over `files`, so a `+=` or a reordering is honoured.
  def skipped_by_workflow(files)
    text = File.read(CI_NO_CODE_WORKFLOW)
    block = text[/^\s*skip_re=.*?(?=^\s*non_code=)/m]
    raise "no `skip_re=` ... `non_code=` block in #{CI_NO_CODE_WORKFLOW}" unless block

    out, status = Open3.capture2("bash", "-c", "#{block}\ngrep -E \"$skip_re\" || true", stdin_data: files.join("\n"))
    raise "bash failed evaluating skip_re" unless status.success?

    out.split("\n")
  end

  def skipped_paths
    @skipped_paths ||= skipped_by_workflow(tracked_files)
  end

  def reads_it?(path)
    return true if CI_NO_CODE_ROOT_FILES.include?(path) || (path.end_with?(".gemspec") && !path.include?("/"))
    return true if CI_NO_CODE_APPS_RUBY.match?(path)
    return false if CI_NO_CODE_TOOLING_ONLY.any? { |dir| path.start_with?(dir) }

    CI_NO_CODE_READ_DIRS.any? { |dir| path.start_with?(dir) } || gem_files.include?(path)
  end

  def gem_files
    @gem_files ||= Dir.chdir(CI_NO_CODE_REPO_ROOT) { Gem::Specification.load("rigortype.gemspec").files.to_set }
  end

  before do
    skip "not a git checkout" unless File.exist?(File.join(CI_NO_CODE_REPO_ROOT, ".git"))
  end

  it "matches what it should and never matches ci.yml (guards an extraction that yields nothing)" do
    expect(skipped_paths).to include("editors/vscode/package.json")
    expect(skipped_paths).not_to include(".github/workflows/ci.yml")
  end

  it "skips no file the suite, a linter or the packaged gem would read, apart from Markdown" do
    escaped = skipped_paths.reject { |path| path.end_with?(".md") }.select { |path| reads_it?(path) }

    expect(escaped).to be_empty, <<~MESSAGE
      These tracked files match `skip_re` in .github/workflows/ci.yml but are read by the Ruby suite, `make lint` or
      the packaged gem, so a pull request touching only them would skip the suite:
      #{escaped.map { |path| "  #{path}" }.join("\n")}
      Narrow `skip_re` (and the `push` trigger's `paths-ignore`), or move the file.
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
    ignored = tracked_files.select { |path| globs.any? { |glob| File.fnmatch(glob, path, flags) } }
    run_on_push_only = ignored - skipped_paths

    expect(run_on_push_only).to be_empty, <<~MESSAGE
      These tracked files are ignored by the `push` trigger's `paths-ignore` in .github/workflows/ci.yml but would
      still run the suite in a pull request (`skip_re` does not match them). Keep the two lists in step:
      #{run_on_push_only.map { |path| "  #{path}" }.join("\n")}
    MESSAGE
  end
end
