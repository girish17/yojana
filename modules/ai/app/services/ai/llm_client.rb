module Ai
  class LlmClient
    Error = Class.new(StandardError)
    ConnectionError = Class.new(Error)
    ModelNotFoundError = Class.new(Error)

    def initialize(endpoint: nil, model: nil)
      @endpoint = (endpoint || ENV["OLLAMA_HOST"].presence || setting.ollama_endpoint).chomp("/")
      @model = model || setting.default_model
    end

    def chat(messages, tools: nil, stream: nil, think: nil, keep_alive: "-1", options: nil, &block)
      payload = chat_payload(messages, tools:, stream:, think:, keep_alive:, options:)

      if stream && block
        stream_chat(payload, &block)
      else
        response = with_timeout_handling { connection.post("/api/chat", payload.to_json) }
        handle_errors(response)
        response.body.is_a?(Hash) ? response.body : JSON.parse(response.body)
      end
    end

    def embed(text)
      response = with_timeout_handling { connection.post("/api/embed", { model: @model, input: text }.to_json) }
      handle_errors(response)
      body = response.body.is_a?(Hash) ? response.body : JSON.parse(response.body)
      body.fetch("embeddings", [])
    end

    def available?
      cached = self.class.availability_cache[endpoint_key]
      return true if cached && cached > 15.seconds.ago

      reachable = connection.get("/api/tags").success?
      self.class.availability_cache[endpoint_key] = reachable ? Time.zone.now : nil
      reachable
    rescue StandardError
      false
    end

    def self.available?
      new.available?
    end

    def self.availability_cache
      Thread.current[:ai_llm_available] ||= {}
    end

    private

    def stream_chat(payload)
      full_response = { "message" => { "role" => "assistant", "content" => "", "tool_calls" => [] } }
      buffer = +""

      process_line = lambda do |line|
        line = line.sub(/\r$/, "")
        next if line.strip.empty?

        parsed = begin
          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end
        next if parsed.nil?

        msg = parsed["message"] || {}

        if (content = msg["content"])
          full_response["message"]["content"] += content
          yield({ type: :token, content: })
        end

        if (tool_calls = msg["tool_calls"])
          full_response["message"]["tool_calls"] = tool_calls
        end

        if parsed["done"]
          yield({ type: :done, response: full_response })
        end
      end

      with_timeout_handling do
        connection.post("/api/chat", payload.to_json) do |req|
          req.options.on_data = ->(chunk, _bytes, _env) do
            buffer << chunk
            while (newline = buffer.index("\n"))
              line = buffer.slice!(0, newline)
              buffer.slice!(0, 1)
              process_line.call(line)
            end
          end
        end
        process_line.call(buffer) unless buffer.empty?
      end
    end

    def chat_payload(messages, tools:, stream:, think:, keep_alive:, options:)
      payload = {
        model: @model,
        messages:,
        stream: stream ? true : false,
        keep_alive:,
        options: generation_options(options || {})
      }
      payload[:tools] = tools if tools
      payload[:think] = think unless think.nil?
      payload
    end

    def generation_options(overrides)
      options = { num_ctx: 8192 }.merge(overrides.to_h.compact)
      options[:num_predict] = setting.max_tokens if setting.max_tokens
      options[:temperature] = setting.temperature if setting.temperature
      options
    end

    def endpoint_key
      @endpoint
    end

    def connection
      @connection ||= Faraday.new(@endpoint) do |f|
        f.request :json
        f.response :json
        f.adapter Faraday.default_adapter
        f.options.timeout = 300
        f.options.open_timeout = 10
      end
    end

    def handle_errors(response)
      raise ConnectionError, "Ollama returned #{response.status}" unless response.success?
    end

    def with_timeout_handling
      yield
    rescue Faraday::TimeoutError
      raise ConnectionError, "Ollama took too long to respond (300s timeout). The model may still be loading from cold start — try again."
    end

    def setting
      @setting ||= Ai::Setting.instance
    end
  end
end
