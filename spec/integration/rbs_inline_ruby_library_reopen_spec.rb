# frozen_string_literal: true

# Issue #2174 — a project-only RBS declaration of a class Ruby's own libraries define is a reopen, not the class.
#
# `class Matrix` with one `#:`-annotated method, and no `matrix` signatures loaded, gave Matrix an inline-only
# declaration holding just that method, and `Matrix.identity(2)` (correct Ruby) reported
# `undefined method 'identity' for singleton(Matrix)`. A `sig/` file reopening an unloaded stdlib class did the
# same. `RbsLoader#ruby_library_reopen?` marks such a class's surface as open when the project requires the library.
#
# Mutations this file kills (the user-paths and require-gate rows are pinned in
# `spec/rigor/environment/rbs_loader_ruby_library_reopen_spec.rb`):
#
# | Mutation                                                   | Killed by                                        |
# | ---------------------------------------------------------- | ------------------------------------------------ |
# | `unbounded_receiver_surface?` loses `ruby_library_reopen?` | "does not report a library method ..."           |
# | the root lookup always answers a library                   | "... on the project's own class"                 |
# | the required-feature test always passes                    | "... a library the project does not require"     |
# | `project_authored_entry?` reads `any?` for `all?`          | "... on a loaded library class ..."              |
# | `RubyLibraryRoots.stdlib_roots` reads nothing              | "reads the roots of the rbs stdlib tree"         |
# | `RubyLibraryRoots.ruby_lib_roots` reads nothing            | "... of the interpreter's library directory"     |
# | `RubyLibraryRoots.bundled_gem_roots` reads nothing         | "does not report a library method ..."           |
# | the full name is looked up instead of its root             | "does not report it on a nested reopen ..."      |
#
# "keeps checking a method the project's own declaration lists" is a guard, not a mutation witness: it passes
# with the fix removed, and pins that the opened surface still checks the methods the project declares.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a project-only declaration of a Ruby library class (#2174)" do
  def write_project
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    File.write(File.join("lib", "matrix_ext.rb"), reopens_source)
    File.write(File.join("sig", "ripper.rbs"), <<~RBS)
      class Ripper
        def mine: () -> Integer
      end
    RBS
    File.write(File.join("lib", "probe.rb"), probe_source)
  end

  def reopens_source
    <<~RUBY
      # rbs_inline: enabled

      require "matrix"
      require "ripper"
      require "zlib"
      require "weakref"
      require "optparse"
      require "net/smtp"

      class Matrix
        #: () -> Integer
        def my_rank = 1
      end

      class Matrix::LUPDecomposition
        #: () -> Integer
        def mine = 1
      end

      module Zlib
        #: () -> Integer
        def self.mine = 1
      end

      class WeakRef
        #: () -> Integer
        def mine = 1
      end

      class Own
        #: () -> Integer
        def bar = 1
      end

      class OptionParser
        #: () -> Integer
        def mine = 1
      end

      class Syslog
        #: () -> Integer
        def mine = 1
      end

      class Net::SMTP
        #: () -> Integer
        def mine = 1
      end
    RUBY
  end

  # Line 3 reaches a bundled gem's root (`Matrix`), 6 a root both the `rbs` stdlib tree and the interpreter's
  # library directory declare (`Ripper`), 7 a nested reopen whose root is the library's, 8 a root only the `rbs`
  # stdlib tree declares (`Zlib`, a C extension), and 9 one only the library directory declares (`WeakRef`).
  def probe_source
    <<~RUBY
      # rbs_inline: enabled
      class Probe
        def singleton_side = Matrix.identity(2)
        #: (Matrix) -> untyped
        def instance_side(m) = m.det
        def sig_reopen = Ripper.sexp("1")
        def nested_reopen = Matrix::LUPDecomposition.new.det
        def stdlib_only_root = Zlib.crc32("x")
        def lib_dir_only_root = WeakRef.new.weakref_alive?
        def declared_arity = Matrix.new.my_rank(1)
        def sig_declared_arity = Ripper.new("x").mine(1)
        def own_typo = Own.new.typo
        def own_singleton_typo = Own.typo2
        def loaded_library_typo = OptionParser.new.typo_x
        def unrequired_library_typo = Syslog.new.typo
        def nested_feature = Net::SMTP.start("h")
      end
    RUBY
  end

  # Requires and registers the bundled plugin from source; see `rbs_inline_cross_file_method_spec.rb`.
  def require_rbs_inline_plugin
    plugin_lib = File.expand_path("../../plugins/rigor-rbs-inline/lib", __dir__)
    $LOAD_PATH.unshift(plugin_lib) unless $LOAD_PATH.include?(plugin_lib)
    require "rigor-rbs-inline"
    Rigor::Plugin.unregister!
    lambda do |_name|
      Rigor::Plugin.register(Rigor::Plugin::RbsInline)
      true
    end
  end

  def run_check
    plugin_requirer = require_rbs_inline_plugin
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0,
        "plugins" => [{ "gem" => "rigor-rbs-inline", "id" => "rbs-inline" }]
      )
    )
    guarded_run(
      Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil, plugin_requirer: plugin_requirer),
      %w[lib]
    )
  end

  def rows(result)
    result.diagnostics.select { |d| d.path.end_with?("probe.rb") }.map { |d| [d.line, d.qualified_rule] }
  end

  around do |example|
    Dir.mktmpdir("rigor-ruby-library-reopen-") { |dir| Dir.chdir(dir) { example.run } }
  ensure
    Rigor::Plugin.unregister!
  end

  let(:result) do
    write_project
    run_check
  end

  it "does not report a library method the project's declaration omits, inline or in sig/, on either side" do
    expect(rows(result).map(&:first)).not_to include(3, 5, 6)
  end

  it "does not report it on a nested reopen, judged by its root" do
    expect(rows(result).map(&:first)).not_to include(7)
  end

  it "reads the roots of the rbs stdlib tree" do
    expect(rows(result).map(&:first)).not_to include(8)
  end

  it "reads the roots of the interpreter's library directory" do
    expect(rows(result).map(&:first)).not_to include(9)
  end

  it "keeps checking a method the project's own declaration lists" do
    expect(rows(result)).to include([10, "call.wrong-arity"], [11, "call.wrong-arity"])
  end

  it "still reports a typo on the project's own class" do
    expect(rows(result)).to include([12, "call.undefined-method"], [13, "call.undefined-method"])
  end

  it "still reports a typo on a loaded library class the project also reopens" do
    expect(rows(result)).to include([14, "call.undefined-method"])
  end

  it "still reports a typo on a class named for a library the project does not require" do
    expect(rows(result)).to include([15, "call.undefined-method"])
  end

  it "matches a nested feature by its first segment (`require \"net/smtp\"` against `Net`)" do
    expect(rows(result).map(&:first)).not_to include(16)
  end

  it "reports nothing else" do
    expect(rows(result)).to contain_exactly(
      [10, "call.wrong-arity"], [11, "call.wrong-arity"], [12, "call.undefined-method"],
      [13, "call.undefined-method"], [14, "call.undefined-method"], [15, "call.undefined-method"]
    )
  end
end
