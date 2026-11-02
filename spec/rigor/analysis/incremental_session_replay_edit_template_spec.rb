# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "../../fixtures/template_units/view_demo_plugin"

# Issue #2233 (review of #2658) — an editor buffer for a claimed template, replayed as an edit under
# `--incremental`. The session admitted the buffer's logical path to the `.rb` set and the run then also
# appended the template's unit, so one diagnostic was reported twice whenever `--instead-of` was absolute.
RSpec.describe Rigor::Analysis::IncrementalSession, "#replay_edit" do
  after { Rigor::Plugin.unregister!("view-demo") }

  def write_project(dir)
    FileUtils.mkdir_p(File.join(dir, "lib"))
    FileUtils.mkdir_p(File.join(dir, "app", "views", "users"))
    File.write(File.join(dir, "lib", "app.rb"),
               "class User; def name; 'a'; end; end\nclass ViewContext; def render_header(t); t; end; end\n")
    File.write(File.join(dir, "app", "views", "users", "show.rbx"), "render_header(@title)\n")
  end

  def configuration
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge(
                               "paths" => ["lib"], "exclude" => [], "plugins" => ["rigor-view-demo"],
                               "parallel" => { "workers" => 0 }
                             ))
  end

  # The buffer's diagnostics from an edit replay of the warm baseline, with the editor's bytes at `logical`.
  def buffer_diagnostics(dir, logical)
    buffer_path = File.join(dir, "buffer.rbx")
    File.write(buffer_path, "render_header(@title.nope_from_buffer)\n")
    session = described_class.new(
      configuration: configuration, paths: ["lib"],
      plugin_requirer: ->(_name) { Rigor::Plugin.register(RigorViewDemoPlugin) }
    )
    guarded_baseline(session)
    recheck = session.replay_edit(Rigor::Analysis::BufferBinding.new(logical_path: logical, physical_path: buffer_path))
    recheck.diagnostics.select { |diagnostic| diagnostic.method_name == "nope_from_buffer" }
  end

  it "reports a template buffer once when --instead-of is relative" do
    Dir.mktmpdir("rigor-template-buffer-") do |dir|
      write_project(dir)
      Dir.chdir(dir) do
        found = buffer_diagnostics(dir, "app/views/users/show.rbx")

        expect(found.map(&:path)).to eq(["app/views/users/show.rbx"])
      end
    end
  end

  it "reports a template buffer once when --instead-of is absolute" do
    Dir.mktmpdir("rigor-template-buffer-") do |dir|
      write_project(dir)
      Dir.chdir(dir) do
        found = buffer_diagnostics(dir, File.join(Dir.pwd, "app", "views", "users", "show.rbx"))

        expect(found.map(&:path)).to eq(["app/views/users/show.rbx"])
      end
    end
  end
end
