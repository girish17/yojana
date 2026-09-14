# frozen_string_literal: true

require "billy"
require "spec_helper"

RSpec.describe Ai::AgentsController do
  let(:user) { create(:admin) }

  describe "authorization" do
    before do
      allow(OpenProject::FeatureDecisions).to receive(:ai_agents_active?).and_return(true)
    end

    context "when not logged in" do
      it "returns 401 for index" do
        get :index, format: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when logged in" do
      before do
        login_as(user)
      end

      it "allows access" do
        get :index, format: :json
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "feature gating" do
    before do
      login_as(user)
      allow(OpenProject::FeatureDecisions).to receive(:ai_agents_active?).and_return(false)
    end

    it "forbids access when feature is inactive" do
      get :index, format: :json
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET #index" do
    before do
      login_as(user)
      allow(OpenProject::FeatureDecisions).to receive(:ai_agents_active?).and_return(true)
    end

    let!(:agent) { create(:ai_agent, user:) }

    it "returns a successful JSON response" do
      get :index, format: :json
      expect(response).to have_http_status(:ok)
    end

    it "returns only the current user's agents" do
      other_agent = create(:ai_agent, user: create(:user))
      get :index, format: :json
      ids = response.parsed_body.map { |a| a["id"] }
      expect(ids).to include(agent.id)
      expect(ids).not_to include(other_agent.id)
    end

    it "renders HTML when requested" do
      get :index
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("text/html")
    end

    it "returns agents ordered by recent" do
      old_agent = create(:ai_agent, user:, updated_at: 1.day.ago)
      get :index, format: :json
      expect(response.parsed_body.first["id"]).to eq(agent.id)
    end
  end

  describe "GET #show" do
    before do
      login_as(user)
      allow(OpenProject::FeatureDecisions).to receive(:ai_agents_active?).and_return(true)
    end

    let!(:agent) { create(:ai_agent, user:) }

    it "returns the agent" do
      get :show, params: { id: agent.id }, format: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["id"]).to eq(agent.id)
    end

    it "includes recent executions" do
      execution = create(:ai_agent_execution, :completed, agent:)
      get :show, params: { id: agent.id }, format: :json
      expect(response.parsed_body["executions"]).to be_present
    end

    it "returns 404 for another user's agent" do
      other_agent = create(:ai_agent, user: create(:user))
      get :show, params: { id: other_agent.id }, format: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST #create" do
    before do
      login_as(user)
      allow(OpenProject::FeatureDecisions).to receive(:ai_agents_active?).and_return(true)
    end

    let(:valid_params) do
      {
        name: "New Agent",
        prompt: "You are a new agent",
        cron_expression: "0 9 * * *",
        agent_type: "custom"
      }
    end

    it "creates a new agent" do
      expect do
        post :create, params: valid_params, format: :json
      end.to change(Ai::Agent, :count).by(1)
    end

    it "returns created status" do
      post :create, params: valid_params, format: :json
      expect(response).to have_http_status(:created)
    end

    it "assigns the current user" do
      post :create, params: valid_params, format: :json
      expect(Ai::Agent.last.user).to eq(user)
    end

    it "returns errors on invalid params" do
      post :create, params: { name: "" }, format: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["errors"]).to be_present
    end
  end

  describe "PATCH #update" do
    before do
      login_as(user)
      allow(OpenProject::FeatureDecisions).to receive(:ai_agents_active?).and_return(true)
    end

    let!(:agent) { create(:ai_agent, user:, name: "Original") }

    it "updates the agent" do
      patch :update, params: { id: agent.id, name: "Updated" }, format: :json
      expect(agent.reload.name).to eq("Updated")
    end

    it "returns the updated agent" do
      patch :update, params: { id: agent.id, name: "Updated" }, format: :json
      expect(response.parsed_body["name"]).to eq("Updated")
    end

    it "returns unprocessable on invalid" do
      patch :update, params: { id: agent.id, name: "" }, format: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "DELETE #destroy" do
    before do
      login_as(user)
      allow(OpenProject::FeatureDecisions).to receive(:ai_agents_active?).and_return(true)
    end

    let!(:agent) { create(:ai_agent, user:) }

    it "deletes the agent" do
      expect do
        delete :destroy, params: { id: agent.id }, format: :json
      end.to change(Ai::Agent, :count).by(-1)
    end

    it "returns no content" do
      delete :destroy, params: { id: agent.id }, format: :json
      expect(response).to have_http_status(:no_content)
    end
  end

  describe "GET #executions" do
    before do
      login_as(user)
      allow(OpenProject::FeatureDecisions).to receive(:ai_agents_active?).and_return(true)
    end

    let!(:agent) { create(:ai_agent, user:) }
    let!(:execution) { create(:ai_agent_execution, :completed, agent:) }

    it "returns executions" do
      get :executions, params: { id: agent.id }, format: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["executions"].length).to eq(1)
    end

    it "returns executions in reverse chronological order" do
      old_exec = create(:ai_agent_execution, :completed, agent:, created_at: 1.day.ago)
      get :executions, params: { id: agent.id }, format: :json
      expect(response.parsed_body["executions"].first["id"]).to eq(execution.id)
    end
  end
end
