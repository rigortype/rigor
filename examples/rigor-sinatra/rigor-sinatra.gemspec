# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-sinatra"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin example: ADR-16 Tier A worked target (block-as-method)."
  spec.description = "Recognises Sinatra's class-level route DSL (`get '/path' do ... end`, " \
                     "`post`, `put`, `delete`, `head`, `options`, `patch`, `link`, `unlink`) " \
                     "and narrows the block body's `self` to an instance of the enclosing " \
                     "`Sinatra::Base` subclass. The block then resolves bare identifiers " \
                     "(`params`, `redirect`, `halt`, etc.) through `Sinatra::Base`'s RBS via " \
                     "rigor's normal inference path. ADR-16 slice 1c — the first worked " \
                     "consumer of `Plugin::Macro::BlockAsMethod`."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
