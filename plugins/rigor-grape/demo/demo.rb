# frozen_string_literal: true

# rigor-grape demo. Run from this directory:
#
#   RUBYLIB=$PWD/../lib bundle exec rigor check
#
# The .rigor.dist.yml here enables the plugin; the bundled `sig/grape.rbs` supplies the
# Grape/grape-entity DSL surface, and the manifest's `block_as_methods` entries narrow each
# block's `self` the way Grape `instance_eval`s it (`params` on ParamsScope, `namespace` on the
# API::Instance class object, verb bodies on Grape::Endpoint).
#
# Without the plugin every declaration below reads Dynamic[top]: `Grape::API` subclasses forward
# these calls to a runtime-generated base instance at load time, so nothing static sees them.

class Entities
  class Thing < Grape::Entity
    expose :id, documentation: { type: Integer, desc: "the id" }
    expose :name do
      expose :first
      expose :last
    end
    format_with(:iso_timestamp) { |d| d.utc.iso8601 }
  end
end

class ThingsAPI < Grape::API
  version "v1", using: :path
  format :json
  default_error_status 400

  desc "List things"
  params do
    optional :q, type: String, desc: "search query"
    requires :account_id, type: Integer
    requires :filter, type: Hash do
      requires :state, type: String, values: %w[open closed]
      optional :label, type: String
    end
    mutually_exclusive :q, :filter
  end
  get "/things" do
    present Thing.all, with: Entities::Thing
  end

  namespace :admin do
    route_setting :authorization, roles: %i[admin]
    desc "Delete a thing"
    delete "/things/:id" do
      error!("forbidden", 403) unless params["id"]
      status 204
    end
  end
end
