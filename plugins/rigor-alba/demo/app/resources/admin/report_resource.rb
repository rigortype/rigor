# frozen_string_literal: true

module Admin
  class ReportResource
    include Alba::Resource

    # Inferred under the resource's own namespace: Admin::EntryResource.
    many :entries
  end
end
