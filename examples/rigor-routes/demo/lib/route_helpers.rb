# frozen_string_literal: true

# Tiny runtime — just enough to make demo.rb runnable. Real
# Rails apps would generate these helpers from the routes
# table at boot. The plugin's value is what `rigor check`
# reports about callers, not what the runtime returns here.

def users_path = "/users"
def users_url = "https://example.com/users"
def new_user_path = "/users/new"
def user_path(id) = "/users/#{id}"
def edit_user_path(id) = "/users/#{id}/edit"
def posts_path = "/posts"
def post_path(id) = "/posts/#{id}"
def post_comment_path(post_id, id) = "/posts/#{post_id}/comments/#{id}"
