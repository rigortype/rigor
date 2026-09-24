# `blog.posts` returns a `CollectionProxy`, which rigor-activerecord types as `Relation[Post]`. The proxy is
# held in an ivar so that no method below calls the association reader itself: each row then shows only
# what the relation call contributes.
class PostDrafts
  def initialize(blog_id)
    @posts = Blog.find(blog_id).posts
  end

  # `build` and `new` push the record into the association's target, so a later `@posts.size` counts it.
  def draft
    @posts.build
  end

  def draft_new
    @posts.new
  end

  def publish(title)
    @posts.create(title: title)
  end

  # Drops every record built on the proxy and not yet saved.
  def discard
    @posts.reset
  end

  # Writers only a proxy defines.
  def attach(post)
    @posts << post
  end

  def detach(post)
    @posts.delete(post)
  end

  # A query builder hands back a new relation and leaves this one alone.
  def titled(title)
    @posts.where(title: title)
  end
end
