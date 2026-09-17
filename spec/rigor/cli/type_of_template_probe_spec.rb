# frozen_string_literal: true

require "fileutils"
require "json"
require "stringio"
require "tmpdir"

require "rigor"
require "rigor/cli"
require_relative "../../fixtures/template_units/view_demo_plugin"

TYPE_OF_TEMPLATE_VIEW_DEMO_FILE = File.expand_path("../../fixtures/template_units/view_demo_plugin.rb", __dir__)

# #1040 — `rigor type-of` against a template unit, on the identity-plus-banner fixture transform. The banner
# puts every compiled line one below its template line, so a probe that read the template from disk, or
# that forgot the line map, answers about the wrong node — which is what the issue measured.
RSpec.describe "rigor type-of on a template unit (#1040)" do
  let(:dir) { Dir.mktmpdir("rigor-1040-") }

  before do
    Rigor::Plugin.unregister!("view-demo")
    Rigor::Plugin.register(RigorViewDemoPlugin)
    FileUtils.mkdir_p(File.join(dir, "app", "views", "users"))
    FileUtils.mkdir_p(File.join(dir, "sig"))
    FileUtils.mkdir_p(File.join(dir, "lib"))
    File.write(File.join(dir, "sig", "app.rbs"), <<~RBS)
      class User
        def name: () -> String
      end

      class ViewContext
        def render_header: (String) -> String
      end
    RBS
    # `gem:` names the fixture file itself: the spec has already required it, so the loader's require is a
    # no-op and the explicit `id:` resolves the class this `before` registered.
    File.write(File.join(dir, ".rigor.yml"), <<~YAML)
      plugins:
        - gem: #{TYPE_OF_TEMPLATE_VIEW_DEMO_FILE}
          id: view-demo
    YAML
  end

  after do
    Rigor::Plugin.unregister!("view-demo")
    FileUtils.remove_entry(dir)
  end

  def write_template(body)
    File.write(File.join(dir, "app", "views", "users", "show.rbx"), body)
  end

  def run_cli(*argv)
    out = StringIO.new
    err = StringIO.new
    status = Dir.chdir(dir) { Rigor::CLI.start(argv, out: out, err: err) }
    [status, out.string, err.string]
  end

  it "answers about the compiled node under the unit's declared self and ivar seeds" do
    write_template("render_header(@user.name)\n")

    status, out, err = run_cli("type-of", "app/views/users/show.rbx:1:21")

    expect(err).to eq("")
    expect(status).to eq(0)
    expect(out).to eq(<<~TEXT)
      app/views/users/show.rbx:1:21
      node:    Prism::CallNode
      type:    String
      erased:  String
    TEXT
  end

  # `size` parses as a local only because the unit's locals are passed to Prism as an enclosing scope.
  it "types a seeded local as the local, not as a method call" do
    write_template("size.upcase\n")

    status, out, _err = run_cli("type-of", "app/views/users/show.rbx:1:1")

    expect(status).to eq(0)
    expect(out).to include("node:    Prism::LocalVariableReadNode", "type:    String")
  end

  it "lists a line's expressions at the template's own columns" do
    write_template("size.upcase; @user.name\n")

    status, out, err = run_cli("type-of", "app/views/users/show.rbx:1")

    expect(err).to eq("")
    expect(status).to eq(0)
    expect(out.lines.map(&:split)).to eq(
      [
        ["app/views/users/show.rbx:1"],
        %w[1 CallNode String],
        %w[1 LocalVariableReadNode String],
        %w[14 CallNode String],
        %w[14 InstanceVariableReadNode User]
      ]
    )
  end

  it "reports a --trace fallback at the template line, not at the compiled one" do
    write_template("size\n@user.nope\n")

    status, out, _err = run_cli("type-of", "--trace", "--format=json", "app/views/users/show.rbx:2:7")

    expect(status).to eq(0)
    fallbacks = JSON.parse(out).fetch("fallbacks")
    expect(fallbacks).not_to be_empty
    expect(fallbacks.map { |event| [event["line"], event["column"]] }).to all(eq([2, 1]))
  end

  it "range-checks against the template's lines, with the exit status a Ruby probe gives" do
    write_template("size\n")

    status, _out, err = run_cli("type-of", "app/views/users/show.rbx:2:1")

    expect(status).to eq(Rigor::CLI::EXIT_USAGE)
    expect(err).to eq("type-of: line 2 is past the end of the source buffer\n")
  end

  it "declines a column past the end of the line rather than answering about the next compiled byte" do
    write_template("size\n")

    status, _out, err = run_cli("type-of", "app/views/users/show.rbx:1:9")

    expect(status).to eq(1)
    expect(err).to include("no expression found at app/views/users/show.rbx:1:9")
  end

  describe "a file that is not a template unit" do
    def plain_probe(with_plugin:)
      File.write(File.join(dir, ".rigor.yml"), "plugins: []\n") unless with_plugin
      File.write(File.join(dir, "lib", "plain.rb"), "a = [1, 2]\na.first\n")
      run_cli("type-of", "lib/plain.rb:2:3", "lib/plain.rb:2")
    end

    it "probes a .rb file byte-identically, and never builds the template index for it" do
      write_template("size\n")
      calls = RigorViewDemoPlugin.transform_calls
      with_plugin = plain_probe(with_plugin: true)
      expect(RigorViewDemoPlugin.transform_calls).to eq(calls)

      expect(with_plugin).to eq(plain_probe(with_plugin: false))
      expect(with_plugin.first).to eq(0)
    end

    it "keeps today's parse error for a non-Ruby file no plugin claims" do
      File.write(File.join(dir, "lib", "notes.erb"), "<%= 1 %>\n")

      status, _out, err = run_cli("type-of", "lib/notes.erb:1:5")

      expect(status).to eq(1)
      expect(err).to start_with("lib/notes.erb:1: ")
    end
  end
end
