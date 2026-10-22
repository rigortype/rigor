# frozen_string_literal: true

# Integration spec for `plugins/rigor-devise/`. ADR-16 slice 3c. Exercises the substrate's Tier B path end-to-end:
#
# 1. Load the example plugin via the `rigor-devise` entry point.
# 2. Run rigor against a multi-file fixture with a User model using `devise :database_authenticatable,
#    :recoverable` plus a consumer file calling the synthesised methods cross-file.
# 3. Assert that bare reader calls resolve through the substrate (no `call.undefined-method` for Devise
#    module methods).
#
# Per WD13 floor — the synthesised methods return `Dynamic[T]`; this spec verifies the *name resolution* path,
# not precise return typing (which is slice-6 ceiling).

require "spec_helper"

DEVISE_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-devise/lib", __dir__)
$LOAD_PATH.unshift(DEVISE_PLUGIN_LIB) unless $LOAD_PATH.include?(DEVISE_PLUGIN_LIB)
require "rigor-devise"

RSpec.describe "rigor-devise integration" do
  let(:plugin_class) { Rigor::Plugin::Devise }

  let(:devise_rbs) do
    <<~RBS
      module ActiveRecord
        class Base
          def self.devise: (*Symbol) -> void
          def save: () -> bool
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

          module Validatable
            def password_required?: () -> bool
          end

          module Confirmable
            def confirmed?: () -> bool
            def confirm: () -> bool
          end

          module Omniauthable : ActiveRecord::Base
            def from_omniauth?: () -> bool
          end
        end
      end
    RBS
  end

  let(:demo_source) do
    <<~RUBY
      class ApplicationRecord < ActiveRecord::Base
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

  # Issue #476 — the example above cannot tell the tier from its absence: its receivers are untyped parameters,
  # so nothing fires either way. These receive a `User`, so the call's type is decided by the synthetic
  # tier: Tier B redispatches `valid_password?` on `Devise::Models::DatabaseAuthenticatable` and answers its
  # authored `bool`. The pre-pass used to hand the scanner no environment, which made the index empty and
  # the answer `Dynamic[top]` — silent here.
  describe "end to end through the Runner (#476)" do
    let(:typed_consumer_source) do
      <<~RUBY
        def authenticate(password)
          user = User.new
          user.valid_password?(password).no_such_bool_method
        end
      RUBY
    end

    it "resolves a synthesised method to the strategy module's authored return type" do
      result = run_under_plugin(demo: demo_source, consumer: typed_consumer_source)

      undefined = result.diagnostics.select { |d| d.rule.to_s == "call.undefined-method" }
      expect(undefined.map(&:message)).to contain_exactly(a_string_matching(/`no_such_bool_method' for bool/))
    end

    it "raises no diagnostic on the synthesised call itself" do
      result = run_under_plugin(
        demo: demo_source,
        consumer: "def authenticate(password)\n  User.new.valid_password?(password)\nend\n"
      )

      expect(result.diagnostics).to be_empty
    end

    # RBS builds a module's instance definition over `Object`. Without the owner filter the scanner put every
    # `Object` / `Kernel` method on `User` (`hash`, `to_s`, `puts` ...), and the arity rule treats a name in the
    # synthetic index as possibly rewritten by a plugin and stands down: the wrong call below went unreported.
    it "does not mute the arity check of the model's own override of an Object method" do
      result = run_under_plugin(
        demo: <<~RUBY,
          class ApplicationRecord < ActiveRecord::Base
          end

          class User < ApplicationRecord
            devise :database_authenticatable

            def hash
              1
            end
          end
        RUBY
        consumer: "def digest\n  User.new.hash(1, 2, 3)\nend\n"
      )

      expect(result.diagnostics.map(&:rule).map(&:to_s)).to include("call.wrong-arity")
    end

    # PR #2286 review S1 — Ruby answers a member the model declares, or a project module it includes after
    # `devise`, ahead of the Devise module; the synthetic tier used to answer them from the module's RBS. The
    # model's undeclared `send_reset_password_instructions` is the positive control (still `bool`).
    describe "a member the project declares on the model" do
      let(:shadowing_demo) do
        <<~RUBY
          class ApplicationRecord < ActiveRecord::Base
          end

          module PasswordPolicy
            def password_required?
              "policy"
            end
          end

          class User < ApplicationRecord
            devise :database_authenticatable, :validatable, :confirmable, :recoverable
            include PasswordPolicy

            def confirmed?
              :yes
            end
            alias_method :confirm, :confirmed?

            def valid_password?(a, b)
              a == b
            end
          end
        RUBY
      end

      let(:shadowing_consumer) do
        <<~RUBY
          def probe
            u = User.new
            u.password_required?.upcase
            u.confirmed?.to_proc
            u.confirm.to_proc
            u.valid_password?("x")
            u.send_reset_password_instructions.no_such_bool_method
          end
        RUBY
      end

      def consumer_rows(result)
        result.diagnostics.select { |d| d.path.end_with?("consumer.rb") }.to_h { |d| [d.line, d.rule.to_s] }
      end

      it "answers each from the project's member, and the model's own arity check stands" do
        rows = consumer_rows(run_under_plugin(demo: shadowing_demo, consumer: shadowing_consumer))

        expect(rows.fetch(3, nil)).to be_nil # PasswordPolicy#password_required? -> String
        expect(rows.fetch(4, nil)).to be_nil # User#confirmed? -> Symbol
        expect(rows.fetch(5, nil)).to be_nil # alias_method :confirm
        expect(rows.fetch(6, nil)).to eq("call.wrong-arity") # User#valid_password?(a, b)
        expect(rows.fetch(7, nil)).to eq("call.undefined-method") # Recoverable, undeclared by the project
      end
    end

    # PR #2286 review M2 — RBS builds `module Omniauthable : ActiveRecord::Base` over `ActiveRecord::Base`, so its
    # definition lists `save`. Ruby answers `save` from `ApplicationRecord`, which the module sits ahead of but
    # does not define it in; the module's own `from_omniauth?` is the positive control.
    it "does not synthesise a self-typed module's view of its self type's methods" do
      result = run_under_plugin(
        demo: <<~RUBY,
          class ApplicationRecord < ActiveRecord::Base
            def save
              :saved
            end
          end

          class User < ApplicationRecord
            devise :omniauthable
          end
        RUBY
        consumer: "def probe\n  u = User.new\n  u.save.to_proc\n  u.from_omniauth?.no_such_bool_method\nend\n"
      )

      expect(result.diagnostics.map { |d| [d.line, d.rule.to_s] }).to eq([[4, "call.undefined-method"]])
    end

    it "synthesises nothing for a model the project never declares with `devise`" do
      result = run_under_plugin(
        demo: "class ApplicationRecord < ActiveRecord::Base\nend\n\nclass User < ApplicationRecord\nend\n",
        consumer: typed_consumer_source
      )

      expect(result.diagnostics.select { |d| d.message.include?("no_such_bool_method") }).to be_empty
    end
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
        runner = Rigor::Analysis::Runner.new(
          configuration: configuration,
          cache_store: nil,
          plugin_requirer: lambda do |_name|
            Rigor::Plugin.register(plugin_class)
            true
          end
        )
        guarded_run(runner)
      end
    end
  end
end
