# frozen_string_literal: true

# Sample Rails routes file for the rigor-rails-routes demo.
# rigor-rails-routes statically interprets this DSL via Prism;
# nothing here is executed.

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
