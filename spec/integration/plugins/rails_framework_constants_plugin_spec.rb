# frozen_string_literal: true

# Issue #534 item 7 — the Rails framework namespaces the corpus references but nothing named.
#
# Three plugins each declare their own gem's top-level constants (`ActiveRecord`'s exception hierarchy plus
# `ActiveModel` / `Arel`, `ActionController`'s errors, `ActiveSupport::Concern`), so `rescue
# ActiveRecord::RecordNotFound => e` types `e` instead of leaving it `untyped`.
#
# Every declaration is a CONSTANT-resolution fix and asserts no method surface, so each positive assertion
# below is paired with the negative that discriminates it: a call to a member the signature does not declare
# must stay silent. Without that pair the change would be indistinguishable from shipping a partial RBS,
# which is the failure mode ADR-26's `open_receivers:` exists to prevent — and which, on these classes,
# would put `call.undefined-method` on `e.record` in every Rails rescue body.

require "spec_helper"

unless defined?(FRAMEWORK_CONSTANTS_PLUGIN_LIBS)
  FRAMEWORK_CONSTANTS_PLUGIN_LIBS = %w[
    rigor-activerecord rigor-actionpack rigor-activesupport-core-ext
  ].map { |gem_name| File.expand_path("../../../plugins/#{gem_name}/lib", __dir__) }
end
FRAMEWORK_CONSTANTS_PLUGIN_LIBS.each do |lib|
  $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
end
require "rigor-activerecord"
require "rigor-actionpack"
require "rigor-activesupport-core-ext"

RSpec.describe "Rails framework constants (#534 item 7)" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  def dumps(result)
    result.diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message)
  end

  def undefined_method_messages(result)
    result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message)
  end

  describe "rigor-activerecord" do
    let(:plugin_class) { Rigor::Plugin::Activerecord }

    it "types a rescued ActiveRecord error instead of leaving it untyped" do
      source = <<~RUBY
        def work = 1

        begin
          work
        rescue ActiveRecord::RecordNotFound => e
          Rigor.dump_type(e)
        rescue ActiveRecord::StatementInvalid => f
          Rigor.dump_type(f)
        end
      RUBY
      expect(dumps(run_plugin(source: source))).to eq(
        ["dump_type: ActiveRecord::RecordNotFound", "dump_type: ActiveRecord::StatementInvalid"]
      )
    end

    it "CONTROL: the same rescue is untyped without the plugin" do
      source = <<~RUBY
        def work = 1

        begin
          work
        rescue ActiveRecord::RecordNotFound => e
          Rigor.dump_type(e)
        end
      RUBY
      result = run_plugin(source: source, plugin_entry: { "gem" => "rigor-activerecord", "enabled" => false })
      expect(dumps(result)).to eq(["dump_type: Dynamic[top]"])
    end

    it "types `Arel` and keeps `Arel.sql` resolving" do
      expect(dumps(run_plugin(source: "Rigor.dump_type(Arel)\n"))).to eq(["dump_type: singleton(Arel)"])
    end

    it "declares no method surface on the error classes — an undeclared member stays silent" do
      # The discriminating negative. `RecordInvalid#record`, `StatementInvalid#sql` and `Arel.star` are all
      # real Rails members this signature deliberately omits; if the `open_receivers:` wiring were dropped,
      # every one of them would become a `call.undefined-method` on working code.
      source = <<~RUBY
        def work = 1

        begin
          work
        rescue ActiveRecord::RecordInvalid => e
          e.record
        rescue ActiveRecord::StatementInvalid => f
          f.sql
        end
        Arel.star
      RUBY
      expect(undefined_method_messages(run_plugin(source: source))).to be_empty
    end

    it "does not close the model hierarchy — `ActiveRecord::Base` stays undeclared" do
      # Declaring `ActiveRecord::Base` empty would turn every inherited Rails member in every model into a
      # false positive, which is why the signature names errors and namespaces only.
      source = <<~RUBY
        class Widget < ActiveRecord::Base
        end

        Widget.where(name: "x").first_or_create!
      RUBY
      expect(undefined_method_messages(run_plugin(source: source))).to be_empty
    end
  end

  describe "rigor-actionpack" do
    let(:plugin_class) { Rigor::Plugin::Actionpack }

    it "types a rescued ActionController error, including the two under core Ruby supertypes" do
      source = <<~RUBY
        def work = 1

        begin
          work
        rescue ActionController::ParameterMissing => e
          Rigor.dump_type(e)
        rescue ActionController::RoutingError => f
          Rigor.dump_type(f)
        end
      RUBY
      expect(dumps(run_plugin(source: source))).to eq(
        ["dump_type: ActionController::ParameterMissing", "dump_type: ActionController::RoutingError"]
      )
    end

    it "CONTROL: the same rescue is untyped without the plugin" do
      source = <<~RUBY
        def work = 1

        begin
          work
        rescue ActionController::ParameterMissing => e
          Rigor.dump_type(e)
        end
      RUBY
      result = run_plugin(source: source, plugin_entry: { "gem" => "rigor-actionpack", "enabled" => false })
      expect(dumps(result)).to eq(["dump_type: Dynamic[top]"])
    end

    it "leaves `ActionController::Parameters` RBS-less, so `params` stays lenient" do
      # The load-bearing absence. The plugin types `params` as an RBS-LESS nominal on purpose; had the new
      # signature named `Parameters`, this made-up selector would become a `call.undefined-method` and every
      # real Parameters member the declaration omitted would too.
      files = {
        "app/controllers/probe_controller.rb" => <<~RUBY
          class ProbeController
            def create
              params.require(:user).permit(:name)
              params.totally_made_up_member
            end
          end
        RUBY
      }
      result = run_plugin(source: "", files: files, paths: ["app"])
      expect(undefined_method_messages(result)).to be_empty
    end

    it "declares no method surface on the error classes — an undeclared member stays silent" do
      source = <<~RUBY
        def work = 1

        begin
          work
        rescue ActionController::ParameterMissing => e
          e.param
        end
      RUBY
      expect(undefined_method_messages(run_plugin(source: source))).to be_empty
    end
  end

  describe "rigor-activesupport-core-ext" do
    let(:plugin_class) { Rigor::Plugin::ActivesupportCoreExt }

    it "types `ActiveSupport::Concern`" do
      expect(dumps(run_plugin(source: "Rigor.dump_type(ActiveSupport::Concern)\n")))
        .to eq(["dump_type: singleton(ActiveSupport::Concern)"])
    end

    it "keeps the concern DSL silent — `included` / `class_methods` resolve on the extender" do
      # The hazard this pairing exists for: naming `Concern` makes it RBS-known, and a known module whose
      # signature omitted `included` would put `call.undefined-method` on the first line of every concern.
      source = <<~RUBY
        module Suspendable
          extend ActiveSupport::Concern

          included do
            something_the_framework_defines
          end

          class_methods do
            def suspended = 1
          end
        end
      RUBY
      expect(undefined_method_messages(run_plugin(source: source))).to be_empty
    end

    it "declares no further surface on Concern — an undeclared member stays silent" do
      source = <<~RUBY
        module Suspendable
          extend ActiveSupport::Concern
          append_features(Object)
        end
      RUBY
      expect(undefined_method_messages(run_plugin(source: source))).to be_empty
    end
  end
end
