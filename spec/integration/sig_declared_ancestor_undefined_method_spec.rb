# frozen_string_literal: true

# Issue #723 — a class whose `sig/` declares it WITHOUT its project superclass MUST NOT draw
# `call.undefined-method` for a method that superclass defines in source.
#
# `Analysis::CheckRules#source_declared_method?` asked `Scope#discovered_method?`, which is keyed on the
# receiver's own name, while the typer resolves the same call through the project ancestor walk. The two
# then contradicted each other on one line of one run: `dump_type: :admin_val` and
# `undefined method 'admin_val'`, same file, same column. It is #653's incentive with the project's own
# ancestry in the plugin's place — writing MORE RBS made the run worse.
#
# Every example asserts the TYPE as well as the rule set. Silence alone proves nothing here: a collapsed
# class, an empty universe and a crashed run all report zero diagnostics, and a fix that made the typer go
# opaque would satisfy a rule-only gate while destroying the precision the suppression is supposed to
# preserve.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a sig-declared class and its project ancestry (#723)" do
  # Declares the subclass and NOT its superclass — the realistic abridged `sig/`, and the shape two
  # unrelated workers had to design their fixtures around before this was fixed.
  let(:partial_rbs) do
    <<~RBS
      module Admin
        class Nested
        end
      end
    RBS
  end

  def run_analysis(source, rbs: partial_rbs)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "sig", "admin.rbs"), rbs)
      File.write(File.join(dir, "demo.rb"), source)
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          "paths" => [File.join(dir, "demo.rb")],
          "signature_paths" => [File.join(dir, "sig")]
        )
      )
      Dir.chdir(dir) do
        guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil))
      end
    end
  end

  def undefined_messages(result)
    result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message)
  end

  def dumps(result)
    result.diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message)
  end

  it "does not fire for a method the project superclass defines" do
    result = run_analysis(<<~RUBY)
      class Base
        def admin_val = :admin_val
      end

      module Admin
        class Nested < ::Base
        end
      end

      module Runner
        def self.go
          n = Admin::Nested.new
          Rigor.dump_type(n.admin_val)
          n.admin_val
        end
      end
    RUBY
    expect(undefined_messages(result)).to be_empty
    # The must-still-RESOLVE half, and the reason the issue is filed at all: the typer already had this
    # answer while the rule was firing against it.
    expect(dumps(result)).to eq(["dump_type: :admin_val"])
  end

  it "still fires for a method no ancestor defines" do
    # Discriminates the example above: the fixture CAN report this rule on this receiver. Without this
    # arm, a suppression that silenced the class outright would pass.
    result = run_analysis(<<~RUBY)
      class Base
        def admin_val = :admin_val
      end

      module Admin
        class Nested < ::Base
        end
      end

      module Runner
        def self.go
          Admin::Nested.new.no_such_method_at_all
        end
      end
    RUBY
    expect(undefined_messages(result)).to eq(
      ["undefined method `no_such_method_at_all' for Admin::Nested"]
    )
  end

  it "does not fire for a method an included project module defines" do
    result = run_analysis(<<~RUBY)
      module Taggable
        def tag = :tagged
      end

      module Admin
        class Nested
          include Taggable
        end
      end

      module Runner
        def self.go
          Rigor.dump_type(Admin::Nested.new.tag)
        end
      end
    RUBY
    expect(undefined_messages(result)).to be_empty
    expect(dumps(result)).to eq(["dump_type: :tagged"])
  end

  it "does not fire for an inherited class method, or one an extend contributes" do
    # The singleton side walks the superclass chain, and `extend` reaches it because `ScopeIndexer` folds
    # an extend into the extender's own singleton entries before the discovery table is frozen.
    #
    # The two dumps differ deliberately. `label` (the extend) resolves; `build` (the inherited class
    # method) reads `Dynamic[top]` because the singleton-side lookup has no ancestor walk behind it at all
    # — issue #731, pre-existing and independent of this suppression. It is asserted rather than elided so
    # closing #731 fails HERE with the reason, instead of silently passing a weaker gate.
    result = run_analysis(<<~RUBY)
      class Base
        def self.build = :built
      end

      module Naming
        def label = :labelled
      end

      module Admin
        class Nested < ::Base
          extend Naming
        end
      end

      module Runner
        def self.go
          Rigor.dump_type(Admin::Nested.build)
          Rigor.dump_type(Admin::Nested.label)
        end
      end
    RUBY
    expect(undefined_messages(result)).to be_empty
    expect(dumps(result)).to eq(["dump_type: Dynamic[top]", "dump_type: :labelled"])
  end

  it "still fires for a module's own class method called on an includer" do
    # Pins the `mixins: kind != :singleton` narrowing. `include` contributes INSTANCE methods; `M.build`
    # is not callable on the includer, and MRI raises NoMethodError here — so suppressing it would be a
    # missed detection bought with nothing.
    result = run_analysis(<<~RUBY)
      module Factory
        def self.build = :built
      end

      module Admin
        class Nested
          include Factory
        end
      end

      module Runner
        def self.go
          Admin::Nested.build
        end
      end
    RUBY
    expect(undefined_messages(result)).to eq(
      ["undefined method `build' for singleton(Admin::Nested)"]
    )
  end
end
