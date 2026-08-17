class UsersController < ApplicationController
  def index
    User.where(active: true)
  end

  def show
    User.find(1)
  end

  def create
    user = User.new
    user.save
  end

  def enqueue
    WelcomeJob.perform_later(1)
  end

  def enqueue_later
    WelcomeJob.set(wait: 10).perform_later(1)
  end

  def run_now
    WelcomeJob.perform_now(1)
  end

  def deliver
    UserMailer.welcome(1).deliver_now
  end

  def login
    session[:user_id] = 1
  end

  def render_page
    render(:show)
  end
end
