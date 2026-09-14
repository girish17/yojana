module Ai
  class AgentsController < ApplicationController
    no_authorization_required! :index, :show, :create, :update, :destroy, :executions
    before_action :require_login
    before_action :require_ai_agents
    before_action :find_agent, only: %i[show update destroy executions]

    def index
      agents = Ai::Agent.for_user(User.current).recent
      respond_to do |format|
        format.json { render json: agents.map { |a| serialize_agent(a) } }
        format.html { render :index, layout: "no_menu" }
      end
    end

    def show
      render json: serialize_agent(@agent).merge(
        executions: @agent.executions.recent.limit(20).map { |e| serialize_execution(e) }
      )
    end

    def create
      agent = Ai::Agent.new(agent_params.merge(user: User.current))
      if agent.save
        render json: serialize_agent(agent), status: :created
      else
        render json: { errors: agent.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def update
      if @agent.update(agent_params)
        render json: serialize_agent(@agent)
      else
        render json: { errors: @agent.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def destroy
      @agent.destroy
      head :no_content
    end

    def executions
      render json: { executions: @agent.executions.recent.limit(50).map { |e| serialize_execution(e) } }
    end

    private

    def find_agent
      @agent = Ai::Agent.for_user(User.current).find(params[:id])
    end

    def agent_params
      params.permit(:name, :description, :prompt, :cron_expression, :active, :agent_type, :project_id, config: {})
    end

    def serialize_agent(a)
      {
        id: a.id,
        name: a.name,
        description: a.description,
        prompt: a.prompt,
        cron_expression: a.cron_expression,
        active: a.active,
        agent_type: a.agent_type,
        project_id: a.project_id,
        created_at: a.created_at,
        updated_at: a.updated_at,
        execution_count: a.executions.count,
        last_run_at: a.executions.completed.order(created_at: :desc).first&.created_at
      }
    end

    def serialize_execution(e)
      {
        id: e.id,
        status: e.status,
        result: e.result,
        error_message: e.error_message,
        started_at: e.started_at,
        completed_at: e.completed_at,
        created_at: e.created_at
      }
    end

    def require_ai_agents
      return true if OpenProject::FeatureDecisions.ai_agents_active?

      render json: { error: I18n.t("ai.feature_unavailable") }, status: :forbidden
      false
    end
  end
end
