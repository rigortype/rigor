# frozen_string_literal: true

module Rigor
  module Analysis
    # Frozen snapshot of the project-wide state {Runner} consumes before per-file analysis fires: the loaded
    # plugin registry (with `#prepare` already invoked), the dependency-source index, the synthetic-method and
    # project-patched indexes produced by the pre-pass scanners, and the diagnostics those passes emitted.
    #
    # Owners (`Rigor::LanguageServer::ProjectContext`, future editor / sig-gen integrations) build a ProjectScan
    # once per project-state generation via `Runner#prepare_project_scan` and pass it to
    # `Runner.new(prebuilt: ...)` so per-buffer publishes skip the scanner walks and `#prepare` re-runs. When
    # watched project files change, the owner discards the ProjectScan and a fresh one builds on next read.
    #
    # Editor mode v1 contract reminder: scanners observe the bytes that were on disk at scan time, NOT the
    # in-flight buffer. Edits to a file that itself declares synthetic methods (or `pre_eval:`-listed patches)
    # are NOT visible until the owner invalidates the scan — typically via `workspace/didChangeWatchedFiles`.
    # This is the same trade-off the LSP made when slice 7 cached only the `Environment`; extending the cache
    # to the pre-pass outputs preserves the contract.
    #
    # `template_units` (#1038) is the one slot a consumer does not adopt verbatim. The rest of the snapshot
    # is reused as it stands until the owner invalidates it; the template index is handed to
    # `TemplateUnits.collect(previous:)`, which re-expands the claimed globs and revalidates each template
    # against the filesystem, so a template edited, added or deleted on disk is seen on the next publish
    # even though the snapshot itself did not move. What the carry saves is the plugin transform — for ERB
    # (#393) an Erubi compile of every view in the project, otherwise paid per keystroke. The index is
    # always built WITHOUT a buffer binding, so the shared snapshot never holds a unit compiled from an
    # editor's in-flight bytes.
    ProjectScan = Data.define(
      :plugin_registry,
      :dependency_source_index,
      :synthetic_method_index,
      :project_patched_methods,
      :plugin_prepare_diagnostics,
      :pre_eval_diagnostics,
      :template_units
    )
  end
end
