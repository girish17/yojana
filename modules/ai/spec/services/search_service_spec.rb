# frozen_string_literal: true

require "billy"
require "spec_helper"

RSpec.describe Ai::SearchService do
  let(:user) { create(:user) }
  let(:project) { create(:project) }
  let(:role) { create(:project_role, permissions: [:view_work_packages]) }
  let!(:work_package) { create(:work_package, project:, subject: "Open tasks sprint planning") }
  let(:llm_client) { instance_double(Ai::LlmClient) }

  subject(:service) { described_class.new("open tasks", user:, project:) }

  before do
    create(:member, user:, project:, roles: [role])
    allow(Ai::LlmClient).to receive(:new).and_return(llm_client)
    allow(llm_client).to receive(:available?).and_return(true)
    User.current = user
  end

  after { User.current = nil }

  describe "#call" do
    context "when the LLM parses the query into JSON inside message content" do
      let(:parsed_query) do
        { q: "open tasks", scope: "work_packages", status: "open", assignee: nil }.to_json
      end

      before do
        allow(llm_client).to receive(:chat).and_return(
          { "message" => { "role" => "assistant", "content" => parsed_query } },
          { "message" => { "role" => "assistant", "content" => "Found 1 open work package." } }
        )
      end

      it "runs a scoped search and summarizes the results" do
        result = service.call
        expect(result[:scope]).to eq("work_packages")
        expect(result[:count]).to eq(1)
        expect(result[:results].first[:id]).to eq(work_package.id)
        expect(result[:summary]).to include("Found 1 open work package.")
      end
    end

    context "when the LLM requests a type with no matching Type record" do
      before do
        allow(llm_client).to receive(:chat).and_return(
          { "message" => { "role" => "assistant", "content" => { q: "open tasks", scope: "work_packages", type: "feature" }.to_json } },
          { "message" => { "role" => "assistant", "content" => "Summary" } }
        )
      end

      it "ignores the unmatched type filter and still returns results" do
        result = service.call
        expect(result[:count]).to eq(1)
        expect(result[:results].first[:id]).to eq(work_package.id)
      end
    end

    context "when strict AND token matching returns nothing" do
      let!(:loose_match) do
        create(:work_package, project:, subject: "Deploy sprint board to production")
      end

      before do
        allow(llm_client).to receive(:chat).and_return(
          { "message" => { "role" => "assistant", "content" => { q: "deploy sprint review", scope: "work_packages" }.to_json } },
          { "message" => { "role" => "assistant", "content" => "Summary" } }
        )
      end

      it "relaxes to OR matching and surfaces partial matches" do
        result = service.call
        expect(result[:results].map { |r| r[:id] }).to include(loose_match.id)
      end
    end

    context "when the LLM wraps the JSON in markdown fences" do
      before do
        allow(llm_client).to receive(:chat).and_return(
          "Here:\n```json\n{\"q\": \"open\", \"scope\": \"work_packages\"}\n```",
          { "message" => { "role" => "assistant", "content" => "Summary" } }
        )
      end

      it "extracts and parses the fenced JSON" do
        result = service.call
        expect(result[:results]).not_to be_empty
      end
    end

    context "when the LLM response is not parseable JSON" do
      before do
        allow(llm_client).to receive(:chat).and_return("I could not parse that.")
      end

      it "falls back to a plain tokenized search" do
        result = service.call
        expect(result[:q]).to eq("open tasks")
        expect(result[:filters]).to eq({})
        expect(result[:count]).to eq(1)
      end
    end
  end

  describe "#call without an available LLM" do
    before do
      allow(llm_client).to receive(:available?).and_return(false)
    end

    it "still searches using tokenized phrase matching" do
      result = service.call
      expect(result[:scope]).to eq("all")
      expect(result[:count]).to eq(1)
    end
  end
end
