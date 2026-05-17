# frozen_string_literal: true

# rigor-dry-validation demo. Run from this directory:
#
#   cp .rigor.dist.yml .rigor.yml
#   RUBYLIB=$PWD/../lib bundle exec rigor check
#
# The canonical Dry::Validation::Contract subclass shapes:
# fully-qualified and lexical-Dry-nested. With the plugin
# enabled, rigor's `prepare(services)` hook scans this file,
# sees both subclasses, and publishes the
# `:dry_validation_contracts` fact = ["EmailContract",
# "NewUserContract"].
#
# The shipped RBS overlay (sig/dry_validation.rbs, wired via
# the `signature_paths:` config) types `contract.call(input)`
# as returning `Dry::Validation::Result`, so the chained
# `.success?` / `.to_h` queries below resolve cleanly.

class NewUserContract < Dry::Validation::Contract
  params do
    required(:email).filled(:string)
    required(:age).value(:integer)
  end

  rule(:email) do
    key.failure("has invalid format") unless value.include?("@")
  end
end

# The lexical-Dry path is the second supported recognition shape:
#
#   module Dry
#     class EmailContract < Validation::Contract
#       params { required(:email).filled(:string) }
#     end
#   end
#
# Omitted from this demo so the file doesn't redefine the
# `Dry::Validation::Contract` stub the RBS overlay also describes.

result = NewUserContract.new.call(email: "alice@example.com", age: 17)
if result.success?
  puts result.to_h.inspect
else
  puts result.errors.inspect
end
