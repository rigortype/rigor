# frozen_string_literal: true

# Integration spec for `examples/rigor-actionmailer/`.
# Tier 1C of the Rails plugins roadmap. Discovers
# ActionMailer subclasses by walking `app/mailers/` and
# validates `Mailer.action(args)` call shape (method exists,
# arity matches) and view template existence.

require "spec_helper"

ACTIONMAILER_PLUGIN_LIB = File.expand_path("../../../examples/rigor-actionmailer/lib", __dir__)
$LOAD_PATH.unshift(ACTIONMAILER_PLUGIN_LIB) unless $LOAD_PATH.include?(ACTIONMAILER_PLUGIN_LIB)
require "rigor-actionmailer"

DEFAULT_MAILERS = {
  "app/mailers/user_mailer.rb" => <<~RUBY,
    class ApplicationMailer
    end
    class UserMailer < ApplicationMailer
      def welcome(user, locale = "en")
        [user, locale]
      end

      def reset_password(user)
        user
      end

      def digest(*entries)
        entries
      end
    end
  RUBY
  "app/views/user_mailer/welcome.html.erb" => "<h1>Welcome</h1>\n",
  "app/views/user_mailer/welcome.text.erb" => "Welcome\n",
  "app/views/user_mailer/reset_password.html.erb" => "<a>Reset</a>\n",
  "app/views/user_mailer/digest.html.erb" => "<p>Digest</p>\n"
}.freeze

RSpec.describe "examples/rigor-actionmailer" do # rubocop:disable RSpec/DescribeClass
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Actionmailer }

  describe "recognised mailer calls" do
    it "emits an info diagnostic for `UserMailer.welcome(user)` matching the action's arity" do
      result = run_plugin(
        source: "UserMailer.welcome(:alice).deliver_now\n",
        files: DEFAULT_MAILERS
      )
      info = plugin_diagnostics(result).find { |d| d.rule == "mailer-call" }
      expect(info).not_to be_nil
      expect(info.severity).to eq(:info)
      expect(info.message).to include("UserMailer.welcome")
      expect(info.message).to include("1..2")
    end

    it "accepts a `.with(...).action` chain by treating `.with` as forwarding" do
      result = run_plugin(
        source: "UserMailer.with(user: :alice).welcome(:alice).deliver_later\n",
        files: DEFAULT_MAILERS
      )
      info = plugin_diagnostics(result).find { |d| d.rule == "mailer-call" }
      expect(info).not_to be_nil
      expect(info.message).to include("UserMailer.welcome")
    end

    it "accepts `*args` actions" do
      result = run_plugin(
        source: "UserMailer.digest(:a, :b, :c).deliver_now\n",
        files: DEFAULT_MAILERS
      )
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "wrong-arity" }).to be_empty
      expect(diags.select { |d| d.rule == "mailer-call" }.size).to be >= 1
    end
  end

  describe "wrong-arity diagnostics" do
    it "flags a call with too few arguments" do
      result = run_plugin(
        source: "UserMailer.reset_password.deliver_now\n",
        files: DEFAULT_MAILERS
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "wrong-arity" }
      expect(err).not_to be_nil
      expect(err.message).to include("got 0")
      expect(err.message).to include("UserMailer.reset_password")
    end

    it "flags a call with too many arguments" do
      result = run_plugin(
        source: "UserMailer.welcome(:alice, 'ja', :extra).deliver_now\n",
        files: DEFAULT_MAILERS
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "wrong-arity" }
      expect(err).not_to be_nil
      expect(err.message).to include("got 3")
    end
  end

  describe "unknown-action diagnostics" do
    it "flags a call to an action that the mailer does not define" do
      result = run_plugin(
        source: "UserMailer.unknown_action(:alice).deliver_now\n",
        files: DEFAULT_MAILERS
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "unknown-action" }
      expect(err).not_to be_nil
      expect(err.message).to include("UserMailer.unknown_action")
      expect(err.message).to include("known actions")
    end
  end

  describe "missing-view diagnostics" do
    it "flags actions whose view template is missing under `app/views/<mailer>/`" do
      files = DEFAULT_MAILERS.reject { |path, _| path.start_with?("app/views/user_mailer/welcome") }
      result = run_plugin(
        source: "# noop\n",
        files: files,
        paths: ["app/mailers/user_mailer.rb"]
      )
      missing = plugin_diagnostics(result).select { |d| d.rule == "missing-view" }
      expect(missing.map(&:message)).to include(a_string_including("UserMailer#welcome"))
    end

    it "does not flag actions that have at least one matching view (html OR text)" do
      files = DEFAULT_MAILERS.except("app/views/user_mailer/welcome.text.erb")
      result = run_plugin(
        source: "# noop\n",
        files: files,
        paths: ["app/mailers/user_mailer.rb"]
      )
      missing = plugin_diagnostics(result).select { |d| d.rule == "missing-view" }
      expect(missing.map(&:message).grep(/UserMailer#welcome/)).to be_empty
    end
  end

  describe "edge cases" do
    it "ignores `.action` calls when the receiver is not a discovered mailer class" do
      result = run_plugin(
        source: "RandomKlass.welcome(:alice).deliver_now\n",
        files: DEFAULT_MAILERS
      )
      diags = plugin_diagnostics(result)
      expect(diags.find { |d| d.message.include?("RandomKlass") }).to be_nil
    end

    it "doesn't validate framework methods that happen to be called on the mailer" do
      # `UserMailer.deliver_later` (no preceding action) is
      # a framework-level call; we don't try to validate it
      # as an action.
      result = run_plugin(
        source: "UserMailer.deliver_later\n",
        files: DEFAULT_MAILERS
      )
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "wrong-arity" }).to be_empty
      expect(diags.select { |d| d.rule == "unknown-action" }).to be_empty
    end
  end

  describe "configuration" do
    let(:custom_files) do
      {
        "app/mailers/custom_mailer.rb" => <<~RUBY,
          class MyBaseMailer; end
          class CustomMailer < MyBaseMailer
            def ping(x); x; end
          end
        RUBY
        "app/views/custom_mailer/ping.html.erb" => "<p>Ping</p>\n"
      }
    end

    let(:custom_plugin_entry) do
      { "gem" => "rigor-actionmailer", "config" => { "mailer_base_classes" => ["MyBaseMailer"] } }
    end

    it "respects custom `mailer_base_classes`" do
      result = run_plugin(
        source: "CustomMailer.ping(1).deliver_now\n",
        files: custom_files,
        plugin_entry: custom_plugin_entry
      )
      info = plugin_diagnostics(result).find { |d| d.rule == "mailer-call" }
      expect(info).not_to be_nil
    end
  end
end
