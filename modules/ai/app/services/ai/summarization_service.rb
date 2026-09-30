# frozen_string_literal: true

module Ai
  class SummarizationService
    def initialize(text, max_sentences: 2)
      @text = text
      @max_sentences = max_sentences
    end

    def call
      return nil if @text.blank?
      return nil unless llm_available?

      prompt = <<~PROMPT
        Summarize the following text in #{@max_sentences} sentences or fewer.
        Be concise and capture the key points only.
        Respond with ONLY the summary text, no extra formatting.

        Text:
        #{@text.truncate(4000)}
      PROMPT

      response = llm.chat([{ role: "user", content: prompt }])
      response.is_a?(Hash) ? response.dig("message", "content") : response
    rescue Ai::LlmClient::Error
      nil
    end

    private

    def llm
      @llm ||= Ai::LlmClient.new
    end

    def llm_available?
      Ai::LlmClient.available?
    end
  end
end
