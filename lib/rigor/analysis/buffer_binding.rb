# frozen_string_literal: true

module Rigor
  module Analysis
    # Binds one logical project path (the path the user is editing, e.g. `lib/foo.rb`) to a physical file
    # containing the in-flight buffer bytes (e.g. `/tmp/9539itfeh2.rb`). When the runner / workers / pre-passes
    # need to read source for the logical path, they read from the physical path instead; when they emit a
    # `Diagnostic`, the path is the logical one so editors highlight the buffer the user is actually looking at.
    #
    # See `docs/design/20260516-editor-mode.md` for the design. The CLI surfaces this through paired
    # `--tmp-file` / `--instead-of` flags on `rigor check` and `rigor type-of`; programmatic callers pass a
    # `BufferBinding` to `Runner.new`.
    BufferBinding = Data.define(:logical_path, :physical_path) do
      # Returns the physical path to read bytes from when the caller is about to parse `path`. For non-logical
      # paths returns the input unchanged. Cheap to call on every path; the binding is singular today (one
      # buffer per run).
      def resolve(path)
        path == logical_path ? physical_path : path
      end

      # Returns the path the caller should report in user-facing output (diagnostics, run stats) when it
      # currently holds the physical path. The inverse of `#resolve`. Non-physical paths pass through
      # unchanged, so it is safe to stamp every outgoing path through this helper.
      def display_path(path)
        path == physical_path ? logical_path : path
      end

      # The file's identity for comparing two spellings of one path: its real path, resolved through its directory
      # when the file is absent from disk (a new buffer's file), so a symlinked root or parent spells it as it spells
      # an existing file. Two accepted limits: a missing name is compared as written, so a name that differs only in
      # case is not matched; and a `..` in a missing path is resolved textually, not through the filesystem.
      def self.real_path(path)
        File.realpath(path)
      rescue SystemCallError
        absolute = File.absolute_path(path)
        parent = File.dirname(absolute)
        return absolute if parent == absolute

        File.join(real_path(parent), File.basename(absolute))
      end
    end
  end
end
