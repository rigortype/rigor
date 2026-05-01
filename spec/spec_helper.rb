# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "rigor"

Dir[File.expand_path("support/**/*.rb", __dir__)].each { |f| require f }

RSpec.configure do |config|
  config.include RunnerHelpers, type: :runner
  config.define_derived_metadata(
    file_path: %r{/spec/rigor/analysis/runner_spec\.rb\z}
  ) do |meta|
    meta[:type] = :runner
  end
end
