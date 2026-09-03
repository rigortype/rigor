# frozen_string_literal: true

require "tmpdir"

require "rigor"
require "rigor/analysis/runner"
require "rigor/configuration"

# #239 — a false `call.undefined-method`. `Scope`'s in-source method table is keyed by method NAME, so a class that
# defines one name on both sides (`def helper` plus a `class << self` twin) recorded whichever `def` the walk reached
# last and lost the other kind. On an RBS-KNOWN class whose method the project's `sig/` does not declare, existence
# falls to that table, so `self.class.helper(1)` read as undefined on code that runs fine.
#
# Surfaced by Rigor's own `make check` while landing #207, on `RbsLoader.entry_declarations` — the shape is ordinary
# Ruby (a class-side helper and an instance-side helper sharing a name), which is why it belongs at the check level
# and not only in the indexer's unit specs.
RSpec.describe "a singleton method sharing a name with an instance method" do
  # Only `call_class_side` / `call_instance_side` are declared, so `helper` existence comes from the source scan.
  # `Alone` is the control: byte-identical minus the instance-side twin.
  let(:rbs) do
    <<~RBS
      class Collides
        def call_class_side: () -> Integer
        def call_instance_side: () -> Integer
      end

      class Alone
        def call_class_side: () -> Integer
      end
    RBS
  end

  let(:source) do
    <<~RUBY
      class Collides
        class << self
          def helper(value)
            value
          end
        end

        def helper(value)
          value
        end

        def call_class_side
          self.class.helper(1)
        end

        def call_instance_side
          helper(1)
        end
      end

      class Alone
        class << self
          def helper(value)
            value
          end
        end

        def call_class_side
          self.class.helper(1)
        end
      end
    RUBY
  end

  def write_project
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "collides.rbs"), rbs)
    File.write("app.rb", source)
  end

  def undefined_method_messages
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[app.rb], "signature_paths" => %w[sig])
    )
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    diagnostics = guarded_run(runner, %w[app.rb]).diagnostics
    diagnostics.select { |d| d.rule == "call.undefined-method" }.map(&:message)
  end

  around do |example|
    Dir.mktmpdir("rigor-singleton-collision-") do |dir|
      Dir.chdir(dir) { example.run }
    end
  end

  it "resolves both sides of the collision without a false undefined-method" do
    write_project

    expect(undefined_method_messages).to be_empty
  end

  it "still reports a name that really is absent on the singleton side" do
    # The control the silence above needs: the rule is not merely mute on this class.
    File.write("app.rb", source.sub("self.class.helper(1)", "self.class.no_such_helper_zzz(1)"))
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "collides.rbs"), rbs)

    expect(undefined_method_messages).to include(a_string_matching(/undefined method `no_such_helper_zzz'/))
  end
end
