Fosm::Engine.routes.draw do
  namespace :admin do
    root to: "dashboard#index"
    resources :apps, only: [ :index, :show ], param: :slug do
      member do
        get    :agent,       to: "agents#show"
        post   :agent_invoke, to: "agents#agent_invoke"
        get    "agent/chat",  to: "agents#chat",       as: :agent_chat
        post   "agent/chat",  to: "agents#chat_send",  as: :agent_chat_send
        delete "agent/chat",  to: "agents#chat_reset", as: :agent_chat_reset
      end
    end
    resources :transitions, only: [ :index ]
    resources :webhooks,    only: [ :index, :new, :create, :destroy ]
    resources :roles, only: [ :index, :new, :create, :destroy ] do
      collection do
        get :users_search
      end
    end
    resource :settings,    only: [ :show ]
  end
end
