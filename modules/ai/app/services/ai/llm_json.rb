module Ai
  # Helpers to normalize LLM responses: unwrap the raw response hash and
  # extract clean JSON from content that may include markdown fences or prose.
  module LlmJson
    def content_from(response)
      response.is_a?(Hash) ? response.dig("message", "content") : response
    end

    # Strips markdown code fences and surrounding prose so that a JSON object
    # embedded in the LLM response can be parsed reliably.
    def extract_json(content)
      text = content.to_s.strip
      text = text.gsub(/\A```(?:json)?\s*/i, "").gsub(/```\s*\z/, "")
      start_idx = text.index("{")
      end_idx = text.rindex("}")
      return text if start_idx.nil? || end_idx.nil? || end_idx < start_idx

      text[start_idx..end_idx]
    end
  end
end