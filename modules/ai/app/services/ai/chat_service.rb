# frozen_string_literal: true

module Ai
  class ChatService
    MAX_TOOL_CALL_LOOPS = 8
    MAX_HISTORY_MESSAGES = 16
    MAX_MESSAGE_LENGTH = 4000
    MAX_TOOL_RESULT_LENGTH = 3000

    DESTRUCTIVE_TOOLS = %w[create_work_package update_work_package change_status reassign_work_package].freeze

    def initialize(conversation:, user: User.current)
      @conversation = conversation
      @user = user
      @llm = Ai::LlmClient.new
    end

    def call(stream: true, think: nil, options: nil,
             confirmed_tool_calls: nil) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
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
            when :thinking
              yield({ type: :thinking, content: event[:content] })
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

        destructive_calls, safe_calls = tool_calls.partition do |tc|
          DESTRUCTIVE_TOOLS.include?(tc.dig("function", "name"))
        end

        if confirmed_tool_calls && destructive_calls.any?
          filtered = destructive_calls.select { |tc| confirmed_tool_calls.include?(tc["id"].to_s) }
          safe_calls += filtered
          skipped = destructive_calls.length - filtered.length
          yield({ type: :tool_note, note: "(#{skipped} tool calls skipped — not confirmed by user)" }) if skipped > 0
        elsif destructive_calls.any?
          yield({ type: :need_confirmation, tool_calls: destructive_calls.map { |tc|
            tc["id"] || tc.dig("function", "name")
          } })
          yield({ type: :done, content: "" })
          return
        end

        runnable = safe_calls
        break if runnable.empty?

        yield({ type: :tool_calls_start })

        messages << { role: "assistant", content: @last_response.dig("message", "content") || "", tool_calls: }

        runnable.each do |tc|
          tool_name = tc.dig("function", "name")
          arguments = begin
            JSON.parse(tc.dig("function", "arguments") || "{}")
          rescue StandardError
            {}
          end

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

    TEXT_TOOL_CALL_PATTERN = /
      \{\s*
        (?:
          "function"\s*:\s*\{\s*"name"\s*:\s*"(\w+)"\s*,\s*"arguments"\s*:\s*(\{[^}]*\})
          |
          "name"\s*:\s*"(\w+)"\s*,\s*"arguments"\s*:\s*(\{[^}]*\})
        )
      \s*\}
    /x

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
        You help users manage their projects, tasks, and portfolios. You can take actions on the user's behalf.

        Current user: #{@user.name} (#{@user.mail})
        Current time: #{now.strftime('%Y-%m-%d %H:%M %Z')}

        You have access to tools. When the user asks you to do something, use the appropriate tool.
        You CAN chain multiple tools together — for example, search for work packages, then update or
        comment on the ones you find.

        When you create, update, or reassign a work package, always confirm what you did and
        provide the relevant URL.
        If the user asks about "my tasks" or "my work", use the get_user_tasks tool.

        When presenting results to the user, use plain natural language with markdown formatting
        (bold, italic, lists, tables). Describe structured data in words — do NOT dump raw JSON.
      PROMPT
    end

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
        "change_status" => Ai::Tools::ChangeStatus.new,
        "reassign_work_package" => Ai::Tools::ReassignWorkPackage.new,
        "add_comment" => Ai::Tools::AddComment.new,
        "get_project_info" => Ai::Tools::GetProjectInfo.new,
        "get_user_tasks" => Ai::Tools::GetUserTasks.new,
        "list_projects" => Ai::Tools::ListProjects.new
      }
    end
  end
end