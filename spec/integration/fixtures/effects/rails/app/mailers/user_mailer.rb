class UserMailer < ApplicationMailer
  def welcome(id)
    User.find(id)
  end

  # The wrapper a mailer writes for itself. The builder call is implicit-self, so the constant the
  # `on_result:` row keys on is not written anywhere at the call site (#456) — Redmine spells all 97 of
  # its deliveries this way.
  def self.deliver_welcome(id)
    welcome(id).deliver_later
  end
end
