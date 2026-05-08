# frozen_string_literal: true

# Sample mailer — rigor-actionmailer discovers this class
# because its direct superclass is `ApplicationMailer` (one
# of the default `mailer_base_classes`). The discoverer
# reads each instance-side `def`'s parameter list to
# compute arity, and checks for matching view templates
# under `app/views/user_mailer/`.

class ApplicationMailer
  # Stand-in base class so `ruby app/mailers/user_mailer.rb`
  # parses standalone (without ActionMailer loaded).
  # rigor-actionmailer doesn't care whether the class is
  # declared here or anywhere else — it only matches by
  # name against `mailer_base_classes`.
  def self.with(*)
    self
  end
end

class UserMailer < ApplicationMailer
  def welcome(user, locale = "en")
    [user, locale]
  end

  def reset_password(user)
    user
  end

  def digest(*entries)
    entries
  end
end
