# Class-side calls on `Post`, whose class body has no callback macro and no uniqueness validator for the
# callback edge to read. No synthesised unit stands in front of the `ActiveRecord::Base` row, so each method
# shows only what its one call contributes.
class PostMaintenance
  # Each reads before or while it writes: a lookup, a load of the records it then destroys or updates, a
  # count, or the `SELECT DISTINCT` id query an eager-loading, limited relation issues before its UPDATE /
  # DELETE.
  def via_find_or_create_by(title) = Post.find_or_create_by(title: title)
  def via_find_or_create_by!(title) = Post.find_or_create_by!(title: title)
  def via_create_or_find_by(title) = Post.create_or_find_by(title: title)
  def via_create_or_find_by!(title) = Post.create_or_find_by!(title: title)
  def via_first_or_create = Post.first_or_create
  def via_first_or_create! = Post.first_or_create!
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
  def via_reset_counters(id) = Post.reset_counters(id, :comments)

  # Each issues its statement and nothing before it: `create` is `new(…).save`, the bulk writers compile
  # one statement, and the counter writers are an `update_all` on `unscoped`.
  def via_create(title) = Post.create(title: title)
  def via_create!(title) = Post.create!(title: title)
  def via_insert(row) = Post.insert(row)
  def via_insert!(row) = Post.insert!(row)
  def via_insert_all(rows) = Post.insert_all(rows)
  def via_insert_all!(rows) = Post.insert_all!(rows)
  def via_upsert(row) = Post.upsert(row)
  def via_upsert_all(rows) = Post.upsert_all(rows)
  def via_update_counters(id) = Post.update_counters(id, comments_count: 1)
  def via_increment_counter(id) = Post.increment_counter(:comments_count, id)
  def via_decrement_counter(id) = Post.decrement_counter(:comments_count, id)

  # Readers Rails delegates to `all` that had no row, and so read as pure.
  def via_first_or_initialize = Post.first_or_initialize
  def via_second! = Post.second!
  def via_async_count = Post.async_count
  def via_extract_associated = Post.extract_associated(:blog)

  # `lock!` is `reload(lock: true)`, a `SELECT … FOR UPDATE`; `with_lock` runs it in a transaction.
  def via_lock! = Post.new.lock!
  def via_with_lock = Post.new.with_lock { nil }
end
