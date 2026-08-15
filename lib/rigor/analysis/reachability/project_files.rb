# frozen_string_literal: true

module Rigor
  module Analysis
    module Reachability
      # Which files in a checkout are the PROJECT's, for the purpose of harvesting references.
      #
      # `rigor unused` reads references from the whole project rather than only the analysed `paths:` (ADR-102
      # WD7), which makes "the whole project" a question that needs answering rather than assuming.
      module ProjectFiles
        # Trees that are never a project's own source. A reference found inside a vendored gem is not evidence
        # about this project, and globbing them can cost more than every analysed file combined.
        VENDOR_DIRS = %r{\A(vendor|node_modules|tmp|\.git|\.rigor|coverage)/}

        module_function

        # Path prefixes of the checkout's git submodules, from `.gitmodules`.
        #
        # A submodule is a separate project that happens to live inside this one; its contents are neither this
        # project's declarations nor references to them. Rigor's own repository is the case that made this
        # unmissable — it vendors upstream sources under `references/`, 13,894 of the 18,002 files the
        # reference glob would otherwise read, and one of them crashed the run outright.
        #
        # Reads `.gitmodules` rather than probing for nested `.git` entries: it is one cheap file against a
        # second full tree walk, and it is what the repository itself declares. A nested checkout that is not a
        # registered submodule is therefore not detected — `exclude:` covers that case.
        def submodule_prefixes(root)
          gitmodules = File.join(root, ".gitmodules")
          return [] unless File.file?(gitmodules)

          File.read(gitmodules).scan(/^\s*path\s*=\s*(.+)$/).flatten.filter_map do |path|
            trimmed = path.strip
            "#{trimmed.delete_suffix('/')}/" unless trimmed.empty?
          end
        rescue SystemCallError
          []
        end

        # @param relative_paths [Array<String>] paths relative to `root`.
        # @return [Array<String>] those that belong to the project itself.
        def own(relative_paths, root)
          prefixes = submodule_prefixes(root)
          relative_paths.grep_v(VENDOR_DIRS).reject { |rel| prefixes.any? { |prefix| rel.start_with?(prefix) } }
        end
      end
    end
  end
end
