class UserMailer < ApplicationMailer
  def welcome(id)
    User.find(id)
  end
end
