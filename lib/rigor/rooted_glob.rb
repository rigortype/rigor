# frozen_string_literal: true

module Rigor
  # `Dir.glob(File.join(root, pattern))` with `root` read as a literal path (#1956, #1959).
  #
  # Joining a directory into the pattern makes `Dir.glob` read the directory's own characters as glob syntax:
  # a project at `ds [x]` or `ds{a}` matches nothing, `ds*` matches its siblings, `fx[1]` matches `fx1`, and
  # a directory literally named `{..,zz}` expands into the parent tree. Globbing `pattern` against `base: root`
  # leaves `root` uninterpreted, and joining each match back onto `root` spells the results exactly as the
  # joined glob spelled them for a root without metacharacters: same strings, same order, `root` kept as given
  # (relative, symlinked or with a trailing `/`).
  #
  # A leading `/` on `pattern` is dropped: `Dir.glob` ignores `base:` for an absolute pattern, while the joined
  # spelling read `File.join(root, "/etc/*")` as `root/etc/*`. Every caller keeps that meaning.
  module RootedGlob
    module_function

    # @param root — a directory path (String or Pathname), taken literally
    # @param pattern — a `Dir.glob` pattern relative to `root`
    # @return the matches spelled under `root`, in `Dir.glob` order; empty when `root` is not a directory
    def glob(root, pattern)
      root = root.to_s
      Dir.glob(pattern.to_s.sub(%r{\A/+}, ""), base: root).map { |relative| File.join(root, relative) }
    end
  end
end
