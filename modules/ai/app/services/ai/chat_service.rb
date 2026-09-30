module Ai
  class ChatService
    MAX_TOOL_CALL_LOOPS = 3
    MAX_HISTORY_MESSAGES = 16
    MAX_MESSAGE_LENGTH = 4000
    MAX_TOOL_RESULT_LENGTH = 3000

    def initialize(conversation:, user: User.current)
      @conversation = conversation
      @user = user
      @llm = Ai::LlmClient.new
    end

    def call(stream: true, think: false, options: nil) # rubocop:disable Metrics/AbcSize,Metrics/PerceivedComplexity
      messages = build_messages
      tools = tool_definitions
      tool_objects = tool_registry

      loop_count = 0

      begin
        if stream
          @llm.chat(messages, tools:, stream: true, think:, options:) do |event|
            case event[:type]
            when :token
              yield({ type: :token, content: event[:content] })
            when :done
              @last_response = event[:response]
            end
          end
        else
          @last_response = @llm.chat(messages, tools:, stream: false, think:, options:)
        end

        tool_calls = @last_response&.dig("message", "tool_calls")

        if tool_calls.blank?
          text_calls = detect_text_tool_calls(@last_response&.dig("message", "content") || "")
          if text_calls.present?
            tool_calls = text_calls
            @last_response["message"]["tool_calls"] = tool_calls
          end
        end

        break if tool_calls.blank? || loop_count >= MAX_TOOL_CALL_LOOPS

        yield({ type: :tool_calls_start })

        messages << { role: "assistant", content: @last_response.dig("message", "content") || "", tool_calls: }

        tool_calls.each do |tc|
          tool_name = tc.dig("function", "name")
          arguments = JSON.parse(tc.dig("function", "arguments") || "{}") rescue {}

          yield({ type: :tool_call, name: tool_name, arguments: })

          tool_class = tool_objects[tool_name]
          if tool_class
            result = tool_class.execute(arguments.with_indifferent_access)
            result_content = truncate_tool_result(result)
            yield({ type: :tool_result, name: tool_name, result: })
            messages << { role: "tool", content: result_content, tool_call_id: tc["id"] }
          end
        end

        yield({ type: :tool_calls_end })
        loop_count += 1
      end while tool_calls.present? && loop_count < MAX_TOOL_CALL_LOOPS

      final_content = @last_response&.dig("message", "content") || ""

      @conversation.messages.create!(role: :assistant, content: final_content)

      yield({ type: :done, content: final_content })
    rescue Ai::LlmClient::Error => e
      yield({ type: :error, message: "AI service error: #{e.message}" })
    rescue StandardError => e
      yield({ type: :error, message: "An unexpected error occurred: #{e.message}" })
    end

    private

    def build_messages
      system_prompt = build_system_prompt
      history = @conversation.messages.last(MAX_HISTORY_MESSAGES).map do |msg|
        { role: msg.role, content: (msg.content || "").truncate(MAX_MESSAGE_LENGTH) }
      end
      [{ role: "system", content: system_prompt }] + history
    end

    def truncate_tool_result(result)
      json = result.to_json
      json.length > MAX_TOOL_RESULT_LENGTH ? json.truncate(MAX_TOOL_RESULT_LENGTH) : json
    end

    def build_system_prompt
      now = Time.zone.now

      <<~PROMPT
        You are Yojana AI, an intelligent assistant for Yojana — an open-source project management platform.
        You help users manage their projects, tasks, and portfolios.

        Current user: #{@user.name} (#{@user.mail})
        Current time: #{now.strftime("%Y-%m-%d %H:%M %Z")}

        You have access to tools. When the user asks you to do something, use the appropriate tool.
        Always confirm what you've done and provide relevant URLs when creating or finding items.
        If the user asks about "my tasks" or "my work", use the get_user_tasks tool.

        IMPORTANT: You must NEVER output raw JSON, function call syntax, or tool call definitions
        as text in your response. For example, do NOT write things like:
          {"function": {"name": "search_work_packages", ...}}
        or
          Here's the result: {"id": 123, "subject": "..."}
        Always respond in plain natural language, using markdown for formatting (bold, italic, lists, etc).
        If you need to share structured data, describe it in words or use a markdown table.
      PROMPT
    end

    TEXT_TOOL_CALL_PATTERN = /
      \{\s*
        (?:
          "function"\s*:\s*\{\s*"name"\s*:\s*"(\w+)"\s*,\s*"arguments"\s*:\s*(\{[^}]*\})
          |
          "name"\s*:\s*"(\w+)"\s*,\s*"arguments"\s*:\s*(\{[^}]*\})
        )
      \s*\}
    /x

    def detect_text_tool_calls(content)
      calls = []
      content.scan(TEXT_TOOL_CALL_PATTERN) do |match|
        tool_name = match[0] || match[2]
        args_str = match[1] || match[3]
        next unless tool_name && args_str

        begin
          args = JSON.parse(args_str)
          calls << {
            "id" => "text-#{SecureRandom.hex(8)}",
            "function" => {
              "name" => tool_name,
              "arguments" => args.is_a?(Hash) ? args.to_json : "{}"
            }
          }
        rescue JSON::ParserError
          next
        end
      end
      calls
    end

    def tool_definitions
      tool_registry.values.map(&:tool_spec)
    end

    def tool_registry
      @tool_registry ||= {
        "search_work_packages" => Ai::Tools::SearchWorkPackages.new,
        "create_work_package" => Ai::Tools::CreateWorkPackage.new,
        "update_work_package" => Ai::Tools::UpdateWorkPackage.new,
        "get_project_info" => Ai::Tools::GetProjectInfo.new,
        "get_user_tasks" => Ai::Tools::GetUserTasks.new,
        "list_projects" => Ai::Tools::ListProjects.new
      }
    end
  end
end
