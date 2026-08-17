class WelcomeJob < ApplicationJob
  def perform(id)
    $welcomed = id
  end
end
