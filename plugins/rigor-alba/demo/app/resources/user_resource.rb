# frozen_string_literal: true

class UserResource
  include Alba::Resource

  attributes :id, :name

  # No `resource:` — alba infers ArticleResource (and, failing that, CommentSerializer) from the name.
  many :articles
  many :comments
  # Names its resource, so alba never infers `ReviewResource`: it stays an unused candidate.
  many :reviews, resource: CommentSerializer
end
