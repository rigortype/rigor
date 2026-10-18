# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

SINATRA_CENSUS_PLUGIN_LIB = File.expand_path("../../plugins/rigor-sinatra/lib", __dir__)
$LOAD_PATH.unshift(SINATRA_CENSUS_PLUGIN_LIB) unless $LOAD_PATH.include?(SINATRA_CENSUS_PLUGIN_LIB)
require "rigor-sinatra"

# Issue #1768 — the ADR-58 class-ivar census skipped writes inside an ADR-16 `block_as_methods:` block. A plugin entry
# with the default `:receiver_instance` binding declares that `get "/" do … end` in a subclass of its receiver
# constraint runs as an instance method of that class (Sinatra's `generate_method`), so the block's `@x = …` is the
# instance's ivar, as a `def` body's is. Before the census counted it, an ivar `initialize` sets to `nil` and a route
# sets to a String read as `nil` in every sibling `def`, and `@user.upcase` there reported a call on nil.
RSpec.describe "the ADR-58 ivar census counts block_as_methods instance blocks" do
  def block_plugin(self_type: :receiver_instance)
    klass = Class.new(Rigor::Plugin::Base) do
      manifest(
        id: "censusroutes",
        version: "0.1.0",
        block_as_methods: [
          Rigor::Plugin::Macro::BlockAsMethod.new(
            receiver_constraint: "Sinatra::Base", method_names: %i[get], self_type: self_type
          )
        ]
      )
    end
    stub_const("CensusRoutesPlugin", klass)
  end

  let(:sinatra_rbs) do
    <<~RBS
      module Sinatra
        class Base
          def self.get: (String) ?{ () -> untyped } -> void
          def self.post: (String) ?{ () -> untyped } -> void
          def self.before: (*untyped) ?{ () -> untyped } -> void
          def self.after: (*untyped) ?{ () -> untyped } -> void
          def self.error: (*untyped) ?{ () -> untyped } -> void
          def self.not_found: () ?{ () -> untyped } -> void
          def self.helpers: () ?{ () -> untyped } -> void

          def session: () -> Hash[String, untyped]
          def redirect: (String) -> void
        end
      end

      class Elsewhere
      end
    RBS
  end
  let(:nil_call) { [["app.rb", 10, "call.undefined-method"]] }

  def diagnostics_for(files, plugin: block_plugin, workers: 0, plugin_name: "rigor-censusroutes")
    Rigor::Plugin.unregister!
    Dir.mktmpdir do |dir|
      lib = write_project(dir, files)
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => [lib], "plugins" => plugin ? [plugin_name] : [])
      )
      Dir.chdir(dir) do
        runner = Rigor::Analysis::Runner.new(
          configuration: configuration, cache_store: nil, workers: workers,
          plugin_requirer: lambda do |_name|
            Rigor::Plugin.register(plugin)
            true
          end
        )
        guarded_run(runner).diagnostics
                           .reject { |d| d.path.to_s.end_with?(".rigor.yml") }
                           .map { |d| [File.basename(d.path.to_s), d.line, d.rule] }
      end
    end
  ensure
    Rigor::Plugin.unregister!
  end

  def write_project(dir, files)
    lib = File.join(dir, "lib")
    FileUtils.mkdir_p([lib, File.join(dir, "sig")])
    File.write(File.join(dir, "sig", "sinatra.rbs"), sinatra_rbs)
    files.each { |name, source| File.write(File.join(lib, name), source) }
    lib
  end

  def app(header = "class App < Sinatra::Base")
    <<~RUBY
      #{header}
        def initialize
          @user = nil
        end

        get "/" do
          @user = "alice"
        end

        def greeting = @user.upcase
      end
    RUBY
  end

  it "counts the route block's write in a class whose superclass matches the entry" do
    expect(diagnostics_for({ "app.rb" => app })).to be_empty
  end

  it "counts it in a subclass of a matching class" do
    source = "class Base < Sinatra::Base\nend\n\n#{app('class App < Base')}"
    expect(diagnostics_for({ "app.rb" => source })).to be_empty
  end

  it "counts it when the matching superclass is declared in another file" do
    files = { "base.rb" => "class App < Sinatra::Base\nend\n", "app.rb" => app("class App") }
    expect(diagnostics_for(files)).to be_empty
  end

  it "counts it under --workers 2" do
    expect(diagnostics_for({ "app.rb" => app }, workers: 2)).to be_empty
  end

  # Guard: holds without the fix too; it pins that the match keeps the receiver constraint.
  it "does not count it in a class outside the receiver constraint" do
    source = app("class App < Elsewhere").sub("  def initialize", "  def self.get(_path) = nil\n\n  def initialize")
    expect(diagnostics_for({ "app.rb" => source })).to eq([["app.rb", 12, "call.undefined-method"]])
  end

  # `Admin.get` installs the route on Admin, so the block's `@user` is an Admin instance's, not App's.
  it "does not count a route called on another class's receiver" do
    source = "class Admin < Sinatra::Base\nend\n\n#{app.sub('  get "/" do', '  Admin.get "/" do')}"
    expect(diagnostics_for({ "app.rb" => source })).to eq([["app.rb", 13, "call.undefined-method"]])
  end

  # Guard: holds without the fix too.
  it "does not count it when no plugin declares the call" do
    expect(diagnostics_for({ "app.rb" => app }, plugin: nil)).to eq(nil_call)
  end

  it "does not count it for an entry that runs the block on a named class's instance" do
    expect(diagnostics_for({ "app.rb" => app }, plugin: block_plugin(self_type: "Elsewhere"))).to eq(nil_call)
  end

  it "does not count it for a :lexical entry" do
    expect(diagnostics_for({ "app.rb" => app }, plugin: block_plugin(self_type: :lexical))).to eq(nil_call)
  end

  # Guard: holds without the fix too.
  # The census is per file, as for `define_method`: a route in a reopening feeds that file's census only.
  it "does not credit a route in a reopening to the first file's census" do
    first = "class App < Sinatra::Base\n  def initialize\n    @user = nil\n  end\n\n  " \
            "def greeting = @user.upcase\nend\n"
    reopening = "class App\n  get \"/\" do\n    @user = \"alice\"\n  end\nend\n"
    expect(diagnostics_for({ "app.rb" => first, "routes.rb" => reopening }))
      .to eq([["app.rb", 6, "call.undefined-method"]])
  end

  # A route block is a method body, not class-body code: a class-body `@x = nil` (the class object's ivar) beside it
  # does not exempt the ivar from the read-before-write `nil`, so a sibling def's test is not folded always-truthy.
  it "keeps the read-before-write nil when the class body writes the ivar too" do
    source = <<~RUBY
      class App < Sinatra::Base
        @user = nil

        get "/" do
          @user = "alice"
        end

        def label = (@user ? 1 : 2)
      end
    RUBY
    expect(diagnostics_for({ "app.rb" => source })).to be_empty
  end

  # A block-pass argument is not a literal block: the census has no body to walk and must not fail on the call.
  it "leaves a route given a block-pass argument alone" do
    source = app.sub(%(  get "/" do\n    @user = "alice"\n  end), %(  H = proc { 1 }\n  get "/", &H))
    expect(diagnostics_for({ "app.rb" => source })).to eq([["app.rb", 9, "call.undefined-method"]])
  end

  describe "under the bundled rigor-sinatra plugin" do
    def sinatra_diagnostics(source)
      diagnostics_for({ "app.rb" => source }, plugin: Rigor::Plugin::Sinatra, plugin_name: "rigor-sinatra")
    end

    def filtered_app(reader)
      <<~RUBY
        class User
          def self.find(_id) = new
          def name = "alice"
        end

        class App < Sinatra::Base
          before do
            @user = User.find(session["uid"])
          end

          post "/logout" do
            session.clear
            @user = nil
            redirect "/"
          end

          get "/" do
            username
          end

        #{reader.gsub(/^/, '  ')}
        end
      RUBY
    end

    # Sinatra's `before` filter runs on the app instance (`add_filter` -> `compile!` -> `generate_method`), so the
    # census must see its write next to the logout route's `@user = nil`.
    it "counts a before filter's write beside a route's nil reset (a def reader)" do
      expect(sinatra_diagnostics(filtered_app("def username = @user.name"))).to be_empty
    end

    it "counts it for a reader defined in a helpers block" do
      expect(sinatra_diagnostics(filtered_app("helpers do\n  def username = @user.name\nend"))).to be_empty
    end

    {
      "a before filter with a path" => %(before "/admin/*" do),
      "an after filter" => "after do",
      "an error handler for an exception class" => "error KeyError do",
      "a not_found handler" => "not_found do"
    }.each do |shape, opener|
      it "counts the write in #{shape}" do
        source = <<~RUBY
          class User
            def name = "alice"
          end

          class App < Sinatra::Base
            def initialize
              @user = nil
            end

            #{opener}
              @user = User.new
            end

            def username = @user.name
          end
        RUBY
        expect(sinatra_diagnostics(source)).to be_empty
      end
    end
  end
end
