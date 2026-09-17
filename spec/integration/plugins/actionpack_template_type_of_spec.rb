# frozen_string_literal: true

# #1040 — `rigor type-of` on a real ERB template through rigor-actionpack, under both compile paths the
# plugin has: stdlib `ERB` (what this bundle resolves) and an Erubi-shaped compile (Erubi is never a Rigor
# dependency, so CI cannot install it; the compile is stubbed with Erubi's output SHAPE, as the
# view-units spec already does for its prologue measurement).
#
# The two compilers place the same tag bodies very differently — stdlib `ERB` escapes text newlines inside
# a double-quoted literal and starts each line's code with `;`, Erubi keeps text newlines raw inside a
# single-quoted literal that spans lines — and the probe must answer the same thing under both.

require "spec_helper"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"

TEMPLATE_TYPE_OF_ACTIONPACK_LIB = File.expand_path("../../../plugins/rigor-actionpack/lib", __dir__)
$LOAD_PATH.unshift(TEMPLATE_TYPE_OF_ACTIONPACK_LIB) unless $LOAD_PATH.include?(TEMPLATE_TYPE_OF_ACTIONPACK_LIB)
require "rigor-actionpack"

TEMPLATE_TYPE_OF_SHOW_ERB = <<~ERB
  <h1>Users</h1>
  <p><%= @user.name %></p>
  <p><%= @user.name %> of <%= @user.email %></p>
  <%= @user.email %><%= @user.email %>
ERB

TEMPLATE_TYPE_OF_LAYOUT_ERB = <<~ERB
  <body>
  <%= yield %>
  </body>
ERB

RSpec.describe "plugins/rigor-actionpack — rigor type-of on an ERB template (#1040)" do
  let(:dir) { Dir.mktmpdir("rigor-1040-erb-") }
  let(:compiler) { Rigor::Plugin::Actionpack::ErbCompiler }

  before do
    Rigor::Plugin.unregister!
    Rigor::Plugin.register(Rigor::Plugin::Actionpack)
    compiler.reset!
    write("sig/user.rbs", "class User\n  def name: () -> String\n  def email: () -> String\nend\n")
    write("app/controllers/users_controller.rb", <<~RUBY)
      class UsersController < ActionController::Base
        def show
          @user = User.new
        end
      end
    RUBY
    write("app/views/users/show.html.erb", TEMPLATE_TYPE_OF_SHOW_ERB)
    write("app/views/layouts/application.html.erb", TEMPLATE_TYPE_OF_LAYOUT_ERB)
    write(".rigor.yml", "plugins:\n  - gem: rigor-actionpack\n    id: actionpack\n")
  end

  after do
    compiler.reset!
    Rigor::Plugin.unregister!
    FileUtils.remove_entry(dir)
  end

  def write(relative, contents)
    path = File.join(dir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
  end

  def run_cli(*argv)
    out = StringIO.new
    err = StringIO.new
    status = Dir.chdir(dir) { Rigor::CLI.start(argv, out: out, err: err) }
    [status, out.string, err.string]
  end

  # Erubi's output shape: a one-line prologue with no newline of its own, text appended as a single-quoted
  # literal whose newlines stay RAW (so a text chunk spans compiled lines), and `( expr ).to_s` per output
  # tag.
  def erubi_shaped(text)
    src = +"_buf = ::String.new;"
    position = 0
    text.to_enum(:scan, /<%(=+)?(.*?)%>/m).each do
      match = Regexp.last_match
      append_text(src, text[position...match.begin(0)])
      src << (match[1] ? " _buf << (#{match[2]}).to_s;" : "#{match[2]};")
      position = match.end(0)
    end
    append_text(src, text[position..])
    src << "\n_buf.to_s\n"
  end

  def append_text(src, chunk)
    return if chunk.nil? || chunk.empty?

    src << " _buf << '#{chunk.gsub(/['\\]/) { |char| "\\#{char}" }}'.freeze;"
  end

  shared_examples "a template position probe" do
    it "answers `<%= @user.name %>` at the column of `name` with the method's type" do
      status, out, err = run_cli("type-of", "app/views/users/show.html.erb:2:14")

      expect(err).to eq("")
      expect(status).to eq(0)
      expect(out).to include("app/views/users/show.html.erb:2:14", "node:    Prism::CallNode", "type:    String")
    end

    it "answers the receiver under the controller's ivar seed" do
      status, out, _err = run_cli("type-of", "app/views/users/show.html.erb:2:8")

      expect(status).to eq(0)
      expect(out).to include("node:    Prism::InstanceVariableReadNode", "type:    User")
    end

    it "declines a position inside HTML text with a clear message" do
      status, out, err = run_cli("type-of", "app/views/users/show.html.erb:2:2", "app/views/users/show.html.erb:1:6")

      expect(status).to eq(1)
      expect(out).to eq("")
      expect(err.lines.length).to eq(2)
      expect(err).to include("no expression found at app/views/users/show.html.erb:2:2: the position is in " \
                             "template markup")
      expect(err).to include("no expression found at app/views/users/show.html.erb:1:6")
    end

    it "resolves each expression on a multi-expression line to its own tag" do
      status, out, err = run_cli("type-of", "--format=json", "app/views/users/show.html.erb:3:14",
                                 "app/views/users/show.html.erb:3:35")

      expect(err).to eq("")
      expect(status).to eq(0)
      results = JSON.parse(out).fetch("results")
      expect(results.map { |row| [row["column"], row["type"]] }).to eq([[14, "String"], [35, "String"]])
    end

    it "lists a multi-expression line's expressions at their template columns" do
      status, out, err = run_cli("type-of", "app/views/users/show.html.erb:3")

      expect(err).to eq("")
      expect(status).to eq(0)
      expect(out.lines.drop(1).map(&:split)).to eq(
        [
          %w[8 CallNode String],
          %w[8 InstanceVariableReadNode User],
          %w[29 CallNode String],
          %w[29 InstanceVariableReadNode User]
        ]
      )
    end

    it "declines a position whose bytes were copied to more than one place" do
      status, _out, err = run_cli("type-of", "app/views/users/show.html.erb:4:12")

      expect(status).to eq(1)
      expect(err).to include("copied to more than one place")
    end

    # The plugin rewrites the `yield` keyword into a helper call, so the compiled node is not made of the
    # template's bytes: the probe declines rather than answering about `__rigor_yield`.
    it "declines a layout's rewritten `<%= yield %>`, in both forms, instead of exiting on a parse error" do
      status, out, err = run_cli("type-of", "app/views/layouts/application.html.erb:2:5",
                                 "app/views/layouts/application.html.erb:2")

      expect(status).to eq(1)
      expect(out).to eq("")
      expect(err).to include("no expression found at app/views/layouts/application.html.erb:2:5",
                             "no expression found on app/views/layouts/application.html.erb:2")
      expect(err).not_to include("parse")
    end
  end

  context "when compiled by stdlib ERB" do
    it_behaves_like "a template position probe"
  end

  context "when compiled in Erubi's shape" do
    before do
      allow(compiler).to receive(:compile_source) { |text| erubi_shaped(text) }
    end

    it "really compiles through the Erubi shape, with its prologue on the template's first line" do
      source, map, = compiler.compile(TEMPLATE_TYPE_OF_SHOW_ERB)

      expect(source.lines.first).to start_with("_buf = ::String.new; _buf << '<h1>Users</h1>")
      expect(map[2]).to eq(2)
    end

    it_behaves_like "a template position probe"
  end

  # `dump_type` has no probe path of its own: it is a `rigor check` diagnostic, so it already runs on the
  # compiled unit under the seeded scope and reports at the template line.
  it "reports `Rigor.dump_type` inside the template at the template's line under rigor check" do
    write("app/views/users/show.html.erb", "<h1>Users</h1>\n<% Rigor.dump_type(@user) %>\n")
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => ["app"], "plugins" => [{ "gem" => "rigor-actionpack", "id" => "actionpack" }]
      )
    )

    diagnostics = Dir.chdir(dir) do
      runner = Rigor::Analysis::Runner.new(
        configuration: configuration, cache_store: nil,
        plugin_requirer: ->(_name) { true }
      )
      guarded_run(runner, ["app"]).diagnostics
    end
    dumps = diagnostics.select { |d| d.rule == "dump.type" }

    expect(dumps.map { |d| [d.path, d.line, d.message] })
      .to eq([["app/views/users/show.html.erb", 2, "dump_type: User"]])
  end
end
