# frozen_string_literal: true

# Integration spec for `examples/rigor-devise/`. ADR-16 slice 3c.
# Exercises the substrate's Tier B path end-to-end:
#
# 1. Load the example plugin via the `rigor-devise` entry point.
# 2. Run rigor against a multi-file fixture with a User model
#    using `devise :database_authenticatable, :recoverable` plus a
#    consumer file calling the synthesised methods cross-file.
# 3. Assert that bare reader calls resolve through the substrate
#    (no `call.undefined-method` for Devise module methods).
#
# Per WD13 floor — the synthesised methods return `Dynamic[T]`;
# this spec verifies the *name resolution* path, not precise
# return typing (which is slice-6 ceiling).

require "spec_helper"

DEVISE_PLUGIN_LIB = File.expand_path("../../../examples/rigor-devise/lib", __dir__)
$LOAD_PATH.unshift(DEVISE_PLUGIN_LIB) unless $LOAD_PATH.include?(DEVISE_PLUGIN_LIB)
require "rigor-devise"

RSpec.describe "rigor-devise integration" do
  let(:plugin_class) { Rigor::Plugin::Devise }

  let(:devise_rbs) do
    <<~RBS
      module ActiveRecord
        class Base
          def self.devise: (*Symbol) -> void
        end
      end

      module Devise
        module Models
          module Authenticatable
            def email: () -> String?
          end

          module DatabaseAuthenticatable
            def valid_password?: (String) -> bool
            def update_with_password: (**untyped) -> bool
          end

          module Recoverable
            def send_reset_password_instructions: () -> bool
          end

          module Rememberable
            def remember_me!: () -> void
          end

          module Lockable
            def lock_access!: () -> void
            def access_locked?: () -> bool
          end

          module Trackable
            def failed_attempts: () -> Integer
          end

          module Timeoutable
            def timedout?: (Time) -> bool
          end
        end
      end
    RBS
  end

  let(:demo_source) do
    <<~RUBY
      class ApplicationRecord
      end

      class User < ApplicationRecord
        devise :database_authenticatable, :recoverable, :rememberable
      end

      class Admin < ApplicationRecord
        devise :database_authenticatable, :lockable, :timeoutable, :trackable
      end
    RUBY
  end

  let(:consumer_source) do
    <<~RUBY
      def authenticate(user, password)
        return :no_password unless user.valid_password?(password)

        user.update_with_password(password: password)
        :ok
      end

      def remember_user(user)
        user.remember_me!
      end

      def trigger_recovery(user)
        user.send_reset_password_instructions
      end

      def lock_admin_after_failures(admin)
        admin.lock_access! if admin.failed_attempts > 5
      end
    RUBY
  end

  it "registers a manifest with one Tier B trait registry covering the Devise strategy table" do
    manifest = plugin_class.manifest
    expect(manifest.id).to eq("devise")
    expect(manifest.trait_registries.size).to eq(1)
    registry = manifest.trait_registries.first
    expect(registry.receiver_constraint).to eq("ActiveRecord::Base")
    expect(registry.method_name).to eq(:devise)
    expect(registry.symbol_arg_position).to eq(:rest)
    expect(registry.always_included).to eq(["Devise::Models::Authenticatable"])
    expect(registry.module_for(:database_authenticatable))
      .to eq("Devise::Models::DatabaseAuthenticatable")
    expect(registry.module_for(:unknown_strategy)).to be_nil
  end

  it "synthesises module methods so cross-file calls resolve through the substrate" do
    result = run_under_plugin(demo: demo_source, consumer: consumer_source)
    expected_method_names = %w[
      valid_password? update_with_password remember_me!
      send_reset_password_instructions lock_access! failed_attempts
    ]
    undefined = result.diagnostics.select do |d|
      d.rule.to_s.include?("undefined-method") &&
        expected_method_names.any? { |name| d.message.include?(name) }
    end
    expect(undefined).to(
      be_empty,
      "expected Devise module methods to resolve cross-file via the substrate; " \
      "got: #{undefined.map(&:message).inspect}"
    )
  end

  def run_under_plugin(demo:, consumer:)
    Rigor::Plugin.unregister!
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "demo.rb"), demo)
      File.write(File.join(dir, "consumer.rb"), consumer)
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "sig", "devise.rbs"), devise_rbs)

      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          "paths" => [File.join(dir, "demo.rb"), File.join(dir, "consumer.rb")],
          "plugins" => ["rigor-devise"]
        )
      )

      Dir.chdir(dir) do
        Rigor::Analysis::Runner.new(
          configuration: configuration,
          cache_store: nil,
          plugin_requirer: lambda do |_name|
            Rigor::Plugin.register(plugin_class)
            true
          end
        ).run
      end
    end
  end
end
