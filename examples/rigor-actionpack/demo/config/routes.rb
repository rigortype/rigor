# frozen_string_literal: true

# Sample Rails routes file for the rigor-actionpack demo.
# rigor-rails-routes statically interprets this DSL and
# publishes the helper table; rigor-actionpack consumes it
# at every controller-side call site.

Rails.application.routes.draw do
  root to: "home#index"

  resources :users do
    resources :posts
  end

  resource :profile

  namespace :admin do
    resources :widgets
  end

  get "/about", to: "static#about", as: :about
end
