# frozen_string_literal: true

# DO NOT run via `ruby errors_demo.rb` — analyse with
# `bundle exec rigor check` to see rigor-pundit's
# diagnostics.

def authorize(_record, _action = nil); end
def policy(_record); end

# Misspelled action — flagged with did-you-mean:
#   plugin.pundit.unknown-policy-method
authorize(Post, :destory)

# Action genuinely not on PostPolicy:
#   plugin.pundit.unknown-policy-method
authorize(Post, :archive)

# Misspelled record (so the policy class doesn't exist) —
# flagged with did-you-mean against the known policies:
#   plugin.pundit.unknown-policy-class
authorize(Commnet, :edit)

# Record has no policy at all:
#   plugin.pundit.unknown-policy-class
policy(NoSuchClass)
