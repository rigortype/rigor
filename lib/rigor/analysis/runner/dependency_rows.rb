# frozen_string_literal: true

require_relative "../../cache/descriptor"
require_relative "../../cache/file_digest"
require_relative "../../cache/rbs_descriptor"
require_relative "../../environment/bundle_sig_discovery"
require_relative "../path_expansion"

module Rigor
  module Analysis
    class Runner
      # The leaf rows of the run dependency descriptor and of the `--incremental` slot's rows: what a cached
      # run answer depends on, as {Cache::Descriptor} file and glob entries. Each entry is a function of its
      # arguments, with the {Runner}'s instance state passed in (a `Runner` ivar is a parameter of the same
      # name), and returns rows; none writes anything. {Runner} keeps the assembly: which rows a run puts
      # together (`build_run_dependency_descriptor`, `incremental_slot_rows`, `baseline_dependency_rows`)
      # and the memo the descriptor is kept in.
      #
      # The run KEY is {RunCacheKey}'s; these rows are its validation half, re-digested on the next run by
      # {Cache::Descriptor#fresh?}.
      module DependencyRows
        module_function

        # #1962 / #1555 — a kind row per path the run's answer depends on the presence and kind of, not only its
        # bytes. An analysis root: its path errors (`no such file or directory`, `not a Ruby file`) answer to whether
        # it exists and whether it is a directory or a file, while what a directory root holds is the analysed-file
        # set the key carries. A `pre_eval:` entry: `pre-eval.file-not-found` answers to whether it is a file (one
        # that is has its `:stat` row from {#pre_eval_file_entries}). A project signature root, configured or the
        # auto-detected `sig`: the loader reads a directory and a file differently, and #979's listing rows cover a
        # file appearing under a root that existed, not the root appearing. A kind row rather than an existence row,
        # because a directory replaced by a file of the same name leaves an existence row fresh. The `--incremental`
        # slot records kind rows for the same paths ({Runner#incremental_slot_rows},
        # {Runner#baseline_dependency_rows}, #1977).
        def root_presence_entries(roots, pre_eval, signature_root_candidates)
          (roots + pre_eval + signature_root_candidates)
            .uniq.map { |path| Cache::Descriptor::FileEntry.kind(path: path) }
        end

        # Every file a plugin read or probed through its `IoBoundary` (#577 / #613), and every directory it listed
        # (#954), as the boundaries stand when asked.
        def plugin_boundary_rows(plugins)
          files = []
          globs = []
          plugins.each do |plugin|
            # Read the boundary WITHOUT triggering its lazy `@io_boundary ||=` initializer: plugin instances
            # are frozen after the run, and a plugin that never built a boundary read no files through it,
            # so it contributes no dependencies.
            boundary = plugin.instance_variable_get(:@io_boundary)
            next unless boundary

            # #629 — a boundary carries GlobEntry listing rows too (`IoBoundary#list_directory`), and they
            # are the only edge back to a file the run decided was ABSENT from a directory it consulted.
            boundary_descriptor = boundary.cache_descriptor
            files.concat(boundary_descriptor.files)
            globs.concat(boundary_descriptor.globs)
          end
          Cache::Descriptor.new(files: files, globs: globs)
        end

        # One glob row per producer `watch:` pattern (ADR-60 WD3), recomputed against the tree as it stands.
        def producer_watch_glob_entries(plugins)
          plugins.flat_map do |plugin|
            plugin.class.producers.each_value.flat_map do |prod|
              prod[:watch] ? plugin.send(:watch_glob_entries, prod[:watch]) : []
            end
          end
        end

        # Whether every boundary row that appeared or changed during the per-file loop is one some file's analysis
        # was credited with. A row outside every file's attribution would ride this run's `run` rows only, and the
        # next narrowed run — which does not repeat the read — would drop it.
        def analysis_reads_attributed?(post, pre, analysis_reads)
          credited = analysis_reads.each_value.flat_map(&:itself).to_set
          (post.files - pre.files).all? { |row| credited.include?(row) } &&
            (post.globs - pre.globs).all? { |row| credited.include?(row) }
        end

        # A loader's two readers {Cache::RbsDescriptor} takes signature roots from. `core_root` (issue #2517) is the
        # selected core, which the slot key names by path only, so its files are `owned` rows like the project's own.
        SignatureRoots = Struct.new(:signature_paths, :core_root)
        private_constant :SignatureRoots

        # The signature tree's rows, the project's own and the rest.
        def signature_rows(signature_paths, core_root, signature_root_candidates)
          roots = SignatureRoots.new(signature_paths, core_root)
          own = (signature_root_candidates + [core_root].compact)
                .map { |root| File.join(File.absolute_path(root.to_s), "") }
          own_files, other_files = Cache::RbsDescriptor.file_entries(roots, comparator: :stat)
                                                       .partition { |row| within?(row.path, own) }
          own_globs, other_globs = Cache::RbsDescriptor.glob_entries(roots).partition { |row| within?(row.root, own) }
          [Cache::Descriptor.new(files: own_files, globs: own_globs.uniq),
           Cache::Descriptor.new(files: other_files, globs: other_globs.uniq)]
        end

        def within?(path, roots)
          directory = File.join(File.absolute_path(path.to_s), "")
          roots.any? { |root| directory.start_with?(root) }
        end

        # One names-mode listing row per directory the discovery widening globbed, so a file appearing there is seen
        # as well as an edit to one that existed. Issue #1583 — keyed on the widening decision, not on what it
        # added: a run over `lib/b.rb` alone in `lib` widens to nothing, and a `lib/a.rb` created afterwards must
        # still move the answer of the run-result cache and the `--incremental` slot.
        def discovery_glob_entries(discovery_widened, paths)
          return [] unless discovery_widened

          paths.select { |root| File.directory?(root) }.map do |root|
            Cache::Descriptor::GlobEntry.compute(root: root, pattern: PathExpansion::RUBY_GLOB, mode: :names)
          end
        end

        # Issue #2987 — one names-mode listing row per bundle `sig/` layout ({Environment::BundleSigDiscovery.discover}'s
        # two globs). The signature rows list only the directories the loader read, so a gem that GAINS a `sig/`
        # (or loses it) while its version and lock entry stand still sits in none of them, and the run-result
        # slot kept serving the environment built without (or with) it.
        def bundle_sig_glob_entries(bundler_bundle_path, bundler_auto_detect)
          root = Environment::BundleSigDiscovery.resolve_bundle_path(
            bundle_path: bundler_bundle_path, project_root: Dir.pwd,
            auto_detect: bundler_auto_detect
          )
          return [] if root.nil?

          Environment::BundleSigDiscovery::SIG_GLOBS.map do |pattern|
            Cache::Descriptor::GlobEntry.compute(root: root.to_s, pattern: pattern, mode: :names)
          end
        end

        def unanalysed_pre_eval_entries(files, pre_eval, buffer)
          analysed = files.to_set { |path| File.absolute_path(path) }
          outside = pre_eval.reject { |path| analysed.include?(File.absolute_path(path)) }
          outside.map do |path|
            if File.file?(path)
              Cache::Descriptor::FileEntry.stat(path: path, digest: Cache::FileDigest.hexdigest(path))
            else
              kind_entries([path], buffer).first
            end
          end
        end

        # #1977 — one `:kind` row per path, the row {#root_presence_entries} records in the plain slot.
        def kind_entries(paths, buffer)
          paths.uniq.map do |path|
            Cache::Descriptor::FileEntry.kind(path: buffer ? buffer.resolve(path) : path)
          end
        end

        # Issue #684 — the project files this run DISCOVERED but did not analyse. A widened run's diagnostics
        # are a function of them (that is the entire point: the method whose absence would have been reported
        # is defined in one of them), so the run-result cache must invalidate when one changes. Empty on every
        # run whose discovery expansion is its analysis expansion, which is every whole-project run.
        def discovery_file_entries(expansion, project_discovery_expansion, buffer)
          return [] if project_discovery_expansion.nil?

          analyzed = expansion.fetch(:files).to_set
          analyzed_file_entries(
            { files: project_discovery_expansion.fetch(:files).reject { |path| analyzed.include?(path) } }, buffer
          )
        end

        def analyzed_file_entries(expansion, buffer)
          expansion.fetch(:files).map do |path|
            physical = buffer ? buffer.resolve(path) : path
            # ADR-87 WD1 — validation-only dependency descriptor, so the stat-then-digest `:stat` comparator
            # applies (the env-cache KEY files stay `:digest`).
            Cache::Descriptor::FileEntry.stat(path: physical, digest: Cache::FileDigest.hexdigest(physical))
          end
        end

        # Every template the run READ, successes and failures alike: a `plugin_loader` row produced by a
        # template that would not compile must not outlive the edit that fixes it, and a buffer-bound path is
        # digested at the bytes the run actually read.
        #
        # #392 — the TEMPLATE files behind the run's units. The key slot carries the compiled Ruby's digest
        # (`template_units_digest`), which is what decides whether a cached answer describes this source; these
        # entries are the validation half, so a template edited between two runs re-globs and re-digests here
        # exactly as an analysed `.rb` file does. Both are needed: a transform that compiles two different
        # templates to the same Ruby must still not resurrect the wrong PATH in a diagnostic.
        def template_unit_file_entries(template_units, buffer)
          template_units.source_paths.filter_map do |path|
            physical = template_units.physical_path(path, buffer)
            next unless File.file?(physical)

            Cache::Descriptor::FileEntry.stat(path: physical, digest: Cache::FileDigest.hexdigest(physical))
          end
        end

        # Issue #352 — a `pre_eval:` file is a real input to the run's diagnostics: its `def`s populate the
        # ADR-17 patched-method registry and (since #352) its constants populate the project seed. ADR-17 WD5
        # permits listing a file under `pre_eval:` and NOT under `paths:`, and such a file never appears in the
        # expansion — so without this entry, editing one would leave the run-result cache serving diagnostics
        # computed against the previous version. The common case (a `lib/core_ext/` file that is also under
        # `paths:`) contributes a duplicate entry, which the descriptor's per-path validation absorbs.
        def pre_eval_file_entries(pre_eval, buffer)
          pre_eval.filter_map do |path|
            physical = buffer ? buffer.resolve(path) : path
            next unless File.file?(physical)

            Cache::Descriptor::FileEntry.stat(path: physical, digest: Cache::FileDigest.hexdigest(physical))
          end
        end

        private_class_method :within?
      end
    end
  end
end
