module Ai
  class SearchService
    include LlmJson
    def initialize(query, user: User.current, project: nil)
      @query = query
      @user = user
      @project = project
    end

    def call
      unless llm_available?
        results = execute_search({ q: @query, scope: "all", filters: {} })
        return { q: @query, scope: "all", filters: {}, results:, summary: nil, count: results.size }
      end

      structured = parse_query
      return fallback_search if structured[:q].blank?

      results = execute_search(structured)
      summarize_results(structured, results)
    rescue Ai::LlmClient::Error
      fallback_search
    rescue StandardError
      fallback_search
    end

    private

    def parse_query
      prompt = <<~PROMPT
        You are a search assistant for Yojana, a project management tool.
        #{@project ? "User is in project: #{@project.name}" : "No specific project context"}

        Parse this natural language query into search parameters.
        Respond with ONLY a JSON object like this:
        {
          "q": "core search keywords",
          "scope": "work_packages" | "projects" | "all",
          "status": "open" | "closed" | null,
          "assignee": "me" | null,
          "priority": "high" | "medium" | "low" | null,
          "type": "task" | "bug" | "feature" | "epic" | null
        }
        Use null for any unspecified filters.
      PROMPT

      response = llm.chat([{ role: "system", content: prompt }, { role: "user", content: @query }])
      content = content_from(response)
      JSON.parse(extract_json(content)).deep_symbolize_keys
    rescue JSON::ParserError, TypeError
      { q: @query, scope: "all", filters: {} }
    end

    def execute_search(params)
      scope = case params[:scope]&.to_sym
              when :work_packages then WorkPackage.visible
              when :projects then Project.visible
              else WorkPackage.visible
              end

      scope = scope.where(project_id: @project.id) if @project

      if params[:status] == "open"
        scope = scope.where(status_id: Status.where(is_closed: false).select(:id))
      elsif params[:status] == "closed"
        scope = scope.where(status_id: Status.where(is_closed: true).select(:id))
      end

      if params[:assignee] == "me"
        scope = scope.where(assigned_to_id: @user.id)
      end

      if params[:type].present?
        scope = scope.where(type_id: Type.where(name: params[:type]).select(:id))
      end

      if params[:priority].present?
        scope = scope.where(priority_id: IssuePriority.where(name: params[:priority]).select(:id))
      end

      search_term = params[:q].to_s.strip
      if params[:scope] == "projects"
        scope.where("name ILIKE :q OR LOWER(description) ILIKE :q", q: "%#{search_term}%")
             .limit(10)
             .includes(:status, :members)
             .map { |p| project_summary(p) }
      else
        clauses, args = token_conditions(search_term)
        scope.where(clauses, *args)
             .limit(10)
             .includes(:type, :status, :assigned_to, :project)
             .map { |wp| work_package_summary(wp) }
      end
    end

    # Match each whitespace-separated token against subject/description so that
    # a phrase like "my open tasks" still surfaces relevant work packages.
    def token_conditions(query)
      terms = query.split(/\s+/).reject(&:blank?)
      return ["1 = 0", []] if terms.empty?

      clauses = terms.map do |t|
        "(subject ILIKE ? OR LOWER(description) ILIKE ?)"
      end.join(" AND ")
      args = terms.flat_map { |t| ["%#{t}%", "%#{t}%"] }
      [clauses, args]
    end

    def work_package_summary(wp)
      {
        id: wp.id,
        subject: wp.subject,
        type: wp.type&.name,
        status: wp.status&.name,
        assignee: wp.assigned_to&.name,
        project: wp.project&.name,
        url: "/work_packages/#{wp.id}"
      }
    end

    def project_summary(project)
      {
        id: project.id,
        name: project.name,
        description: project.description&.truncate(100),
        status: project.status,
        members_count: project.members.count,
        url: "/projects/#{project.id}"
      }
    end

    def summarize_results(params, results)
      return fallback_search if results.empty?

      prompt = <<~PROMPT
        You are a helpful search assistant. The user asked: "#{@query}"

        The search found #{results.size} results:
        #{results.take(5).map { |r| " - #{r[:subject] || r[:name]} (status: #{r[:status]}, type: #{r[:type] || r[:status]})" }.join("\n")}

        Provide a brief, friendly summary (1-2 sentences) of what was found.
        If results seem unrelated to the query, acknowledge that.
        Do NOT list every result — just summarize them naturally.
        Include the count if there are more than shown.
      PROMPT

      summary = llm.chat([{ role: "system", content: prompt }, { role: "user", content: @query }])
      summary_text = summary.is_a?(Hash) ? summary.dig("message", "content") : summary.to_s

      {
        q: params[:q],
        scope: params[:scope] || "all",
        filters: {},
        results: results,
        summary: summary_text&.strip,
        count: results.size
      }
    rescue StandardError
      {
        q: params[:q],
        scope: params[:scope] || "all",
        filters: {},
        results: results,
        summary: nil,
        count: results.size
      }
    end

    def fallback_search
      { q: @query, scope: "all", filters: {}, results: [], summary: nil, count: 0 }
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
