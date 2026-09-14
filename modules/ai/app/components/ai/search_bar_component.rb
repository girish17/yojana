module Ai
  class SearchBarComponent < ApplicationComponent
    include OpPrimer::ComponentHelpers

    def initialize(project: nil)
      super
      @project = project
    end

    def search_path
      if @project
        Rails.application.routes.url_helpers.project_search_path(@project, q: "")
      else
        Rails.application.routes.url_helpers.search_path(q: "")
      end
    end

    def suggestions_path
      Rails.application.routes.url_helpers.ai_search_suggestions_path(project_id: @project&.id)
    end
  end
end
