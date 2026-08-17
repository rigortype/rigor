class User < ApplicationRecord
  validates :email, uniqueness: true
  before_save :normalize_email
  after_commit :notify

  def normalize_email
    @email = email.to_s.downcase
  end

  def notify
    Rails.logger.info("user saved")
  end

  def email
    @email
  end
end
