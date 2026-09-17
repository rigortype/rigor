# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require "rigor/language_server"
require "rigor/configuration"

RSpec.describe Rigor::LanguageServer::DiagnosticPublisher do
  # In-memory writer collecting every payload pushed to it. Mirrors
  # `LanguageServer::Protocol::Transport::Io::Writer#write` but captures the raw Hash so specs can inspect the wire
  # shape without re-parsing. A method (not `let`) so a single example can build several independent writers —
  # needed to compare a batched round against N sequential single-buffer rounds side by side.
  def build_writer
    Class.new do
      attr_reader :payloads

      def initialize
        @payloads = []
      end

      def write(payload)
        @payloads << payload
      end
    end.new
  end

  let(:writer) { build_writer }

  let(:buffer_table) { Rigor::LanguageServer::BufferTable.new }
  let(:configuration) { Rigor::Configuration.new("paths" => []) }
  let(:project_context) { Rigor::LanguageServer::ProjectContext.new(configuration: configuration) }
  let(:publisher) do
    described_class.new(writer: writer, buffer_table: buffer_table, project_context: project_context)
  end

  describe "#publish_for" do
    it "no-ops when the URI isn't a file:// scheme" do
      publisher.publish_for("untitled:foo")
      expect(writer.payloads).to be_empty
    end

    it "no-ops when the buffer isn't open in the table" do
      publisher.publish_for("file:///not/in/table.rb")
      expect(writer.payloads).to be_empty
    end

    it "publishes an EMPTY set for a buffer the server could not keep in sync" do
      Dir.mktmpdir("rigor-lsp-desync-") do |tmpdir|
        path = File.join(tmpdir, "foo.rb")
        uri = "file://#{path}"
        buffer_table.open(uri: uri, bytes: "def broken\n", version: 1)
        # A malformed range edit: the table keeps the old text and marks the URI desynchronised.
        buffer_table.apply_changes(
          uri: uri,
          changes: [{ range: { start: { line: 0 }, end: { line: 0, character: 0 } }, text: "x" }],
          version: 2
        )

        Dir.chdir(tmpdir) { publisher.publish_for(uri) }

        # Markers are cleared rather than left pointing at spans computed from text that has drifted.
        expect(writer.payloads.size).to eq(1)
        expect(writer.payloads.first.dig(:params, :diagnostics)).to eq([])
      end
    end

    it "pushes one `textDocument/publishDiagnostics` notification per call" do
      Dir.mktmpdir("rigor-lsp-publish-") do |tmpdir|
        path = File.join(tmpdir, "foo.rb")
        uri = "file://#{path}"
        # Buffer has a parse error — should surface as an LSP diagnostic mapped from Rigor's :error severity.
        buffer_table.open(uri: uri, bytes: "def broken\n", version: 1)

        Dir.chdir(tmpdir) { publisher.publish_for(uri) }

        expect(writer.payloads.size).to eq(1)
        msg = writer.payloads.first
        expect(msg[:method]).to eq("textDocument/publishDiagnostics")
        expect(msg.dig(:params, :uri)).to eq(uri)
        diagnostics = msg.dig(:params, :diagnostics)
        expect(diagnostics).not_to be_empty
        expect(diagnostics.first[:severity]).to eq(1) # LSP Error
        expect(diagnostics.first[:source]).to eq("rigor")
      end
    end

    # #392 — a template-unit buffer. The publisher's Runner path already carries the `BufferBinding` into
    # `TemplateUnits.collect`, but the LSP entry itself was unpinned: a regression there would publish
    # diagnostics computed from the saved file (or, for a view that exists only in the editor, from the
    # buffer parsed as plain top-level Ruby with no declared `self`) on every keystroke.
    it "publishes a `.rbx` buffer through its template unit, not as raw top-level Ruby" do
      Dir.mktmpdir("rigor-lsp-template-unit-") do |tmpdir|
        path = write_template_unit_project(tmpdir)
        uri = "file://#{path}"
        buffer_table.open(uri: uri, bytes: "render_header(@title.nope_in_buffer)\n", version: 1)
        context = template_unit_context(tmpdir)

        Dir.chdir(tmpdir) { publisher_for(context).publish_for(uri) }

        messages = writer.payloads.first.dig(:params, :diagnostics).map { |d| d[:message] }
        # The buffer's own call, resolved against the DECLARED `self` — `render_header` is silent and
        # nothing reads as an unresolved top-level call.
        expect(messages).to eq(["undefined method `nope_in_buffer' for String"])
      end
    ensure
      # `Rigor::Plugin.register` is process-global; leaving the id registered makes a later spec's own
      # registration read as "the gem registered nothing new" and fail its load.
      Rigor::Plugin.unregister!("view-demo")
    end

    # #1038 — the warm-path acceptance. A per-buffer publish against a long-lived ProjectContext must not
    # re-run the plugin transform: before the index was carried on the ProjectScan, every keystroke
    # re-globbed the claimed patterns, re-read every template and compiled every one of them — for ERB
    # (#393) an Erubi compile of every view in the project, per keystroke.
    it "re-runs no template transform on a publish when nothing changed on disk" do
      Dir.mktmpdir("rigor-lsp-template-warm-") do |tmpdir|
        write_template_unit_project(tmpdir)
        path = File.join(tmpdir, "lib", "app.rb")
        uri = "file://#{path}"
        buffer_table.open(uri: uri, bytes: File.read(path), version: 1)
        context = template_unit_context(tmpdir)
        publisher = publisher_for(context)

        Dir.chdir(tmpdir) do
          context.project_scan # the cold build, which is where the one compile belongs
          compiled = RigorViewDemoPlugin.transform_calls
          publisher.publish_for(uri)
          publisher.publish_for(uri)

          expect(RigorViewDemoPlugin.transform_calls).to eq(compiled)
        end
      end
    ensure
      Rigor::Plugin.unregister!("view-demo")
    end

    # ... and the other half of the trade: the carry is revalidated against the filesystem, so an edit made
    # outside the editor (a `git checkout`, another buffer's save) is compiled on the next publish without
    # anything invalidating the ProjectContext.
    #
    # Since #1047 the unit of that revalidation is the claiming plugin's WHOLE claim, not the one template:
    # a transform may read the plugin's other templates (rigor-actionpack seeds a partial's locals from the
    # views that render it), so reusing an untouched sibling's unit after an edit could serve a stale seed.
    # The bound is therefore one transform per claimed template per publish, until the owner invalidates —
    # which a save does (`didChangeWatchedFiles`), and an edit on disk IS a save. Keystrokes are not: the
    # buffer-bound path never costs the carry (see the no-change example above).
    #
    # The snapshot itself does not move: it is frozen, so it keeps seeding from the pre-edit index and the
    # claim is recompiled on every publish until then. The second edited publish pins that.
    it "recompiles the changed template's whole claim on disk, on every publish until invalidated" do
      Dir.mktmpdir("rigor-lsp-template-edited-") do |tmpdir|
        template = write_template_unit_project(tmpdir)
        File.write(File.join(File.dirname(template), "index.rbx"), "render_header(@title.upcase)\n")
        path = File.join(tmpdir, "lib", "app.rb")
        uri = "file://#{path}"
        buffer_table.open(uri: uri, bytes: File.read(path), version: 1)
        publisher = publisher_for(template_unit_context(tmpdir))

        Dir.chdir(tmpdir) do
          publisher.publish_for(uri) # warms the scan: both templates compiled once
          before = RigorViewDemoPlugin.transform_calls
          File.write(template, "render_header(@title.downcase)\n")
          publisher.publish_for(uri)
          edited = RigorViewDemoPlugin.transform_calls
          publisher.publish_for(uri)

          expect(edited - before).to eq(2)
          expect(RigorViewDemoPlugin.transform_calls - edited).to eq(2)
        end
      end
    ensure
      Rigor::Plugin.unregister!("view-demo")
    end

    # #1047 — a render site edited on disk must reach the partial it renders, on the next publish, through
    # a long-lived ProjectContext whose plugin instance memoises the render-locals index. The observable is
    # a TYPED seed: `show` passes `s: String.new`, so `s.nope_from_seed` in the partial is an undefined
    # method on String; once `show` passes a computed value instead, `s` is `Dynamic` and the row must go.
    # Before the fix the memo was never revalidated and the carry reused the partial's unit, so the row
    # survived every publish until something invalidated the context. The `invalidate!` steps pin that a
    # cold rebuild agrees with the warm answer in both directions.
    it "re-reads a render site edited on disk into the partial it renders" do
      Dir.mktmpdir("rigor-lsp-render-locals-") do |tmpdir|
        show = write_render_locals_project(tmpdir, "String.new")
        card = File.join(tmpdir, "app", "views", "users", "_card.html.erb")
        uri = "file://#{card}"
        buffer_table.open(uri: uri, bytes: File.read(card), version: 1)
        context = render_locals_context(tmpdir)
        publisher = publisher_for(context)

        Dir.chdir(tmpdir) do
          expect(published_messages(publisher, uri)).to include(a_string_including("nope_from_seed"))

          File.write(show, render_locals_show("params[:s]"))
          expect(published_messages(publisher, uri)).not_to include(a_string_including("nope_from_seed"))

          context.invalidate!
          expect(published_messages(publisher, uri)).not_to include(a_string_including("nope_from_seed"))

          File.write(show, render_locals_show("String.new(\"restored\")"))
          context.invalidate!
          expect(published_messages(publisher, uri)).to include(a_string_including("nope_from_seed"))
        end
      end
    ensure
      Rigor::Plugin.unregister!("actionpack")
    end

    # #1047 review — a warm publish offers the collector only the buffer's path, so no order of paths can
    # tell one pass from the next. Switching buffers after a render site changed on disk must still read the
    # new site, whichever way the two buffers sort; `template_units_pass_started` is what makes it so.
    it "re-reads an edited render site after switching to a buffer, in either sort direction" do
      Dir.mktmpdir("rigor-lsp-render-locals-switch-") do |tmpdir|
        uris, write_show = write_switch_project(tmpdir)
        publisher = publisher_for(render_locals_context(tmpdir))

        Dir.chdir(tmpdir) do
          # mid (cold), edit, then card — which sorts BEFORE mid.
          expect(published_messages(publisher, uris["m/_mid"])).to include(a_string_including("nope_from_seed"))
          write_show.call("params[:s]")
          expect(published_messages(publisher, uris["a/_card"])).not_to include(a_string_including("nope_from_seed"))

          # restore, then mid — which sorts AFTER card.
          write_show.call("String.new(\"back\")")
          expect(published_messages(publisher, uris["m/_mid"])).to include(a_string_including("nope_from_seed"))
        end
      end
    ensure
      Rigor::Plugin.unregister!("actionpack")
    end

    # Two partials that sort on either side of nothing in particular (`a/_card`, `m/_mid`), both open as
    # buffers, both rendered with a typed local from `z/show`. Returns their URIs and a writer for `show`.
    def write_switch_project(tmpdir)
      views = File.join(tmpdir, "app", "views")
      uris = %w[a/_card m/_mid].to_h do |name|
        path = File.join(views, "#{name}.html.erb")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "<p><%= s.nope_from_seed %></p>\n")
        buffer_table.open(uri: "file://#{path}", bytes: File.read(path), version: 1)
        [name, "file://#{path}"]
      end
      show = File.join(views, "z", "show.html.erb")
      FileUtils.mkdir_p(File.dirname(show))
      write_show = lambda do |value|
        File.write(show, %(<%= render partial: "a/card", locals: { s: #{value} } %>\n) +
                         %(<%= render partial: "m/mid", locals: { s: #{value} } %>\n))
      end
      write_show.call("String.new")
      [uris, write_show]
    end

    def published_messages(publisher, uri)
      writer.payloads.clear
      publisher.publish_for(uri)
      writer.payloads.flat_map { |payload| payload.dig(:params, :diagnostics).map { |d| d[:message] } }
    end

    def render_locals_show(value)
      %(<%= render partial: "card", locals: { s: #{value} } %>\n)
    end

    def write_render_locals_project(tmpdir, value)
      FileUtils.mkdir_p(File.join(tmpdir, "app", "views", "users"))
      File.write(File.join(tmpdir, "app", "views", "users", "_card.html.erb"), "<p><%= s.nope_from_seed %></p>\n")
      show = File.join(tmpdir, "app", "views", "users", "show.html.erb")
      File.write(show, render_locals_show(value))
      show
    end

    # rigor-actionpack, loaded the way a project loads a plugin: a file on disk that registers it, with
    # `view_type_checks:` on so the typed seed is observable as a `call.` row.
    def render_locals_context(tmpdir)
      lib = File.expand_path("../../../plugins/rigor-actionpack/lib", __dir__)
      plugin_path = File.join(tmpdir, "rigor-actionpack-lsp.rb")
      File.write(plugin_path, <<~RUBY)
        $LOAD_PATH.unshift(#{lib.inspect}) unless $LOAD_PATH.include?(#{lib.inspect})
        require "rigor-actionpack"
        Rigor::Plugin.register(Rigor::Plugin::Actionpack)
      RUBY
      Rigor::LanguageServer::ProjectContext.new(
        configuration: Rigor::Configuration.new(
          "paths" => ["app"],
          "plugins" => [{ "gem" => plugin_path, "id" => "actionpack", "config" => { "view_type_checks" => true } }]
        )
      )
    end

    # ADR-87's racy guard is what makes a carried pack trustworthy, and it only exists inside a
    # `Cache::FileDigest.with_run` scope. `ProjectContext#project_scan` is NOT inside one, so without the
    # wrap in `TemplateUnitCollector.collect_for_scan` the recording instant is taken AFTER the pack's own
    # `File.stat` and can never be racy — a write landing between the collector's read and that stat would
    # be recorded as the OLD digest beside the NEW stat tuple, and every later publish would validate it on
    # the tuple fast path and serve a unit compiled from bytes no longer on disk.
    #
    # The property is asserted on the PACK, against the moment the bytes were read, rather than by staging
    # a real write race: whether the guard can fire for a given write depends on the filesystem's timestamp
    # granularity (ADR-87's own trade, and a coarse-granularity mount is exactly what `RIGOR_STRICT_VALIDATION`
    # exists for), so a race-shaped example measures the runner's filesystem instead of this code. The
    # instant preceding the read is what the wrap is FOR, and it is platform-independent.
    it "stamps a scan-built pack with an instant taken before the template was read" do
      Dir.mktmpdir("rigor-lsp-template-racy-") do |tmpdir|
        write_template_unit_project(tmpdir)
        context = template_unit_context(tmpdir)
        read_at = capture_read_instant(File.join(tmpdir, "app", "views", "users", "show.rbx"))

        index = Dir.chdir(tmpdir) { context.project_scan.template_units }

        expect(read_at.value).not_to be_nil # the stub matched the collector's spelling of the path
        expect(recording_instant(index, "app/views/users/show.rbx")).to be <= read_at.value
      end
    ensure
      Rigor::Plugin.unregister!("view-demo")
    end

    # Notes when `target`'s bytes were read, and holds the read open long enough that an instant taken
    # after it is unmistakably later — the window a concurrent editor or `git checkout` writes into.
    def capture_read_instant(target)
      seen = Struct.new(:value).new(nil)
      allow(File).to receive(:binread).and_wrap_original do |original, *args|
        bytes = original.call(*args)
        if same_file?(args.first, target)
          seen.value = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
          sleep 0.01
        end
        bytes
      end
      seen
    end

    # The collector reads through `Dir.pwd`, which is always resolved — on macOS a tmpdir's `/var/…` and
    # pwd's `/private/var/…` are one file — and a relative spelling is a third. Both comparisons, so the
    # stub matches the path whichever way the runner spells it.
    def same_file?(candidate, target)
      candidate = candidate.to_s
      return true if File.expand_path(candidate) == File.expand_path(target)

      File.exist?(candidate) && File.identical?(candidate, target)
    end

    # The `recording_instant_ns` field of the ADR-87 pack the scan recorded for `path` (see
    # `Cache::FileDigest.pack_stat`). Read off the index's private table: it is deliberately not part of
    # the index's public surface — a stat is not an answer, only the question of whether a carried answer
    # still holds.
    def recording_instant(index, path)
      Integer(index.instance_variable_get(:@stats).fetch(path).split.fetch(5), 10)
    end

    def publisher_for(context)
      described_class.new(writer: writer, buffer_table: buffer_table, project_context: context)
    end

    def fixture_plugin_path
      File.expand_path("../../fixtures/template_units/view_demo_plugin.rb", __dir__)
    end

    # A view class, a template on disk whose saved bytes are CLEAN, and the fixture plugin that claims it.
    # @return the template's absolute path — the way the editor names a buffer.
    def write_template_unit_project(tmpdir)
      FileUtils.mkdir_p(File.join(tmpdir, "lib"))
      File.write(File.join(tmpdir, "lib", "app.rb"), <<~RUBY)
        class ViewContext
          def render_header(text)
            text
          end
        end
      RUBY
      path = File.join(tmpdir, "app", "views", "users", "show.rbx")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "render_header(@title.upcase)\n")
      path
    end

    # `ProjectContext` takes no `plugin_requirer:`, so the plugin loads the way a project loads one: a file
    # on disk that registers itself, named by the configuration's `plugins:` entry.
    def template_unit_context(tmpdir)
      plugin_path = File.join(tmpdir, "rigor-view-demo.rb")
      File.write(plugin_path, "#{File.read(fixture_plugin_path)}\nRigor::Plugin.register(RigorViewDemoPlugin)\n")
      Rigor::LanguageServer::ProjectContext.new(
        configuration: Rigor::Configuration.new(
          "paths" => ["lib"], "plugins" => [{ "gem" => plugin_path, "id" => "view-demo" }]
        )
      )
    end

    it "uses 0-based line / character positions per LSP spec" do
      Dir.mktmpdir("rigor-lsp-publish-zerobased-") do |tmpdir|
        path = File.join(tmpdir, "foo.rb")
        uri = "file://#{path}"
        # Parse error fires on line 1 of the buffer; LSP expects line: 0 (0-based).
        buffer_table.open(uri: uri, bytes: "def broken\n", version: 1)

        Dir.chdir(tmpdir) { publisher.publish_for(uri) }

        diag = writer.payloads.first.dig(:params, :diagnostics).first
        # Rigor: line 1, col 11 (1-based). LSP: line 0, character 10.
        expect(diag[:range][:start][:line]).to be >= 0
        expect(diag[:range][:start][:character]).to be >= 0
      end
    end
  end

  # Issue #142 — N dirty buffers published across the fork-based worker pool in one dispatch instead of one
  # Runner call at a time. `#publish_many` is the entry point the `PublishBatcher` (`@batcher`) drives once
  # several buffers' debounce timers elapse close together (see the "batch coalescing" section below); it is
  # also directly callable, which is how these specs exercise it deterministically.
  describe "#publish_many" do
    def context_for(dir)
      Rigor::LanguageServer::ProjectContext.new(configuration: Rigor::Configuration.new("paths" => [dir]))
    end

    def publisher_for(context, table = buffer_table, out_writer = writer)
      described_class.new(writer: out_writer, buffer_table: table, project_context: context)
    end

    # Every file is BROKEN on disk (an undefined-method call unique to that file) and FIXED in its own
    # buffer only. A worker that read the on-disk file instead of the buffer — the #142 buffer-substitution
    # risk — would surface `call.undefined-method`; a worker fed a SIBLING'S buffer bytes would surface a
    # DIFFERENT undefined-method name than its own path has ever produced. Either failure mode is visible.
    def write_multi_buffer_fixture(dir, count)
      Array.new(count) do |i|
        path = File.join(dir, "f#{i}.rb")
        File.write(path, "class F#{i}\n  def go\n    disk_only_undefined_#{i}\n  end\nend\n")
        [path, "file://#{path}", "class F#{i}\n  def go\n    #{i}\n  end\nend\n"]
      end
    end

    it "publishes N buffers' OWN diagnostics — none see the on-disk break, only their own buffer's fix" do
      Dir.mktmpdir("rigor-lsp-publish-many-") do |dir|
        entries = write_multi_buffer_fixture(dir, 4)
        entries.each { |_path, uri, bytes| buffer_table.open(uri: uri, bytes: bytes, version: 1) }
        uris = entries.map { |_path, uri, _bytes| uri }

        Dir.chdir(dir) { publisher_for(context_for(dir)).publish_many(uris) }

        uris.each do |uri|
          payload = writer.payloads.find { |p| p.dig(:params, :uri) == uri }
          expect(payload.dig(:params, :diagnostics)).to eq([]), "#{uri}: #{payload.inspect}"
        end
      end
    end

    it "matches publishing the same buffers one at a time, byte-for-byte" do
      Dir.mktmpdir("rigor-lsp-publish-many-equiv-") do |dir|
        entries = write_multi_buffer_fixture(dir, 4)
        uris = entries.map { |_path, uri, _bytes| uri }
        context = context_for(dir)

        table_batched = Rigor::LanguageServer::BufferTable.new
        table_sequential = Rigor::LanguageServer::BufferTable.new
        entries.each do |_path, uri, bytes|
          table_batched.open(uri: uri, bytes: bytes, version: 1)
          table_sequential.open(uri: uri, bytes: bytes, version: 1)
        end
        writer_batched = build_writer
        writer_sequential = build_writer

        Dir.chdir(dir) { publisher_for(context, table_batched, writer_batched).publish_many(uris) }
        Dir.chdir(dir) do
          publisher = publisher_for(context, table_sequential, writer_sequential)
          uris.each { |uri| publisher.publish_for(uri) }
        end

        uris.each do |uri|
          batched = writer_batched.payloads.find { |p| p.dig(:params, :uri) == uri }&.dig(:params, :diagnostics)
          sequential = writer_sequential.payloads.find { |p| p.dig(:params, :uri) == uri }&.dig(:params, :diagnostics)
          expect(batched).to eq(sequential)
        end
      end
    end

    # BufferPoolDispatcher may still take its OWN sequential-in-process path internally below its size
    # gate (`DEFAULT_MIN_BATCH_SIZE`) — that's a separate, dispatcher-level concern covered in
    # `spec/rigor/analysis/runner/buffer_pool_dispatcher_spec.rb`. What THIS proves is the publisher-level
    # claim: N eligible URIs become ONE dispatcher call, not N.
    it "dispatches every eligible URI through ONE BufferPoolDispatcher call, not N separate ones" do
      Dir.mktmpdir("rigor-lsp-publish-many-dispatch-") do |dir|
        entries = write_multi_buffer_fixture(dir, 3)
        entries.each { |_path, uri, bytes| buffer_table.open(uri: uri, bytes: bytes, version: 1) }
        uris = entries.map { |_path, uri, _bytes| uri }

        allow(Rigor::Analysis::Runner::BufferPoolDispatcher).to receive(:new).and_call_original

        Dir.chdir(dir) { publisher_for(context_for(dir)).publish_many(uris) }

        expect(Rigor::Analysis::Runner::BufferPoolDispatcher).to have_received(:new).once
      end
    end

    it "degrades to the single-buffer path when only one URI is eligible after filtering" do
      Dir.mktmpdir("rigor-lsp-publish-many-single-") do |dir|
        entries = write_multi_buffer_fixture(dir, 2)
        _path0, uri0, bytes0 = entries[0]
        _path1, uri1, bytes1 = entries[1]
        buffer_table.open(uri: uri0, bytes: bytes0, version: 1)
        buffer_table.open(uri: uri1, bytes: bytes1, version: 1)
        buffer_table.close(uri: uri1) # closed before the batch runs — only uri0 stays eligible

        allow(Rigor::Analysis::Runner::BufferPoolDispatcher).to receive(:new)

        Dir.chdir(dir) { publisher_for(context_for(dir)).publish_many([uri0, uri1]) }

        expect(Rigor::Analysis::Runner::BufferPoolDispatcher).not_to have_received(:new)
        payload = writer.payloads.find { |p| p.dig(:params, :uri) == uri0 }
        expect(payload.dig(:params, :diagnostics)).to eq([])
        expect(writer.payloads.any? { |p| p.dig(:params, :uri) == uri1 }).to be(false)
      end
    end

    it "excludes a buffer closed during the debounce window and publishes an empty set for a desynchronised one" do
      Dir.mktmpdir("rigor-lsp-publish-many-guards-") do |dir|
        entries = write_multi_buffer_fixture(dir, 3)
        entries.each { |_path, uri, bytes| buffer_table.open(uri: uri, bytes: bytes, version: 1) }
        uris = entries.map { |_path, uri, _bytes| uri }
        closed_uri = uris[0]
        desync_uri = uris[1]
        buffer_table.close(uri: closed_uri)
        buffer_table.apply_changes(
          uri: desync_uri,
          changes: [{ range: { start: { line: 0 }, end: { line: 0, character: 0 } }, text: "x" }],
          version: 2
        )

        Dir.chdir(dir) { publisher_for(context_for(dir)).publish_many(uris) }

        expect(writer.payloads.any? { |p| p.dig(:params, :uri) == closed_uri }).to be(false)
        desync_payload = writer.payloads.find { |p| p.dig(:params, :uri) == desync_uri }
        expect(desync_payload.dig(:params, :diagnostics)).to eq([])
      end
    end

    it "no-ops when every URI is ineligible" do
      publisher.publish_many(["file:///not/in/table.rb", "untitled:foo"])
      expect(writer.payloads).to be_empty
    end
  end

  describe "debouncer integration (slice 8)" do
    let(:debouncer) { Rigor::LanguageServer::Debouncer.new }
    let(:debounced_publisher) do
      described_class.new(
        writer: writer, buffer_table: buffer_table, project_context: project_context,
        debouncer: debouncer, debounce_seconds: 0
      )
    end

    it "delivers exactly ONE notification for a burst of publish_for calls (last write wins)" do
      Dir.mktmpdir("rigor-lsp-debounce-") do |tmpdir|
        path = File.join(tmpdir, "foo.rb")
        uri = "file://#{path}"
        buffer_table.open(uri: uri, bytes: "x = 1\n", version: 1)

        Dir.chdir(tmpdir) do
          # Five rapid publish_for calls — only one should fire.
          5.times { debounced_publisher.publish_for(uri) }
          debouncer.flush!
        end

        expect(writer.payloads.size).to eq(1)
      end
    end

    it "drops the publish when the buffer is closed during the debounce window" do
      Dir.mktmpdir("rigor-lsp-debounce-close-") do |tmpdir|
        path = File.join(tmpdir, "foo.rb")
        uri = "file://#{path}"
        buffer_table.open(uri: uri, bytes: "def broken\n", version: 1)

        # Schedule with a small delay so we can close before fire.
        publisher_with_delay = described_class.new(
          writer: writer, buffer_table: buffer_table, project_context: project_context,
          debouncer: debouncer, debounce_seconds: 0.05
        )
        Dir.chdir(tmpdir) do
          publisher_with_delay.publish_for(uri)
          buffer_table.close(uri: uri) # close before debounce fires
          debouncer.flush!
        end

        expect(writer.payloads).to be_empty
      end
    end

    # Issue #142 — a burst of `publish_for` calls for DIFFERENT URIs (a workspace-wide rename, a git branch
    # switch that touches many open files) coalesces into batched `#publish_many` round(s) via the
    # `PublishBatcher` each publisher owns, rather than firing N independent, GVL-serialized threads. The
    # coalescing MECHANICS (single-flight, dedup, error recovery) are unit-tested independently in
    # `spec/rigor/language_server/publish_batcher_spec.rb`; these specs cover the WIRING — that `publish_for`
    # really does route through the batcher and really does end up calling `#publish_many`.
    describe "batch coalescing across URIs" do
      def context_for(dir)
        Rigor::LanguageServer::ProjectContext.new(configuration: Rigor::Configuration.new("paths" => [dir]))
      end

      it "publishes every buffer in a burst of different-URI publish_for calls" do
        Dir.mktmpdir("rigor-lsp-coalesce-") do |dir|
          paths = Array.new(3) { |i| File.join(dir, "g#{i}.rb") }
          uris = paths.map { |p| "file://#{p}" }
          paths.each_with_index do |path, i|
            File.write(path, "class G#{i}\n  def go\n    disk_only_undefined_#{i}\n  end\nend\n")
          end
          publisher = described_class.new(
            writer: writer, buffer_table: buffer_table, project_context: context_for(dir),
            debouncer: debouncer, debounce_seconds: 0
          )
          uris.each_with_index do |uri, i|
            buffer_table.open(uri: uri, bytes: "class G#{i}\n  def go\n    #{i}\n  end\nend\n", version: 1)
          end

          Dir.chdir(dir) do
            uris.each { |uri| publisher.publish_for(uri) }
            debouncer.flush!
          end

          uris.each do |uri|
            payload = writer.payloads.find { |p| p.dig(:params, :uri) == uri }
            expect(payload.dig(:params, :diagnostics)).to eq([]), "#{uri}: #{payload.inspect}"
          end
        end
      end

      # Proves the WIRING: a URI whose debounce timer elapses drives the publisher's OWN `@batcher`, which in
      # turn calls back into `#publish_many` — not some other code path. Driven directly (no real Debouncer
      # thread) via the batcher's public `#enqueue`, matching how the debounced block in `#publish_for` calls
      # it.
      it "routes a ready URI through @batcher into #publish_many" do
        uri = "file:///a.rb"
        allow(debounced_publisher).to receive(:publish_many)

        debounced_publisher.instance_variable_get(:@batcher).enqueue(uri)

        expect(debounced_publisher).to have_received(:publish_many).with([uri])
      end

      it "a batch round that raises does not stop the NEXT publish from going through" do
        Dir.mktmpdir("rigor-lsp-coalesce-rescue-") do |dir|
          path = File.join(dir, "h.rb")
          uri_a = "file:///does-not-matter-a.rb"
          uri_b = "file://#{path}"
          File.write(path, "x = 1\n")
          allow(debounced_publisher).to receive(:publish_many).and_raise(StandardError, "boom")
          allow(debounced_publisher).to receive(:warn)
          batcher = debounced_publisher.instance_variable_get(:@batcher)

          batcher.enqueue(uri_a)

          expect(debounced_publisher).to have_received(:warn).with(a_string_including("boom"))

          allow(debounced_publisher).to receive(:publish_many).and_call_original
          buffer_table.open(uri: uri_b, bytes: "x = 1\n", version: 1)
          Dir.chdir(dir) { batcher.enqueue(uri_b) }

          expect(debounced_publisher).to have_received(:publish_many).with([uri_b])
        end
      end
    end
  end

  describe "#to_lsp_diagnostic" do
    it "converts 1-based Rigor positions to 0-based LSP positions" do
      diag = Rigor::Analysis::Diagnostic.new(
        path: "/a.rb", line: 3, column: 7, message: "test",
        severity: :error, rule: "x"
      )
      result = publisher.send(:to_lsp_diagnostic, diag, "/a.rb")
      expect(result[:range][:start][:line]).to eq(2)
      expect(result[:range][:start][:character]).to eq(6)
    end

    it "returns nil when the diagnostic path does not match buffer_path" do
      diag = Rigor::Analysis::Diagnostic.new(
        path: "/other.rb", line: 1, column: 1, message: "test",
        severity: :error, rule: "x"
      )
      expect(publisher.send(:to_lsp_diagnostic, diag, "/a.rb")).to be_nil
    end

    it "uses SEVERITY_MAP and falls back to :info (3) for unmapped severities" do
      diag = Rigor::Analysis::Diagnostic.new(
        path: "/a.rb", line: 1, column: 1, message: "test",
        severity: :unknown_tier, rule: "x"
      )
      result = publisher.send(:to_lsp_diagnostic, diag, "/a.rb")
      expect(result[:severity]).to eq(3)
    end
  end

  describe "#cancel_pending" do
    let(:debouncer) { Rigor::LanguageServer::Debouncer.new }
    let(:debounced_publisher) do
      described_class.new(
        writer: writer, buffer_table: buffer_table, project_context: project_context,
        debouncer: debouncer, debounce_seconds: 0.5
      )
    end

    it "cancels in-flight debounced tasks" do
      buffer_table.open(uri: "file:///tmp/x.rb", bytes: "x = 1", version: 1)
      debounced_publisher.publish_for("file:///tmp/x.rb")
      debounced_publisher.cancel_pending

      # Wait past the original delay window; no notification fires.
      sleep 0.05
      expect(writer.payloads).to be_empty
    end
  end

  describe "#publish_empty" do
    it "pushes an empty diagnostics array for the URI" do
      publisher.publish_empty("file:///x.rb")

      expect(writer.payloads).to eq([
                                      {
                                        method: "textDocument/publishDiagnostics",
                                        params: { uri: "file:///x.rb", diagnostics: [] }
                                      }
                                    ])
    end
  end

  # #246 — the save round. Analysis scope is the whole project; the PUBLISH SET is the open, clean buffers.
  describe "#publish_project" do
    # `widget.rb` returns a String and `other.rb` calls `upcase` on it — clean. Editing widget's return to an
    # Integer makes the diagnostic appear in OTHER.rb, which is the whole point: a single-file publish for
    # widget can never report it.
    def write_project(dir, widget_body)
      File.write(File.join(dir, "widget.rb"), "class Widget\n  def name\n    #{widget_body}\n  end\nend\n")
      File.write(File.join(dir, "other.rb"), "class Other\n  def go\n    Widget.new.name.upcase\n  end\nend\n")
    end

    def context_for(dir)
      Rigor::LanguageServer::ProjectContext.new(
        configuration: Rigor::Configuration.new("paths" => [dir])
      )
    end

    def publisher_for(context)
      described_class.new(writer: writer, buffer_table: buffer_table, project_context: context)
    end

    def diagnostics_for(uri)
      payload = writer.payloads.rfind { |p| p.dig(:params, :uri) == uri }
      payload&.dig(:params, :diagnostics)
    end

    it "publishes a saved file's effect on a dependent that is open in another buffer" do
      Dir.mktmpdir("rigor-lsp-round-") do |dir|
        write_project(dir, "1")
        widget = "file://#{File.join(dir, 'widget.rb')}"
        other  = "file://#{File.join(dir, 'other.rb')}"
        buffer_table.open(uri: widget, bytes: File.read(File.join(dir, "widget.rb")), version: 1)
        buffer_table.open(uri: other, bytes: File.read(File.join(dir, "other.rb")), version: 1)

        Dir.chdir(dir) { publisher_for(context_for(dir)).publish_project(widget) }

        expect(diagnostics_for(other)).not_to be_empty
        expect(diagnostics_for(other).first[:message]).to include("undefined method `upcase'")
        # The saved buffer itself is clean, so it is published too — with its own (empty) slice.
        expect(diagnostics_for(widget)).to eq([])
      end
    end

    it "excludes a dirty buffer, whose markers only its own analysis may set" do
      Dir.mktmpdir("rigor-lsp-round-dirty-") do |dir|
        write_project(dir, "1")
        widget = "file://#{File.join(dir, 'widget.rb')}"
        other  = "file://#{File.join(dir, 'other.rb')}"
        buffer_table.open(uri: widget, bytes: File.read(File.join(dir, "widget.rb")), version: 1)
        buffer_table.open(uri: other, bytes: File.read(File.join(dir, "other.rb")), version: 1)
        # The user is mid-edit in other.rb — this round analysed the file on DISK, so it may not speak for it.
        buffer_table.change(uri: other, bytes: "class Other\nend\n", version: 2)

        Dir.chdir(dir) { publisher_for(context_for(dir)).publish_project(widget) }

        expect(diagnostics_for(other)).to be_nil
        expect(diagnostics_for(widget)).to eq([])
      end
    end

    it "publishes nothing when the context was invalidated while the round ran" do
      Dir.mktmpdir("rigor-lsp-round-gen-") do |dir|
        write_project(dir, "1")
        widget = "file://#{File.join(dir, 'widget.rb')}"
        buffer_table.open(uri: widget, bytes: File.read(File.join(dir, "widget.rb")), version: 1)
        context = context_for(dir)
        # A watched-file change lands mid-analysis: the world these diagnostics describe is gone.
        allow(context).to receive(:project_diagnostics).and_wrap_original do |original, *args|
          result = original.call(*args)
          context.invalidate!
          result
        end

        Dir.chdir(dir) { publisher_for(context).publish_project(widget) }

        expect(writer.payloads).to be_empty
      end
    end

    it "runs one round at a time and collapses a burst into one extra round" do
      Dir.mktmpdir("rigor-lsp-round-flight-") do |dir|
        write_project(dir, '"w"')
        widget = "file://#{File.join(dir, 'widget.rb')}"
        buffer_table.open(uri: widget, bytes: File.read(File.join(dir, "widget.rb")), version: 1)
        context = context_for(dir)
        publisher = publisher_for(context)
        rounds = 0
        concurrent = false
        running = false
        allow(context).to receive(:project_diagnostics).and_wrap_original do |original, *args|
          concurrent ||= running
          running = true
          rounds += 1
          # Re-entering while this round is in flight must NOT start a second one.
          publisher.publish_project(widget) if rounds == 1
          result = original.call(*args)
          running = false
          result
        end

        Dir.chdir(dir) { publisher.publish_project(widget) }

        expect(concurrent).to be(false)
        expect(rounds).to eq(2) # the in-flight round plus exactly one re-run for the save that arrived
      end
    end
  end
end
