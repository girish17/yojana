# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ai::MessagesController do
  let(:user) { create(:user, admin: true) }
  let(:conversation) { Ai::Conversation.create!(user:, title: "test") }

  before do
    login_as(user)
    allow(OpenProject::FeatureDecisions).to receive(:ai_chat_assistant_active?).and_return(true)
  end

  describe "feature gating" do
    before do
      allow(OpenProject::FeatureDecisions).to receive(:ai_chat_assistant_active?).and_return(false)
    end

    it "forbids access when feature is inactive" do
      post :create, params: { conversation_id: conversation.id, content: "hi" }
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST #create without SSE" do
    it "creates a user message and returns 201" do
      expect { post :create, params: { conversation_id: conversation.id, content: "hi" } }
        .to change(conversation.messages, :count).by(1)
      expect(response).to have_http_status(:created)
    end

    it "rejects blank content with 422" do
      post :create, params: { conversation_id: conversation.id, content: "   " }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "POST #create with SSE" do
    def stub_chat_service
      service = instance_double(Ai::ChatService)
      allow(Ai::ChatService).to receive(:new).and_return(service)
      service
    end

    it "streams connected, token, done and completed events" do
      service = stub_chat_service
      allow(service).to receive(:call) do |stream: true, &block|
        expect(stream).to be(true)
        block.call({ type: :token, content: "Hel" })
        block.call({ type: :token, content: "lo" })
        block.call({ type: :done, content: "Hello" })
      end

      request.headers["Accept"] = "text/event-stream"
      post :create, params: { conversation_id: conversation.id, content: "hi" }

      expect(response.headers["Content-Type"]).to eq("text/event-stream")
      body = response.body
      expect(body).to include("event: connected")
      expect(body).to include("event: token")
      expect(body).to include("Hel")
      expect(body).to include("lo")
      expect(body).to include("event: done")
      expect(body).to include("event: completed")
    end

    it "emits error event when the stream raises" do
      service = stub_chat_service
      allow(service).to receive(:call).and_raise("LLM broke")

      request.headers["Accept"] = "text/event-stream"
      post :create, params: { conversation_id: conversation.id, content: "hi" }

      body = response.body
      expect(body).to include("event: error")
      expect(body).to include(I18n.t("ai.chat_error"))
    end

    it "survives a closed stream (IOError) without raising" do
      service = stub_chat_service
      allow(service).to receive(:call).and_raise(IOError)

      request.headers["Accept"] = "text/event-stream"
      post :create, params: { conversation_id: conversation.id, content: "hi" }

      expect(response).to have_http_status(:ok)
    end
  end
end
