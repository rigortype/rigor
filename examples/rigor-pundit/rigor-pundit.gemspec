# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-pundit"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin: validates Pundit `authorize` / `policy` / `policy_scope` calls."
  spec.description = "Walks `app/policies/` for classes whose direct superclass is " \
                     "`ApplicationPolicy`, indexes their predicate methods, and validates " \
                     "every `authorize(record, :action)` / `policy(record)` / " \
                     "`policy_scope(scope)` call site against the discovered policies. " \
                     "Records whose inferred type is `Nominal[T]` are mapped to `TPolicy` " \
                     "via Pundit's standard naming convention. No Rails runtime."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 2.0"
  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
