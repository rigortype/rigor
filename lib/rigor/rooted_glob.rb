# frozen_string_literal: true

module Rigor
  # `Dir.glob(File.join(root, pattern))` with `root` read as a literal path (#1956, #1959).
  #
  # Joining a directory into the pattern makes `Dir.glob` read the directory's own characters as glob syntax:
  # a project at `ds [x]` or `ds{a}` matches nothing, `ds*` matches its siblings, `fx[1]` matches `fx1`, and
  # a directory literally named `{..,zz}` expands into the parent tree. Each glob metacharacter of `root` is
  # backslash-escaped before the join, so `root` matches only itself while `pattern` keeps exactly the meaning the
  # joined spelling gave it: a leading `/` collapses into the join (`/etc/*` reads `root/etc/*`), and so does one
  # inside a brace alternative (`{/etc,lib}/*` reads `root/etc/*` and `root/lib/*`). `Dir.glob(pattern, base:)`
  # would not do that: it reads an absolute pattern, or an absolute alternative, outside `base`. A root without
  # metacharacters is joined unchanged, so the results are the joined glob's strings in its order, `root` kept as
  # given (relative, symlinked or with a trailing `/`).
  #
  # `literal(name)` is the same escape for a single name (a file's basename, a configured path) that is joined into
  # a pattern as a literal: `literal("a[1].rb")` matches `a[1].rb` and not `a1.rb`.
  module RootedGlob
    METACHARACTERS = /[\[\]{}*?\\]/

    module_function

    # @param root — a directory path, taken literally
    # @param pattern — a `Dir.glob` pattern relative to `root`
    # @return the matches spelled under `root`, in `Dir.glob` order; empty when `root` is not a directory
    def glob(root, pattern)
      Dir.glob(File.join(literal(root), pattern.to_s))
    end

    # @param name — a file or directory name, taken literally
    # @return the pattern that matches exactly `name` under `Dir.glob`, with its metacharacters escaped
    def literal(name)
      name.to_s.gsub(METACHARACTERS, "\\\\\\0")
    end

    # A configured file path (#2222), absolute or relative to the working directory, as the `[root, pattern]` pair
    # that `glob(root, pattern)` reads as exactly that file. A relative path stays under the working directory, as
    # it always did. An absolute one is split into its own directory and a literal basename: `File.join(".", "/abs")`
    # reads `./abs`, so an absolute path joined under `"."` matched nothing.
    #
    # @param path — a file path, taken literally
    # @return `[root, pattern]`: `"."` and the literal path when relative, else the directory and the literal basename
    def split_file(path)
      path = path.to_s
      return [".", literal(path)] unless File.absolute_path?(path)

      [File.dirname(path), literal(File.basename(path))]
    end
  end
end
