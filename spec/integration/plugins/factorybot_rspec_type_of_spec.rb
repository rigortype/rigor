# frozen_string_literal: true

# Integration spec for the cross-plugin channel between `plugins/rigor-factorybot/` and
# `plugins/rigor-rspec/` (#921): rigor-rspec's `let`-binding resolver reads the `:factory_index` ADR-9
# fact rigor-factorybot publishes to bind `let(:user) { create(:user) }` to `Nominal[User]`. Drives the
# real `rigor type-of` CLI end to end — through `Rigor::ProjectEnvironment`, the plugin loader, and the
# `dynamic_return file_methods:` dispatch path — rather than constructing the plugin/fact-store plumbing
# by hand, so a regression anywhere in that chain (not just a missing `publish` call) fails this spec.

require "spec_helper"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"

FACTORYBOT_RSPEC_TYPE_OF_FACTORYBOT_LIB = File.expand_path("../../../plugins/rigor-factorybot/lib", __dir__)
FACTORYBOT_RSPEC_TYPE_OF_RSPEC_LIB = File.expand_path("../../../plugins/rigor-rspec/lib", __dir__)
[FACTORYBOT_RSPEC_TYPE_OF_FACTORYBOT_LIB, FACTORYBOT_RSPEC_TYPE_OF_RSPEC_LIB].each do |lib|
  $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
end
require "rigor-factorybot"
require "rigor-rspec"

RSpec.describe "rigor-factorybot + rigor-rspec: :factory_index fact binds create(:name) under type-of (#921)" do
  # `require` runs a gem's body (and its `Rigor::Plugin.register` call) at most once per process — this
  # file's own top-level `require` above already did it once, so `Plugin::Loader`'s later require (inside
  # `run_cli`) is a silent no-op and its newly-registered-ids delta is empty. Registering the already-loaded
  # classes back onto the (freshly emptied) registry here, and pairing it with an explicit `id:` in the
  # `.rigor.yml` fixture below, sidesteps that delta entirely — `Plugin::Loader` resolves an `id:`-bearing
  # entry straight off `Plugin.registered_for(id)` (see `plugin_helpers.rb`'s `build_plugin_requirer` for
  # the sibling trick the `run_plugin` integration helper uses for the same reason).
  before do
    Rigor::Plugin.unregister!
    Rigor::Plugin.register(Rigor::Plugin::Factorybot)
    Rigor::Plugin.register(Rigor::Plugin::Rspec)
    write_fixture("user.rb", "class User\nend\n")
    write_fixture("spec/factories/users.rb", <<~RUBY)
      FactoryBot.define do
        factory :user, class: "User" do
          name { "Alice" }
        end
      end
    RUBY
    write_fixture("spec/user_spec.rb", <<~RUBY)
      RSpec.describe User do
        let(:user) { create(:user) }

        it "works" do
          expect(user).to be_a(User)
        end
      end
    RUBY
    write_fixture(".rigor.yml", <<~YAML)
      plugins:
        - gem: rigor-factorybot
          id: factorybot
        - gem: rigor-rspec
          id: rspec
    YAML
  end

  after do
    Rigor::Plugin.unregister!
    FileUtils.remove_entry(tmpdir)
  end

  let(:tmpdir) { Dir.mktmpdir }

  def write_fixture(relative_path, contents)
    path = File.join(tmpdir, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    path
  end

  def run_cli(*argv)
    out = StringIO.new
    err = StringIO.new
    status = Rigor::CLI.start(argv, out: out, err: err)

    [status, out.string, err.string]
  end

  it "types the `let`-bound factory local as the factory's model class" do
    status, out, err = Dir.chdir(tmpdir) do
      run_cli("type-of", "--format=json", "--config", ".rigor.yml", "spec/user_spec.rb:5:12")
    end

    expect(err).to eq("")
    expect(status).to eq(0)
    expect(JSON.parse(out)["type"]).to eq("User")
  end
end
