module Ai
  class SuggestionService
    include LlmJson
    def initialize(subject:, project:, work_package: nil)
      @subject = subject
      @project = project
      @work_package = work_package
    end

    def call
      return empty_suggestions unless llm_available?
      return empty_suggestions if @subject.blank?

      prompt = build_prompt
      response = llm.chat([{ role: "system", content: prompt }, { role: "user", content: @subject }])
      parse_response(response)
    rescue Ai::LlmClient::Error, StandardError
      empty_suggestions
    end

    private

    def build_prompt
      types = @project.types.pluck(:id, :name).map { |id, name| "#{id}: #{name}" }.join(", ")
      priorities = IssuePriority.pluck(:id, :name).map { |id, name| "#{id}: #{name}" }.join(", ")
      users = @project.members.includes(:principal).map { |m| m.principal }.compact
      assignees = users.select { |u| u.is_a?(User) }.map { |u| "#{u.id}: #{u.name}" }.join(", ")

      <<~PROMPT
        You are a project management assistant for Yojana.
        Suggest the best values for a new work package based on its title/subject.
        Available types: #{types}
        Available priorities: #{priorities}
        Available assignees: #{assignees}

        Respond with ONLY a JSON object:
        {
          "type_id": <number or null>,
          "priority_id": <number or null>,
          "assignee_id": <number or null>,
          "reason": "brief explanation"
        }
        Choose the most appropriate values. Use null when unsure.
      PROMPT
    end

    def parse_response(response)
      content = content_from(response)
      return empty_suggestions if content.blank?

      parsed = JSON.parse(extract_json(content)).deep_symbolize_keys
      {
        type_id: parsed[:type_id],
        priority_id: parsed[:priority_id],
        assignee_id: parsed[:assignee_id],
        reason: parsed[:reason]
      }
    rescue JSON::ParserError, TypeError
      empty_suggestions
    end

    def empty_suggestions
      { type_id: nil, priority_id: nil, assignee_id: nil, reason: nil }
    end

    def llm
      @llm ||= Ai::LlmClient.new
    end

    def llm_available?
      llm.available?
    rescue StandardError
      false
    end
  end
end
