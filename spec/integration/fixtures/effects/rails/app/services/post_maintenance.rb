# Class-side writers on a model whose class body declares no callback and no validator, so no synthesised
# unit stands in front of the `ActiveRecord::Base` row: each method shows only what its one call contributes.
class PostMaintenance
  # Each reads before or while it writes: a lookup, a load of the records it then destroys or updates, or
  # the `SELECT DISTINCT` id query an eager-loading, limited relation issues before its UPDATE / DELETE.
  def via_find_or_create_by(title) = Post.find_or_create_by(title: title)
  def via_find_or_create_by!(title) = Post.find_or_create_by!(title: title)
  def via_create_or_find_by(title) = Post.create_or_find_by(title: title)
  def via_create_or_find_by!(title) = Post.create_or_find_by!(title: title)
  def via_update(id, title) = Post.update(id, title: title)
  def via_update!(id, title) = Post.update!(id, title: title)
  def via_destroy(id) = Post.destroy(id)
  def via_destroy_all = Post.destroy_all
  def via_destroy_by(title) = Post.destroy_by(title: title)
  def via_delete(id) = Post.delete(id)
  def via_delete_all = Post.delete_all
  def via_delete_by(title) = Post.delete_by(title: title)
  def via_update_all(title) = Post.update_all(title: title)
  def via_touch_all = Post.touch_all

  # Each issues its INSERT and nothing before it: `create` is `new(…).save`, and the bulk writers compile
  # one statement.
  def via_create(title) = Post.create(title: title)
  def via_create!(title) = Post.create!(title: title)
  def via_insert(row) = Post.insert(row)
  def via_insert!(row) = Post.insert!(row)
  def via_insert_all(rows) = Post.insert_all(rows)
  def via_insert_all!(rows) = Post.insert_all!(rows)
  def via_upsert(row) = Post.upsert(row)
  def via_upsert_all(rows) = Post.upsert_all(rows)
end
