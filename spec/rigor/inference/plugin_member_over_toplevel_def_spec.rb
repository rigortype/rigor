# frozen_string_literal: true

# Issue #963 item 2 — the own-method veto's plugin arm.
#
# #618 made a same-named top-level `def` a FALLBACK for names the call's own `self` does not answer, because
# a top-level `def` is a private instance method on `Object`, the last link of every MRO. #633 / #955 /
# #1030 / #1035 widened the sources `ExpressionTyper#self_type_answers?` reads — inherited discovery,
# pre-`::Object` RBS owners, singleton twins, the `define_method` block's `self`, the meta-constant
# spellings — and every one of them is a source the ENGINE walks.
#
# A plugin-supplied member is not. A rigor-activerecord column reader, an association, a scope, an ADR-16
# Tier C synthesised reader: Ruby dispatches to each of them ahead of `Object`'s private top-level `def`, and the
# veto could see none of them. A project with a top-level `def name` in a script or spec-support file read
# `name.upcase` inside the model's own `def shout` as the top-level def's `nil` and fired
# `undefined method 'upcase' for nil` on working Rails code — #618's false positive, at a source the veto
# had no way to ask about.
#
# The fix asks the two tiers `MethodDispatcher#resolve` itself consults — the gated `dynamic_return` walk
# and the ADR-16 synthetic-method index — through `MethodDispatcher.plugin_member_answers?`, so a name the
# veto reports as answered is a name the dispatch really would resolve, and no plugin knowledge moves into
# the engine's veto. `ExpressionTyper#plugin_member_answers?` keeps #618's confidence gate unchanged: a
# `self` whose class is not KNOWN does not participate, which leaves #316's / #319's territory alone.
#
# The ancestor-walking half of the veto lives in `self_class_method_over_toplevel_def_spec.rb`; this file is
# the plugin half.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

ACTIVERECORD_PLUGIN_LIB_FOR_VETO = File.expand_path(
  "../../../plugins/rigor-activerecord/lib", __dir__
)
$LOAD_PATH.unshift(ACTIVERECORD_PLUGIN_LIB_FOR_VETO) unless $LOAD_PATH.include?(ACTIVERECORD_PLUGIN_LIB_FOR_VETO)
require "rigor-activerecord"

RSpec.describe "a plugin-supplied member beats a top-level def of the same name (#963 item 2)" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  # The shadowing top-level `def`s, in their own file so nothing about the repro depends on collocation.
  # Each answers `nil`, which is what turns a bound call into `undefined method '...' for nil`.
  def shadow_source = <<~RUBY
    def name
      nil
    end

    def name?
      nil
    end

    def errors
      nil
    end

    def nope
      nil
    end

    def label
      nil
    end
  RUBY

  def schema_source = <<~RUBY
    ActiveRecord::Schema[8.0].define(version: 2026_01_01_000000) do
      create_table "users", force: :cascade do |t|
        t.string "name", null: false
      end
    end
  RUBY

  def run_project(files, plugins:, requirer: nil, signatures: {})
    Rigor::Plugin.unregister!
    Dir.mktmpdir do |dir|
      files.each do |relative, source|
        full = File.join(dir, relative)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, source)
      end
      signatures.each do |relative, source|
        FileUtils.mkdir_p(File.join(dir, "sig"))
        File.write(File.join(dir, "sig", relative), source)
      end
      settings = { "paths" => ["app", "shadow.rb"], "plugins" => plugins }
      settings["signature_paths"] = [File.join(dir, "sig")] unless signatures.empty?
      configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge(settings))
      Dir.chdir(dir) do
        runner = Rigor::Analysis::Runner.new(
          configuration: configuration, cache_store: nil, plugin_requirer: requirer
        )
        guarded_run(runner).diagnostics
      end
    end
  end

  def ar_files(model_body, schema: schema_source)
    {
      "shadow.rb" => shadow_source,
      "db/schema.rb" => schema,
      "app/models/application_record.rb" => "class ApplicationRecord < ActiveRecord::Base\nend\n",
      "app/models/user.rb" => "class User < ApplicationRecord\n#{model_body}end\n"
    }
  end

  # The plugin gem is already loaded by this file's own `require`, so the loader's `require` no-ops and
  # nothing re-registers the class after `Rigor::Plugin.unregister!`. Registering through the requirer is
  # how every bundled-plugin spec closes that, and it keeps the run's diagnostic stream free of the
  # loader's "did not register any plugin" warning.
  def ar_requirer
    lambda do |_name|
      Rigor::Plugin.register(Rigor::Plugin::Activerecord)
      true
    end
  end

  def ar_messages(model_body, schema: schema_source, plugins: ["rigor-activerecord"], signatures: {})
    run_project(
      ar_files(model_body, schema: schema),
      plugins: plugins, requirer: ar_requirer, signatures: signatures
    ).map(&:message)
  end

  # A project sidecar declaring the reader and an association, for the arm below.
  def user_rbs = <<~RBS
    class User
      def name: () -> String
      def posts: () -> Array[String]
    end
  RBS

  # `errors` is the issue's second name. It is NOT an enumerable member of any rigor-activerecord model —
  # the plugin's bundled `sig/active_record/framework.rbs` deliberately declines to declare
  # `ActiveRecord::Base`, because an empty declaration would close every model in the project — so the
  # engine has no source that knows `ActiveRecord::Base#errors`. What the veto CAN answer is a plugin that
  # claims the name, which is the contract under test here and the shape any plugin modelling a framework
  # base class takes.
  let(:member_plugin) do
    klass = Class.new(Rigor::Plugin::Base) do
      manifest(id: "vetofixture", version: "0.1.0")

      dynamic_return methods: %i[errors label] do |call_node, scope|
        next nil unless call_node.is_a?(Prism::CallNode)
        next nil unless call_node.receiver.nil?
        next nil unless scope&.self_type.is_a?(Rigor::Type::Nominal)
        next nil unless scope.self_type.class_name == "Widget"

        Rigor::Type::Combinator.untyped
      end
    end
    stub_const("VetoFixturePlugin", klass)
    klass
  end

  # The second tier the veto asks. A Tier C `heredoc_templates` emission puts the member in
  # `SyntheticMethodIndex` rather than in any `dynamic_return` block, so the two tiers have to be asked
  # separately; asking only the first would leave every macro-synthesised reader shadowed.
  #
  # Tier B (`Plugin::Macro::TraitRegistry`) shares that table but is NOT exercised here, and could not be:
  # the production pre-pass calls `SyntheticMethodScanner.scan` with `environment: nil`, and the scanner
  # short-circuits to an empty index when only trait registries contribute (#476). A rigor-devise fixture
  # still reports today. This arm needs no change when #476 lands — the index is the same table.
  let(:synthetic_plugin) do
    klass = Class.new(Rigor::Plugin::Base) do
      manifest(
        id: "vetosynthetic",
        version: "0.1.0",
        heredoc_templates: [
          Rigor::Plugin::Macro::HeredocTemplate.new(
            receiver_constraint: "Fixture::Base",
            method_name: :field,
            symbol_arg_position: 0,
            emit: [{ name: "\#{name}" }]
          )
        ]
      )
    end
    stub_const("VetoSyntheticPlugin", klass)
    klass
  end

  # --- rigor-activerecord: the issue's own shape ------------------------------------------------------

  it "reads the model's column reader instead of a top-level def of the same name" do
    expect(ar_messages(<<~RUBY)).to be_empty
      def shout
        name.upcase
      end
    RUBY
  end

  it "reads the `column?` predicate the same way" do
    expect(ar_messages(<<~RUBY)).to be_empty
      def flagged
        name?.no_such_bool_method
      end
    RUBY
  end

  # The must-still-fire arm. `nope` is no column, no association and no scope, so nothing on the model
  # answers it, the top-level `def nope` still binds, and the `nil` it returns still reports. Without this
  # the example above cannot tell "the veto fired" from "the fixture cannot report anything".
  it "STILL binds the top-level def for a name the model does not answer" do
    expect(ar_messages(<<~RUBY)).to include(/undefined method .upcase./)
      def shout
        nope.upcase
      end
    RUBY
  end

  # The control that isolates the PLUGIN as the cause: the same sources with no plugin configured report the
  # column read exactly as they did before this change.
  it "CONTROL: the same column read reports with no plugin configured" do
    messages = ar_messages(<<~RUBY, plugins: [])
      def shout
        name.upcase
      end
    RUBY
    expect(messages).to include(/undefined method .upcase./)
  end

  # The schema is what makes `name` a column. Drop it and the plugin runs in reduced mode with no column
  # surface at all, so the same read falls back to the top-level def — the veto answers from the member
  # set, not from "a model is involved".
  it "STILL binds the top-level def when the schema declares no such column" do
    schema = <<~RUBY
      ActiveRecord::Schema[8.0].define(version: 2026_01_01_000000) do
        create_table "users", force: :cascade do |t|
          t.string "other", null: false
        end
      end
    RUBY
    expect(ar_messages(<<~RUBY, schema: schema)).to include(/undefined method .upcase./)
      def shout
        name.upcase
      end
    RUBY
  end

  # The model's OWN `def` is an override Ruby dispatches to, and the plugin tier sits above the engine's
  # body-inference tiers — so the plugin declines rather than displacing the override's real return type.
  # The veto still fires (the discovery arm answers `name`), so the top-level def does not bind either.
  it "lets the model's own def override the column reader" do
    expect(ar_messages(<<~RUBY)).to include(/undefined method .no_such_integer_method./)
      def name
        1
      end

      def shout
        name.no_such_integer_method
      end
    RUBY
  end

  # A signature the project wrote ABOUT THIS MODEL is authorship, and this tier sits ABOVE `RbsDispatch` —
  # so a blanket `untyped` here would displace the declared type at the implicit-self spelling only, leaving
  # `name` and `self.name` typed differently in one body. The plugin declines instead: all three reads keep
  # their declared types and all three true positives still fire. There is no top-level `def` in play for
  # `posts`, and `name`'s is shadowed by the declaration through the veto's own pre-`::Object` RBS arm.
  it "keeps a project-declared RBS type at the implicit-self spelling" do
    messages = ar_messages(<<~RUBY, signatures: { "user.rbs" => user_rbs })
      has_many :posts

      def shout
        name.upcase_zzz
      end

      def shout_explicitly
        self.name.upcase_zzz
      end

      def listing
        posts.upcase_zzz
      end
    RUBY
    expect(messages.grep(/upcase_zzz/).size).to eq(3)
    expect(messages).to include(/undefined method .upcase_zzz. for String/)
    expect(messages).to include(/undefined method .upcase_zzz. for Array\[String\]/)
  end

  # --- a fixture plugin's `dynamic_return` member -----------------------------------------------------

  def member_requirer
    plugin = member_plugin
    lambda do |_name|
      Rigor::Plugin.register(plugin)
      true
    end
  end

  def widget_messages(body, plugins: ["rigor-vetofixture"])
    files = {
      "shadow.rb" => shadow_source,
      "app/widget.rb" => "class Widget\n#{body}end\n"
    }
    run_project(files, plugins: plugins, requirer: member_requirer).map(&:message)
  end

  it "reads a plugin `dynamic_return` member named `errors` instead of a top-level `def errors`" do
    expect(widget_messages(<<~RUBY)).to be_empty
      def complain
        errors.full_messages
      end
    RUBY
  end

  it "reads a plugin `dynamic_return` member instead of a top-level def of the same name" do
    expect(widget_messages(<<~RUBY)).to be_empty
      def shout
        label.upcase
      end
    RUBY
  end

  it "STILL binds the top-level def for a name the plugin does not claim" do
    expect(widget_messages(<<~RUBY)).to include(/undefined method .upcase./)
      def shout
        nope.upcase
      end
    RUBY
  end

  it "CONTROL: the same `errors` read reports with the plugin unconfigured" do
    expect(widget_messages(<<~RUBY, plugins: [])).to include(/undefined method .full_messages./)
      def complain
        errors.full_messages
      end
    RUBY
  end

  # The plugin's gate is the receiver, not the name: the same `label` read inside a class the plugin does
  # not claim falls back to the top-level def, so the veto cannot be reading the method-name gate alone.
  it "STILL binds the top-level def inside a class the plugin does not claim" do
    files = {
      "shadow.rb" => shadow_source,
      "app/gadget.rb" => "class Gadget\n  def shout\n    label.upcase\n  end\nend\n"
    }
    messages = run_project(files, plugins: ["rigor-vetofixture"], requirer: member_requirer).map(&:message)
    expect(messages).to include(/undefined method .upcase./)
  end

  # --- the ADR-16 synthetic-method index --------------------------------------------------------------

  def synthetic_requirer
    plugin = synthetic_plugin
    lambda do |_name|
      Rigor::Plugin.register(plugin)
      true
    end
  end

  def gizmo_messages(declaration)
    files = {
      "shadow.rb" => shadow_source,
      "app/base.rb" => "module Fixture\n  class Base\n  end\nend\n",
      "app/gizmo.rb" => "class Gizmo < Fixture::Base\n  #{declaration}\n\n  def shout\n    label.upcase\n  end\nend\n"
    }
    run_project(files, plugins: ["rigor-vetosynthetic"], requirer: synthetic_requirer).map(&:message)
  end

  it "reads a synthesised member instead of a top-level def of the same name" do
    expect(gizmo_messages("field :label")).to be_empty
  end

  it "STILL binds the top-level def when the macro synthesised another name" do
    expect(gizmo_messages("field :other")).to include(/undefined method .upcase./)
  end

  # --- the confidence gate is untouched ---------------------------------------------------------------

  # #316 / #319 — at genuine top level `scope.self_type` is nil, the veto declines to participate, and the
  # historical binding stands. A plugin answer must not change that: the receiver there is the synthetic
  # `Object` stand-in `ExpressionTyper#call_receiver_type_for` substitutes, not a `self` the engine modelled.
  it "leaves a genuine top-level call bound to the top-level def" do
    files = {
      "shadow.rb" => shadow_source,
      "app/script.rb" => "label.upcase\n"
    }
    messages = run_project(files, plugins: ["rigor-vetofixture"], requirer: member_requirer).map(&:message)
    expect(messages).to include(/undefined method .upcase./)
  end
end
