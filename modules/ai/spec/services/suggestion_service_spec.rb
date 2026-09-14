# frozen_string_literal: true

require "billy"
require "spec_helper"

RSpec.describe Ai::SuggestionService do
  let(:project) { create(:project) }
  let(:work_package_type) { create(:type) }
  let(:priority) { create(:issue_priority) }
  let(:assignee) { create(:user) }
  let(:role) { create(:project_role, permissions: [:view_work_packages]) }

  let(:llm_client) { instance_double(Ai::LlmClient) }

  subject(:service) { described_class.new(subject: "Fix login redirect", project:) }

  before do
    create(:member, user: assignee, project:, roles: [role])
    allow(Ai::LlmClient).to receive(:new).and_return(llm_client)
  end

  describe "#call" do
    context "when the LLM returns a plain JSON string" do
      before do
        allow(llm_client).to receive_messages(available?: true,
                                              chat: '{"type_id": 1, "priority_id": 2, "assignee_id": 3, "reason": "Urgent fix"}')
      end

      it "returns the parsed suggestions" do
        result = service.call
        expect(result[:type_id]).to eq(1)
        expect(result[:priority_id]).to eq(2)
        expect(result[:assignee_id]).to eq(3)
        expect(result[:reason]).to eq("Urgent fix")
      end
    end

    context "when the LLM returns a hash with message content key" do
      let(:llm_response) do
        content = '{"type_id": null, "priority_id": 1, "assignee_id": null, "reason": null}'
        { "message" => { "role" => "assistant", "content" => content } }
      end

      before do
        allow(llm_client).to receive_messages(available?: true, chat: llm_response)
      end

      it "unwraps the message content before parsing" do
        result = service.call
        expect(result[:type_id]).to be_nil
        expect(result[:priority_id]).to eq(1)
      end
    end

    context "when the LLM wraps JSON in markdown fences" do
      let(:fenced_json) do
        "```json\n{\"type_id\": 2, \"priority_id\": 5, \"assignee_id\": null, \"reason\": \"Refactor\"}\n```"
      end

      before do
        allow(llm_client).to receive_messages(available?: true, chat: fenced_json)
      end

      it "strips fences and parses" do
        result = service.call
        expect(result[:type_id]).to eq(2)
        expect(result[:reason]).to eq("Refactor")
      end
    end

    context "when the LLM response is not valid JSON" do
      before do
        allow(llm_client).to receive_messages(available?: true, chat: "I'm not sure about this")
      end

      it "returns empty suggestions" do
        expect(service.call).to eq(type_id: nil, priority_id: nil, assignee_id: nil, reason: nil)
      end
    end

    context "when the LLM is unavailable" do
      before do
        allow(llm_client).to receive_messages(available?: false,
                                              chat: empty_hash)
      end

      let(:empty_hash) { { type_id: nil, priority_id: nil, assignee_id: nil, reason: nil } }

      it "returns empty suggestions without calling chat" do
        expect(service.call).to eq(empty_hash)
        expect(llm_client).not_to have_received(:chat)
      end
    end
  end
end
