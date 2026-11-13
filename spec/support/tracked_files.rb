# frozen_string_literal: true

require "open3"

# `git ls-files -z` as one instrument, for the gates that ask the repository which files it ships.
#
# Two gates in `spec/docs/` read that list and neither can use a glob of the working tree:
# `ci_no_code_paths_spec.rb` checks `ci.yml`'s no-code skip list against every tracked path, and
# `link_integrity_spec.rb` resolves the links in the agent-instruction trees, two of which keep
# installed artifacts beside the instructions (`.gitignore` admits only `.pi/settings.json` and
# `.pi/agents/`). A glob there reads whatever a contributor has installed. Measured on one such clone:
# 121 ignored `.md` files under the five roots, 93 of them under `.pi/npm/node_modules/`; 25 carry a
# relative link and so entered the link corpus; 5 link to files their package does not ship. So
# `make docs-check` failed there and passed in CI, which checks out without them. A gate only one
# side can see is worse than no gate.
#
# The details each caller would otherwise get wrong:
#
# - **`-z`, and binary strings.** The default quoting returns `"na\303\257ve.json"` for a non-ASCII
#   path, which matches none of the callers' anchors (#3060), and a plain `ls-files` also quotes a
#   name containing a newline, so the `.md` filter drops it. `-z` hands over exact bytes; `.b` keeps
#   them matchable, because a UTF-8-tagged invalid string raises on `match?` instead of failing an
#   example.
# - **A git hook's environment.** A spec run from inside a hook inherits `GIT_DIR` & friends, which
#   would point the child `git` at the hook's repository — and a `git add` in a temporary repository
#   would write to the real index. {GIT_ENV} unsets them for every call.
# - **Exit status.** A failed `git` prints to stderr and returns nothing; without the check the
#   caller silently gets an empty file list, which reads as "the corpus shrank".
# - **Unmerged paths.** `ls-files` lists a conflicted path once per stage, so a merge conflict under
#   a watched root would otherwise duplicate it.
module TrackedFiles
  GIT_ENV = { "GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_INDEX_FILE" => nil }.freeze

  class << self
    # Tracked paths under `pathspecs` (all of them when none is given), relative to `root`, as
    # binary strings.
    def call(root, *pathspecs)
      args = ["git", "ls-files", "-z"]
      args += ["--", *pathspecs] unless pathspecs.empty?
      out, err, status = Open3.capture3(GIT_ENV, *args, chdir: root)
      raise "`git ls-files -z` failed in #{root} (exit #{status.exitstatus}): #{err.strip}" unless status.success?

      out.b.split("\0").uniq
    end

    # For a spec that builds a throwaway repository to exercise a caller of {call}.
    def git!(dir, *args)
      _out, err, status = Open3.capture3(GIT_ENV, "git", *args, chdir: dir)
      return if status.success?

      raise "git #{args.join(' ')} failed in #{dir} (exit #{status.exitstatus}): #{err.strip}"
    end
  end
end
