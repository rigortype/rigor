# `blog.posts` returns a `CollectionProxy`, which rigor-activerecord types as `Relation[Post]`. The proxy is
# held in an ivar so that no method below calls the association reader itself: each row then shows only
# what the one relation call contributes.
class PostDrafts
  def initialize(blog_id)
    @posts = Blog.find(blog_id).posts
  end

  # Builders: each pushes the record into the association's target, so a later `@posts.size` counts it.
  def via_build = @posts.build
  def via_new = @posts.new
  def via_create(title) = @posts.create(title: title)
  def via_create!(title) = @posts.create!(title: title)
  def via_find_or_create_by(title) = @posts.find_or_create_by(title: title)
  def via_find_or_create_by!(title) = @posts.find_or_create_by!(title: title)
  def via_find_or_initialize_by(title) = @posts.find_or_initialize_by(title: title)
  def via_create_or_find_by(title) = @posts.create_or_find_by(title: title)
  def via_create_or_find_by!(title) = @posts.create_or_find_by!(title: title)
  def via_first_or_create = @posts.first_or_create
  def via_first_or_create! = @posts.first_or_create!
  def via_first_or_initialize = @posts.first_or_initialize

  # A query builder on the proxy returns an `AssociationRelation`, whose `build` still reaches the
  # association.
  def via_scoped_build(title) = @posts.where(title: title).build

  # Each drops every record built on the proxy and not yet saved.
  def via_reset = @posts.reset
  def via_reload = @posts.reload
  def via_delete_all = @posts.delete_all
  def via_destroy_all = @posts.destroy_all
  def via_update_all(title) = @posts.update_all(title: title)
  def via_touch_all = @posts.touch_all
  def via_insert_all(rows) = @posts.insert_all(rows)
  def via_insert_all!(rows) = @posts.insert_all!(rows)
  def via_upsert_all(rows) = @posts.upsert_all(rows)

  # Writers a plain Relation does not define.
  def via_shovel(post) = @posts << post
  def via_push(post) = @posts.push(post)
  def via_append(post) = @posts.append(post)
  def via_concat(post) = @posts.concat(post)
  def via_replace(posts) = @posts.replace(posts)
  def via_delete(post) = @posts.delete(post)
  def via_destroy(post) = @posts.destroy(post)
  def via_clear = @posts.clear

  # A query builder hands back a new relation and leaves the target alone.
  def titled(title)
    @posts.where(title: title)
  end
end
