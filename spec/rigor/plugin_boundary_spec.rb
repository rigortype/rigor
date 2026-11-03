# frozen_string_literal: true

require "spec_helper"
require "prism"

# ADR-128 WD4 — the plugin-boundary gate's own contract. The gate itself (`spec/support/plugin_boundary_gate.rb`)
# runs over the bundled plugins' integration specs; these examples prove it can fail, and fail for the right
# reason, using fixture plugins under `spec/fixtures/plugin_boundary/plugins/`.
PLUGIN_BOUNDARY_FIXTURE_ROOT = File.expand_path("../fixtures/plugin_boundary/plugins", __dir__)
load File.join(PLUGIN_BOUNDARY_FIXTURE_ROOT, "rigor-offender/lib/offender.rb")
load File.join(PLUGIN_BOUNDARY_FIXTURE_ROOT, "rigor-clean/lib/clean.rb")

# A spec tree root: `spec_helper.rb` is a loaded file under it, and the fixtures above are methods under it.
SPEC_ROOT = File.join(PluginBoundary::REPO_ROOT, "spec")
INTEGRATION_EXAMPLE = "./spec/integration/examples/deprecations_plugin_spec.rb"

RSpec.describe PluginBoundary do
  let(:recorder) { PluginBoundary::Recorder.new(roots: [PLUGIN_BOUNDARY_FIXTURE_ROOT]) }
  let(:scope) { Rigor::Scope.empty(environment: Rigor::Environment.default) }
  let(:node) { Prism.parse("1").value }

  def reached(recorder)
    recorder.violations.to_h { |c| [[c.target, c.name], c.plugin] }
  end

  describe "positive control: a plugin reaching past the interfaces" do
    it "fails on an attr_reader and on a Ruby method of Rigor::Scope" do
      recorder.record { PluginBoundaryFixture::Offender.reach_scope(scope) }

      expect(reached(recorder)).to eq(
        ["Rigor::Scope", :locals] => "rigor-offender",
        ["Rigor::Scope", :discovered_methods] => "rigor-offender"
      )
    end

    it "fails on a call into a module under Rigor::Inference that no allow-list row covers" do
      recorder.record { PluginBoundaryFixture::Offender.reach_inference }

      expect(reached(recorder).keys).to include(["Rigor::Inference::DeclarationWalk::Context", :root])
    end

    it "fails on an instance method of an Inference object, whose receiver is no module" do
      recorder.record { PluginBoundaryFixture::Offender.reach_inference_instance }

      expect(reached(recorder).keys).to include(["Rigor::Inference::DeclarationWalk::Context", :nesting])
    end

    it "makes check! raise, naming the plugin, the method and where it was called" do
      recorder.record { PluginBoundaryFixture::Offender.reach_scope(scope) }

      expect { described_class.check!(recorder) }
        .to raise_error(PluginBoundary::Violation, /rigor-offender: Rigor::Scope#locals at .*offender\.rb:\d+/)
    end
  end

  describe "what the gate lets through" do
    it "accepts every method the interfaces carry, and the Object protocol (nil?, respond_to?)" do
      recorder.record { PluginBoundaryFixture::Offender.within_interface(scope, node) }

      expect(recorder.calls.keys.map { |(_target, name, _plugin)| name })
        .to include(:type_of, :self_type, :local, :source_path, :environment, :nominal_for_name, :nil?)
      expect(recorder.violations).to be_empty
    end

    it "passes a plugin that stays inside the interfaces" do
      recorder.record { PluginBoundaryFixture::Clean.read(scope, node) }

      expect { described_class.check!(recorder) }.not_to raise_error
    end

    it "does not raise inside traced code on a BasicObject receiver" do
      proxy = Class.new(BasicObject) { def ping = nil }.new

      expect { recorder.record { proxy.ping } }.not_to raise_error
      expect(recorder.calls).to be_empty
    end

    it "does not raise inside traced code on a class whose own name takes an argument" do
      odd = Class.new { def self.name(_arg) = "odd"; def self.ping = nil } # rubocop:disable Style/Semicolon

      expect { recorder.record { odd.ping } }.not_to raise_error
    end

    it "does not let instance-variable access through as Object protocol" do
      expect(PluginBoundary::OBJECT_PROTOCOL)
        .not_to include(:instance_variable_get, :instance_variable_set, :instance_variables)
    end

    it "fails a gate that recorded nothing when it is asked to require calls, and not otherwise" do
      recorder.record { scope.locals }

      expect { described_class.check!(recorder, require_calls: true) }
        .to raise_error(PluginBoundary::Violation, /recorded no call from a frame under .*it checked nothing/)
      expect { described_class.check!(recorder) }.not_to raise_error
    end

    it "fails a run that ran an integration example when no root holds a loaded file" do
      wrong = PluginBoundary::Recorder.new(roots: ["#{PLUGIN_BOUNDARY_FIXTURE_ROOT}X"])
      wrong.note_example(INTEGRATION_EXAMPLE)

      expect { described_class.check!(wrong) }
        .to raise_error(PluginBoundary::Violation, /loaded no file under .*it checked nothing/)
    end

    it "passes a run with no integration example, though no root holds a loaded file" do
      wrong = PluginBoundary::Recorder.new(roots: ["#{PLUGIN_BOUNDARY_FIXTURE_ROOT}X"])
      wrong.note_example("./spec/rigor/plugin_boundary_spec.rb")

      expect { described_class.check!(wrong) }.not_to raise_error
    end

    it "fails a run that ran an integration example on a recorder that never went live" do
      never = PluginBoundary::Recorder.new(roots: [SPEC_ROOT])
      never.note_example(INTEGRATION_EXAMPLE)
      expect(never.root_file_loaded?).to be(true)

      expect { described_class.check!(never) }
        .to raise_error(PluginBoundary::Violation, /no method under .* run under the trace/)
    end

    it "fails a run that ran an integration example when the trace saw only engine code" do
      engine_only = PluginBoundary::Recorder.new(roots: [SPEC_ROOT])
      engine_only.note_example(INTEGRATION_EXAMPLE)
      engine = scope # the `let` method is defined in this spec file, under SPEC_ROOT: evaluate it before tracing
      engine_only.record { engine.locals }

      expect(engine_only.live?).to be(false)
      expect { described_class.check!(engine_only) }
        .to raise_error(PluginBoundary::Violation, /no method under .* run under the trace/)
    end

    it "passes a gate whose root holds a loaded file and went live, though it recorded no call" do
      live = PluginBoundary::Recorder.new(roots: [SPEC_ROOT])
      live.note_example(INTEGRATION_EXAMPLE)
      live.record { PluginBoundaryFixture::Clean.idle }

      expect(live.calls).to be_empty
      expect(live.live?).to be(true)
      expect { described_class.check!(live) }.not_to raise_error
    end

    it "fails a gate whose roots match no plugin file, though a plugin made calls" do
      wrong = PluginBoundary::Recorder.new(roots: ["#{PLUGIN_BOUNDARY_FIXTURE_ROOT}X"])
      wrong.note_example(INTEGRATION_EXAMPLE)
      wrong.record { PluginBoundaryFixture::Clean.read(scope, node) }

      expect { described_class.check!(wrong) }.to raise_error(PluginBoundary::Violation)
    end

    it "attributes a call by its caller's path, so a call from the spec file itself is not a plugin's" do
      recorder.record { scope.locals }

      expect(recorder.calls).to be_empty
    end

    it "lets an allow-list row cover its own plugin and owner, and no other plugin" do
      recorder.record { PluginBoundaryFixture::Offender.reach_inference }
      owner = /\ARigor::Inference::DeclarationWalk(::|\z)/
      own = PluginBoundary::AllowRow.new(plugin: "rigor-offender", owner: owner, issue: "rigortype/rigor#2708")
      other = PluginBoundary::AllowRow.new(plugin: "rigor-alba", owner: owner, issue: "rigortype/rigor#2708")

      expect(recorder.violations(allow_list: [own])).to be_empty
      expect(recorder.violations(allow_list: [other])).not_to be_empty
    end
  end

  describe "the default roots" do
    it "are the bundled plugins/ and examples/ directories" do
      expect(PluginBoundary::Recorder.new.roots)
        .to eq([File.join(PluginBoundary::REPO_ROOT, "plugins", ""),
                File.join(PluginBoundary::REPO_ROOT, "examples", "")])
    end
  end

  describe "the integration-spec predicate" do
    it "matches the plugin integration spec directories, as RSpec reports them" do
      expect(described_class.integration_spec?("./spec/integration/examples/deprecations_plugin_spec.rb")).to be(true)
      expect(described_class.integration_spec?("/abs/repo/spec/integration/plugins/alba_plugin_spec.rb")).to be(true)
    end

    it "does not match any other spec file" do
      expect(described_class.integration_spec?("./spec/rigor/plugin_boundary_spec.rb")).to be(false)
      expect(described_class.integration_spec?("./spec/integration/lens_spec.rb")).to be(false)
      expect(described_class.integration_spec?("./spec/integration/examples_helper.rb")).to be(false)
    end

    it "anchors the directory at a path component, with or without a leading directory or ./" do
      expect(described_class.integration_spec?("spec/integration/examples/x_spec.rb")).to be(true)
      expect(described_class.integration_spec?("./myspec/integration/examples/x_spec.rb")).to be(false)
      expect(described_class.integration_spec?("./xspec/integration/plugins/x_spec.rb")).to be(false)
    end
  end

  describe "the recorder's integration state" do
    it "is set only by a plugin integration spec path" do
      recorder.note_example("./spec/rigor/plugin_boundary_spec.rb")
      expect(recorder.integration_ran?).to be(false)

      recorder.note_example("./spec/integration/plugins/alba_plugin_spec.rb")
      expect(recorder.integration_ran?).to be(true)
    end

    it "is not live until a method under a root has run under the trace" do
      expect(recorder.live?).to be(false)
      recorder.record { PluginBoundaryFixture::Clean.idle }

      expect(recorder.live?).to be(true)
    end
  end

  describe "the allow-list" do
    it "holds only the DeclarationWalk reach of rigor-alba and rigor-typelizer, citing #2708" do
      expect(PluginBoundary::ALLOW_LIST.map { |r| [r.plugin, r.issue] })
        .to eq([%w[rigor-alba rigortype/rigor#2708], %w[rigor-typelizer rigortype/rigor#2708]])
    end
  end

  describe "the interfaces" do
    it "backs each interface with a class that implements every member it declares" do
      described_class.interface_members.each do |interface, members|
        backing = Object.const_get(PluginBoundary::BACKING.fetch(interface))

        expect(members.reject { |m| backing.public_method_defined?(m) }).to be_empty, interface
      end
    end

    it "is backed by exactly the interfaces the RBS declares" do
      expect(described_class.interface_members.keys).to match_array(PluginBoundary::BACKING.keys)
    end
  end
end
