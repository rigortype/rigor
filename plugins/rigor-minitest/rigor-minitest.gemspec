# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-minitest"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin: narrows locals through Minitest / Test::Unit assertions."
  spec.description = "Recognises `assert_kind_of(T, x)` / `assert_instance_of(T, x)` / " \
                     "`assert_nil(x)` / `assert_equal(literal, x)` / `assert_match(regex, x)` " \
                     "and their `refute_*` / `assert_not_*` mirrors at every call site the " \
                     "dispatcher visits, plus the Minitest spec-style `_(x).must_be_kind_of(T)` " \
                     "/ `_(x).must_be_nil` / `_(x).must_equal(literal)` / `_(x).wont_be_nil` " \
                     "forms. Each recognised assertion emits a Rigor `post_return_fact` that " \
                     "narrows the named local from the assertion onward so downstream calls in " \
                     "the same test body resolve against the narrowed type. Covers BOTH " \
                     "Minitest and Test::Unit (their `assert_*` / `refute_*` API is " \
                     "compatible); the matchers_vaccine gem's `must` matchers fall through " \
                     "the same spec-style recogniser. No Minitest / Test::Unit runtime " \
                     "dependency."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 2.0"
  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
