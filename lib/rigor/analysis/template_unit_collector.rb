# frozen_string_literal: true

require "digest"

require_relative "../cache/file_digest"
require_relative "template_unit_paths"
require_relative "../plugin/template_unit"

module Rigor
  module Analysis
    # The build half of {TemplateUnits} (#392, #1038): it expands every loaded plugin's `template_globs:`,
    # hands each match's bytes to the plugin's transform, isolates a failure into a {TemplateUnits::Failure}
    # row, substitutes the editor's buffer for the file on disk where one is bound, and — since #1038 —
    # carries a warm index's units for the templates that did not move.
    #
    # It is a separate file from the index for the reason {TemplateUnitPaths} is: the index is what the run
    # READS, on a hot path, and the reasons the build has to be careful are longer than the build.
    module TemplateUnitCollector
      # Expands every loaded plugin's `template_globs:` and runs its transform.
      #
      # A plugin whose glob matches nothing, or whose hook returns `[]`, contributes nothing. A plugin that
      # RAISES contributes nothing and does not break the run — the same failure isolation
      # `#diagnostics_for_file` has, and for the same reason: a template compiler meeting a file it cannot
      # read must cost that file's typing, never the run.
      #
      # Two plugins claiming one path is a conflict with no principled winner, so registration order decides
      # and the later claim is dropped; the loser is not a diagnostic (the project chose both plugins).
      # @param previous — a warm index from an earlier run of the same project (#1038). Every unit in it
      #   whose template is unchanged on disk is carried over instead of recompiled; see the class note.
      def self.collect(registry:, root: Dir.pwd, buffer: nil, previous: nil)
        claims = claims_for(registry)
        claimed = claims.flat_map(&:last).uniq
        signature = claims.map { |plugin, _globs| plugin_signature(plugin) }
        collection = Collection.new(
          root: root, buffer: buffer,
          carried: previous&.carry_over(root: root, claimed_globs: claimed, plugin_signature: signature) || {}
        )
        state = { entries: {}, failures: [], stats: {} }
        claims.each { |plugin, globs| collect_plugin(plugin, globs, collection, state) }
        TemplateUnits.new(state[:entries],
                          failures: state[:failures], claimed_globs: claimed, root: root,
                          stats: state[:stats], plugin_signature: signature)
      end

      # The entry point the LSP-facing {ProjectScan} is built through (#1038): the index a later run
      # CARRIES, so it is compiled with no buffer binding — a unit compiled from an editor's in-flight bytes
      # must never reach a snapshot someone reuses.
      #
      # Wrapped in {Cache::FileDigest.with_run} because ADR-87's racy guard is what makes the packs
      # recorded here trustworthy: the recording instant has to be taken BEFORE the bytes are read, so a
      # template written between the read and the stat is recorded as racy and always re-digested.
      # `prepare_project_scan` is not itself inside a run scope (only `Runner#run` is), and with no active
      # table `pack_stat` falls back to an instant taken AFTER its own `File.stat`, which can never be racy
      # — a pack pairing the OLD digest with the NEW stat tuple, which every later publish would validate
      # on the tuple fast path and serve stale. `strict:` rides along for the reason `Runner#run` carries
      # it: under `cache.validation: digest` the stat tier is skipped, here as everywhere else.
      def self.collect_for_scan(registry:, strict: false)
        return TemplateUnits.empty if registry.nil?

        Cache::FileDigest.with_run(strict: strict) { collect(registry: registry, buffer: nil) }
      end

      # The `(plugin, globs)` pairs of every plugin that claimed one, in registration order — which is what
      # decides a contested path (see {.collect}).
      #
      # A plugin whose manifest cannot be read claims nothing. `Plugin::Base#manifest` raises for a class
      # that declared none, and a registry is not guaranteed to hold only well-formed plugins (the loader
      # reports such a failure through its own channel); refusing to glob is the quiet, correct answer here
      # rather than a second report of the same defect.
      def self.claims_for(registry)
        registry.plugins.filter_map do |plugin|
          globs = begin
            plugin.manifest.template_globs
          rescue StandardError
            []
          end
          next if globs.empty?

          [plugin, globs]
        end
      end
      private_class_method :claims_for

      # What a carried index is checked against, beyond the per-file freshness: the identity of the plugins
      # that claimed a glob. A registry change is a whole-index rebuild, never a per-path question — the
      # transform itself may have changed.
      def self.plugin_signature(plugin)
        "#{plugin.manifest.id}@#{plugin.manifest.version}"
      rescue StandardError
        plugin.class.to_s
      end
      private_class_method :plugin_signature

      # The immutable half of one collection pass. Split off the mutable `state` hash so the per-plugin and
      # per-path helpers stay inside the parameter-count budget.
      Collection = Data.define(:root, :buffer, :carried)
      private_constant :Collection

      # #1047 — the carry is decided for a plugin's claim AS A WHOLE, not per path. A transform may read
      # the plugin's OTHER claimed templates: rigor-actionpack seeds a partial's locals from the render
      # sites in every view that renders it, so `users/_card`'s unit depends on the bytes of
      # `users/show`. A per-path carry reused `_card`'s unit after `show` dropped the local it passed,
      # and the stale seed survived every later publish. So if any of a plugin's claimed templates was
      # edited, added or deleted since the carried index was built, none of its units is carried and the
      # whole claim is recompiled. One change is not seen: a template that produced NO unit (declined, or
      # raised) being deleted, because the carried rows record no owning plugin for it. A declined template
      # contributed nothing a sibling could have read from its unit, which is why that is left as stated
      # rather than tracked. What stays exempt is the editor's buffer — a keystroke is not a save,
      # so #1038's per-keystroke property holds — and a path an earlier plugin already claimed.
      def self.collect_plugin(plugin, globs, collection, state)
        start_pass(plugin)
        plan = expand(globs, collection.root, collection.buffer).map do |path|
          physical = physical_path(path, collection.root, collection.buffer)
          [path, physical, carried_entry(path, physical, collection, state)]
        end
        whole = whole_carry?(plugin, plan, collection, state)
        plan.each do |path, physical, carried|
          if carried && whole
            state[:entries][path], state[:stats][path] = carried
          else
            compile(plugin, path, physical, state)
          end
        end
      end
      private_class_method :collect_plugin

      # {Plugin::Base#template_units_pass_started}, isolated: a plugin that raises there loses its own
      # revalidation for this pass and nothing else.
      def self.start_pass(plugin)
        plugin.template_units_pass_started
      rescue StandardError
        nil
      end
      private_class_method :start_pass

      # True when nothing in this plugin's claim moved: every planned path is carried (or is exempt, see
      # {.collect_plugin}), and no path the carried index held for this plugin has since vanished.
      def self.whole_carry?(plugin, plan, collection, state)
        return false if collection.carried.empty?

        id = plugin.manifest.id
        planned = plan.to_h { |path, _physical, _carried| [path, true] }
        vanished = collection.carried.any? { |path, (entry, _packed)| entry&.plugin_id == id && !planned.key?(path) }
        return false if vanished

        plan.all? do |path, physical, carried|
          carried || state[:entries].key?(path) || buffer_bound?(path, collection) ||
            unchanged_without_unit?(path, physical, collection)
        end
      end
      private_class_method :whole_carry?

      # A template the carried index READ and got no unit for — declined, or its transform raised — whose
      # bytes have not moved. It is re-offered to the plugin as before, but it is not an edit.
      def self.unchanged_without_unit?(path, physical, collection)
        entry, packed = collection.carried[path]
        entry.nil? && !packed.nil? && fresh?(physical, packed)
      end
      private_class_method :unchanged_without_unit?

      # Reads one claimed template and hands its bytes to the plugin, recording the compiled unit and the
      # freshness token a LATER run revalidates the carry against. A transform that raises costs this file
      # its unit and nothing else.
      def self.compile(plugin, path, physical, state)
        id = plugin.manifest.id
        source = read_source(physical, path, id, state[:failures])
        return if source.nil?

        state[:stats][path] = Cache::FileDigest.pack_stat(physical, Digest::SHA256.hexdigest(source))
        units = transform(plugin, path, source, state)
        return if units.nil?

        fallback = "#{id}@#{plugin.manifest.version}"
        units.each { |unit| record(state[:entries], unit, path, fallback, id, state[:failures]) }
      end
      private_class_method :compile

      # The plugin call itself, with the ADR-2 isolation envelope around it: a raise is one `plugin_loader`
      # row for this template and nil, which costs the file its unit and leaves the run intact. A transform
      # that returns nothing is `[]` — an honest decline — not a failure.
      def self.transform(plugin, path, source, state)
        Array(plugin.template_units_for_file(path: path, source: source))
      rescue StandardError => e
        state[:failures] << TemplateUnits::Failure.new(plugin_id: plugin.manifest.id, path: path,
                                                       message: "#{e.class}: #{e.message}")
        nil
      end
      private_class_method :transform

      # #1038 — the `[entry, stat_pack]` a warm index already compiled for `path`, when nothing that could
      # change it has moved; nil means "compile it".
      #
      # Three per-path refusals, each load-bearing; the whole-index ones are {TemplateUnits#carry_over}'s.
      # A path another plugin already claimed is left to the loop that follows, so a second claimant still
      # runs and is still reported the way it was before this memo existed. A path the editor's buffer is
      # bound to is ALWAYS recompiled, from the buffer's bytes: the saved file is not what the user is
      # looking at, and a unit compiled from a buffer must never end up in an index a later run carries.
      # Otherwise the file's own freshness decides, through the ADR-87 pack — a moved stat tuple falls back
      # to the content digest, so a touched-but-unedited template is still a reuse and an edited one never
      # is. Any stat failure (the template was deleted between the glob and here) reads as "not fresh",
      # which sends the path down the ordinary read path and produces the ordinary failure row.
      def self.carried_entry(path, physical, collection, state)
        return nil if state[:entries].key?(path)

        entry, packed = collection.carried[path]
        return nil if entry.nil? || packed.nil?
        return nil if buffer_bound?(path, collection)
        return nil unless fresh?(physical, packed)

        [entry, packed]
      end
      private_class_method :carried_entry

      def self.buffer_bound?(path, collection)
        buffer = collection.buffer
        !buffer.nil? && TemplateUnitPaths.relative(buffer.logical_path, collection.root) == path
      end
      private_class_method :buffer_bound?

      def self.fresh?(physical, packed)
        Cache::FileDigest.stat_fresh?(physical, packed)
      rescue StandardError
        false
      end
      private_class_method :fresh?

      # Editor mode (#146) — the in-flight buffer's bytes stand in for the file on disk, exactly as
      # `Runner#parse_source` reads them for a `.rb` file. Without this a `--tmp-file` / `--instead-of` pair
      # naming a TEMPLATE compiled the saved file and the editor got diagnostics for bytes it had already
      # replaced. `BufferBinding#resolve` is deliberately NOT used: it compares the logical path by string,
      # and a unit path is project-relative while the editor names its buffer absolutely.
      def self.physical_path(path, root, buffer)
        return buffer.physical_path if buffer && TemplateUnitPaths.relative(buffer.logical_path, root) == path

        File.join(root, path)
      end

      def self.read_source(physical, path, plugin_id, failures)
        File.binread(physical)
      rescue StandardError => e
        failures << TemplateUnits::Failure.new(plugin_id: plugin_id, path: path,
                                               message: "could not be read (#{e.class}: #{e.message})")
        nil
      end
      private_class_method :read_source

      # Sorted so the run's analysed-path order — and therefore the run cache key's `paths` slot — is
      # independent of the filesystem's directory order.
      #
      # An editor buffer whose logical path MATCHES a claimed glob joins the set even when nothing is on
      # disk at that path. That is the `didOpen` of a freshly created view: the file exists only in the
      # editor, `Dir.glob` cannot see it, and without this the run fell through to parsing the tmp bytes as
      # plain top-level Ruby — no declared `self`, no seeds, so a helper call read as
      # `call.unresolved-toplevel` and the finding the editor was actually looking at was missed. The
      # buffer's own bytes are what {.compile} then reads, and nothing else changes: an editor run is
      # read-only-cached, and `Runner#template_unit_file_entries` already skips a path with no physical file.
      def self.expand(globs, root, buffer = nil)
        paths = globs.flat_map { |glob| Dir.glob(glob, base: root) }
                     .select { |path| File.file?(File.join(root, path)) }
        buffered = buffer && TemplateUnitPaths.relative(buffer.logical_path, root)
        paths |= [buffered] if buffered && TemplateUnitPaths.claims?(globs, buffered)
        paths.uniq.sort
      end

      private_class_method :expand

      # A unit MUST name the file it was compiled from. Without the check a `path:` naming another project
      # file silently REPLACED that file's source (the engine serves a unit's bytes for its own path), and a
      # `path:` naming something outside the project root was analysed with no dependency-descriptor row —
      # both from a plugin that only had to get one string wrong. A mismatch is reported, not dropped in
      # silence, because a plugin author whose unit vanished has nothing to read.
      def self.record(entries, unit, claimed_path, fallback, plugin_id, failures)
        return unless unit.is_a?(Plugin::TemplateUnit)

        unless unit.path == claimed_path
          failures << TemplateUnits::Failure.new(
            plugin_id: plugin_id, path: claimed_path,
            message: "returned a unit for #{unit.path.inspect}, which is not the file it was offered; " \
                     "a unit may only name its own source"
          )
          return
        end
        # First claim wins — see {.collect}. A duplicate `logical_name` across two DIFFERENT paths is NOT
        # refused: the two units are analysed separately and their summaries union under one `view:` key,
        # which is the same reading a method reopened in two files gets.
        return if entries.key?(unit.path)

        entries[unit.path] = TemplateUnits::Entry.new(
          logical_name: unit.logical_name, path: unit.path, source: unit.ruby_source,
          line_map: unit.line_map, self_type: unit.self_type, locals: unit.locals,
          ivar_seeds: unit.ivar_seeds, digest: unit.digest(fallback), unit_key: unit.unit_key,
          plugin_id: plugin_id, suppressed_rules: unit.suppressed_rules
        )
      end
      private_class_method :record
    end
  end
end
