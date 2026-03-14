Fosm::Engine.routes.draw do
  namespace :admin do
    root to: "dashboard#index"
    resources :apps, only: [:index, :show], param: :slug
    resources :transitions, only: [:index]
    resources :webhooks, only: [:index, :new, :create, :destroy]
  end
end
