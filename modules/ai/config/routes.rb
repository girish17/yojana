Rails.application.routes.draw do
  namespace :ai do
    resources :conversations, only: %i[index show create destroy] do
      resources :messages, only: %i[index create] do
        post :confirm, on: :collection
      end
    end

    resource :settings, only: %i[show update]

    # Inline AI: natural language search
    post "search" => "search#create", as: :search
    post "search/suggestions" => "search#suggestions", as: :search_suggestions

    # Inline AI: summarization
    post "summaries" => "summaries#create", as: :summaries
    post "summaries/from_text" => "summaries#create_from_text", as: :summaries_from_text

    # Inline AI: smart suggestions (scoped to project)
    scope "projects/:project_id" do
      post "suggestions" => "suggestions#create", as: :project_suggestions
    end

    # AI Agents: CRUD and executions
    resources :agents, only: %i[index show create update destroy] do
      get :executions, on: :member
    end
  end

end
