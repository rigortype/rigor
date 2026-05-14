# frozen_string_literal: true

# Integration spec for `examples/rigor-pundit/`.
# Tier 3B of the Rails plugins roadmap. Discovers Pundit
# policy classes by walking `app/policies/` and validates
# `authorize(record, :action)` / `policy(record)` /
# `policy_scope(scope)` call sites against the discovered
# policies.

require "spec_helper"

PUNDIT_PLUGIN_LIB = File.expand_path("../../../examples/rigor-pundit/lib", __dir__)
$LOAD_PATH.unshift(PUNDIT_PLUGIN_LIB) unless $LOAD_PATH.include?(PUNDIT_PLUGIN_LIB)
require "rigor-pundit"

DEFAULT_POLICIES = {
  "app/policies/post_policy.rb" => <<~RUBY,
    class ApplicationPolicy
    end
    class PostPolicy < ApplicationPolicy
      def show?
        true
      end

      def update?
        true
      end

      def destroy?
        false
      end
    end
  RUBY
  "app/policies/comment_policy.rb" => <<~RUBY
    class ApplicationPolicy; end
    class CommentPolicy < ApplicationPolicy
      def edit?
        true
      end
    end
  RUBY
}.freeze

RSpec.describe "examples/rigor-pundit" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Pundit }

  describe "recognised authorize calls" do
    it "emits a `policy-call` info diagnostic for `authorize(SomeClass, :action)`" do
      result = run_plugin(
        source: "authorize(Post, :update)\n",
        files: DEFAULT_POLICIES
      )
      info = plugin_diagnostics(result).find { |d| d.rule == "policy-call" }
      expect(info).not_to be_nil
      expect(info.severity).to eq(:info)
      expect(info.message).to include("PostPolicy")
    end

    it "accepts both `:action` and `:action?` as the predicate argument" do
      result = run_plugin(
        source: "authorize(Post, :update?)\nauthorize(Post, :update)\n",
        files: DEFAULT_POLICIES
      )
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "unknown-policy-method" }).to be_empty
      expect(diags.select { |d| d.rule == "policy-call" }.size).to eq(2)
    end

    it "recognises `policy(...)` and `policy_scope(...)` shapes" do
      result = run_plugin(
        source: "policy(Post)\npolicy_scope(Post)\n",
        files: DEFAULT_POLICIES
      )
      info = plugin_diagnostics(result).select { |d| d.rule == "policy-call" }
      expect(info.size).to eq(2)
    end

    it "validates the policy class via the inferred type when the receiver is Nominal[T]" do
      # `String.new("hi")` returns `Nominal[String]` (RBS
      # gives us this for free); the plugin should map
      # that to `StringPolicy`. There's no `StringPolicy`
      # in the default fixtures, so we expect an
      # `unknown-policy-class` rather than a successful
      # `policy-call`. This shows the inferred-type path
      # *does* fire when the type is statically known.
      result = run_plugin(
        source: %(authorize(String.new("hi"), :show)\n),
        files: DEFAULT_POLICIES
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "unknown-policy-class" }
      expect(err).not_to be_nil
      expect(err.message).to include("StringPolicy")
    end
  end

  describe "unknown-policy-method diagnostics" do
    it "flags an authorize call whose action is not a defined predicate" do
      result = run_plugin(
        source: "authorize(Post, :destory)\n",
        files: DEFAULT_POLICIES
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "unknown-policy-method" }
      expect(err).not_to be_nil
      expect(err.message).to include("destory?")
      expect(err.message).to include("destroy")
    end

    it "lists known predicates in the message for actionable feedback" do
      result = run_plugin(
        source: "authorize(Post, :nope)\n",
        files: DEFAULT_POLICIES
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "unknown-policy-method" }
      expect(err.message).to include("show?")
      expect(err.message).to include("update?")
      expect(err.message).to include("destroy?")
    end
  end

  describe "unknown-policy-class diagnostics" do
    it "flags an authorize call whose record's type has no matching policy" do
      result = run_plugin(
        source: "authorize(NoSuchClass, :show)\n",
        files: DEFAULT_POLICIES
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "unknown-policy-class" }
      expect(err).not_to be_nil
      expect(err.message).to include("NoSuchClassPolicy")
    end

    it "suggests a near-match when one exists" do
      # `CommnetPolicy` would fuzzy-match `CommentPolicy`.
      result = run_plugin(
        source: "authorize(Commnet, :edit)\n",
        files: DEFAULT_POLICIES
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "unknown-policy-class" }
      expect(err).not_to be_nil
      expect(err.message).to include("CommentPolicy")
    end
  end

  describe "edge cases" do
    it "silently passes through `authorize` calls when the record's type is not Nominal" do
      result = run_plugin(
        source: "authorize(some_var, :show)\n",
        files: DEFAULT_POLICIES
      )
      diags = plugin_diagnostics(result)
      expect(diags).to be_empty
    end

    it "skips action validation when `authorize` has no second argument" do
      # The implicit form: pundit looks up the action from
      # the controller. We can still check the policy
      # class exists.
      result = run_plugin(
        source: "authorize(Post)\n",
        files: DEFAULT_POLICIES
      )
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "policy-call" }.size).to eq(1)
      expect(diags.select { |d| d.rule == "unknown-policy-method" }).to be_empty
    end

    it "ignores `authorize` calls with an explicit receiver (likely an unrelated method)" do
      result = run_plugin(
        source: "obj.authorize(Post, :show)\n",
        files: DEFAULT_POLICIES
      )
      expect(plugin_diagnostics(result)).to be_empty
    end
  end

  describe "configuration" do
    let(:custom_files) do
      {
        "app/policies/widget_policy.rb" => <<~RUBY
          class MyBasePolicy; end
          class WidgetPolicy < MyBasePolicy
            def show?
              true
            end
          end
        RUBY
      }
    end

    let(:custom_plugin_entry) do
      { "gem" => "rigor-pundit", "config" => { "policy_base_classes" => ["MyBasePolicy"] } }
    end

    it "respects custom `policy_base_classes`" do
      result = run_plugin(
        source: "authorize(Widget, :show)\n",
        files: custom_files,
        plugin_entry: custom_plugin_entry
      )
      info = plugin_diagnostics(result).find { |d| d.rule == "policy-call" }
      expect(info).not_to be_nil
      expect(info.message).to include("WidgetPolicy")
    end
  end
end
