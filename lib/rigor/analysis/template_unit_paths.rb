# frozen_string_literal: true

module Rigor
  module Analysis
    # The path-spelling arithmetic behind {TemplateUnits} (#392).
    #
    # A template unit is keyed the way a claimed glob spells it — project-relative, as `Dir.glob(base:)`
    # returns it. Every other spelling a path can arrive in has to reduce to that one before a lookup or a
    # claim test, and there are more of them than there look to be: a language server names a buffer by its
    # absolute path, a shell hands over `./app/views/x.rbx` or `lib/../app/views/x.rbx`, and the same
    # directory reached through a symlink is the same directory (`Dir.pwd` is always resolved; on macOS an
    # editor's `/var/…` and pwd's `/private/var/…` are one place). Each of those missed the unit and left
    # the template parsed as plain Ruby, so the reduction lives in one place with the reasons attached.
    module TemplateUnitPaths
      module_function

      # A path as the globs spell it. An analysed path may arrive ABSOLUTE — the language server names a
      # buffer by its full filesystem path, and `rigor check /abs/path` does too — while a claimed glob and
      # everything `Dir.glob(base:)` returns are project-relative. Every lookup and every claim test goes
      # through this, so the two spellings name one unit instead of silently missing each other (which is
      # how an LSP publish for an open `.rbx` reported `call.unresolved-toplevel` for every helper while the
      # unit sat in the index under its relative name). A path outside the root is left alone.
      def relative(path, root)
        # `expand_path` against the root first, so `./app/views/x.rbx`, `app/views/x.rbx` and
        # `$ROOT/lib/../app/views/x.rbx` all reduce to the one absolute spelling before anything is
        # compared. Without it an `--instead-of=./app/views/x.rbx` matched no unit and was parsed as plain
        # Ruby — the spellings a shell and an editor produce are not the spelling `Dir.glob` returns.
        root_dir = File.expand_path(root.to_s)
        text = File.expand_path(path.to_s, root_dir)
        # BOTH spellings of the root. `expand_path` does not resolve symlinks, and the root is not always
        # already resolved: `Dir.pwd` is (which is why this was latent), but a caller may pass any path.
        prefixes(root_dir).each do |prefix|
          return text.delete_prefix(prefix) if text.start_with?(prefix)
        end

        # The same directory reached through a symlink is the same directory. `Dir.pwd` is always the
        # resolved form (`/private/var/…` on macOS) while an editor names a buffer by the path the user
        # opened (`/var/…`), so a string compare alone loses the match.
        resolved = resolved_path(text)
        return text if resolved.nil?

        prefixes(root_dir).each do |prefix|
          return resolved.delete_prefix(prefix) if resolved.start_with?(prefix)
        end
        text
      end

      def prefixes(root_dir)
        [root_dir, (begin
          File.realpath(root_dir)
        rescue StandardError
          nil
        end)].compact.uniq.map { |dir| "#{dir}#{File::SEPARATOR}" }
      end

      # `text` with its **nearest existing ancestor** resolved and the rest re-joined. Realpathing the whole
      # dirname is not enough: a buffer for a view in a directory the editor has not created yet
      # (`app/views/reports/new.rbx` with no `reports/`) raises `ENOENT` there, and a nil answer meant a
      # symlinked root lost the unit entirely for exactly the file most likely to be open.
      def resolved_path(text)
        remainder = []
        current = text
        loop do
          parent = File.dirname(current)
          remainder.unshift(File.basename(current))
          real = begin
            File.realpath(parent)
          rescue StandardError
            nil
          end
          return File.join(real, *remainder) if real
          return nil if parent == current

          current = parent
        end
      end

      # `FNM_PATHNAME` so `*` does not cross a directory separator (the same reading `Dir.glob` gives the
      # pattern), `FNM_EXTGLOB` so a `{html,text}` alternation in a claimed glob matches here as it did
      # there — the two flags together are what make this predicate agree with the expansion above.
      def claims?(globs, path)
        # `relative` has already reduced an IN-root path to its project-relative form, so anything still
        # absolute here is outside the project. An unanchored claim (`**/*.rbx`) would otherwise match it,
        # and the plugin would be handed an absolute `path:` for a file the project does not contain.
        return false if path.start_with?(File::SEPARATOR)

        globs.any? { |glob| File.fnmatch?(glob, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) }
      end
    end
  end
end
