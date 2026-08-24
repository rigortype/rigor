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

  # ActionMailer's parameterized form: `with` returns a lazy Parameterized::Mailer nothing types, so the
  # class that produced the delivery is two calls out rather than one (#456). Mastodon spells it this way.
  def deliver_parameterized
    UserMailer.with(id: 1).welcome(1).deliver_later
  end
  # The enqueue. `NotifyWorker` includes rather than inherits, so this is the row a superclass-only
  # ancestry walk could never have reached (#456).
  def enqueue
    NotifyWorker.perform_async(1)
  end
end
