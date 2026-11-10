# frozen_string_literal: true

# Guard for the `changes` job in `.github/workflows/ci.yml`: a pull request that changes only the paths
# `skip_re` matches skips the code suite (RSpec, self-check, lint, the RBS matrix) and runs this
# `spec/docs/` directory alone. That is safe only while the Ruby suite never reads those paths, so a tracked
# file that the suite or a linter would read must not land in the skipped set. The check runs the workflow's own
# `skip_re` lines through bash against `git ls-files`, so the list it guards cannot drift from the one CI uses.
#
# Markdown is exempt from the read-tree check: it was skipped before the list grew, and the suite reads none of
# it outside `spec/docs/`, which still runs.
require "spec_helper"
require "open3"

CI_NO_CODE_REPO_ROOT = File.expand_path("../..", __dir__)
CI_NO_CODE_WORKFLOW = File.join(CI_NO_CODE_REPO_ROOT, ".github", "workflows", "ci.yml")

# Trees the Ruby suite, `make lint` or an analysis reads. A skipped file here would escape a gate.
CI_NO_CODE_READ_TREES = %w[spec/ lib/ sig/ exe/ plugins/ examples/ data/builtins/ data/core_overlay/
                           data/vendored_gem_sigs/].freeze

RSpec.describe "CI no-code path list (ci.yml `skip_re`)" do
  def skipped_paths
    @skipped_paths ||= begin
      assignments = File.readlines(CI_NO_CODE_WORKFLOW).grep(/^\s*skip_re=/).map(&:strip)
      raise "no `skip_re=` lines in #{CI_NO_CODE_WORKFLOW}" if assignments.empty?

      script = "#{assignments.join("\n")}\ngit ls-files | grep -E \"$skip_re\" || true"
      out, status = Open3.capture2("bash", "-c", script, chdir: CI_NO_CODE_REPO_ROOT)
      raise "bash failed evaluating skip_re" unless status.success?

      out.split("\n")
    end
  end

  before do
    skip "not a git checkout" unless File.exist?(File.join(CI_NO_CODE_REPO_ROOT, ".git"))
  end

  it "matches what it should and never matches ci.yml (guards an extraction that yields nothing)" do
    expect(skipped_paths).to include("editors/vscode/package.json")
    expect(skipped_paths).not_to include(".github/workflows/ci.yml")
  end

  it "skips no file the suite or a linter would read, apart from Markdown" do
    escaped = skipped_paths.reject { |path| path.end_with?(".md") }.select do |path|
      CI_NO_CODE_READ_TREES.any? { |tree| path.start_with?(tree) } || path == "Gemfile" || path.end_with?(".gemspec")
    end

    expect(escaped).to be_empty, <<~MESSAGE
      These tracked files match `skip_re` in .github/workflows/ci.yml but sit in a tree the Ruby suite reads, so a
      pull request touching only them would skip the suite:
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
end
