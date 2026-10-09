# frozen_string_literal: true

module Ai
  class MessagesController < ApplicationController
    no_authorization_required! :index, :create, :confirm
    before_action :require_login
    before_action :require_ai_chat
    before_action :find_conversation
    before_action :extend_timeout_for_sse, only: %i[create confirm]

    def index
      messages = @conversation.messages.where.not(role: :tool)
      render json: messages.map { |m| serialize_message(m) }
    end

    def create
      content = params[:content].to_s.strip
      return head :unprocessable_entity if content.blank?

      @conversation.messages.create!(role: :user, content:)

      return stream_response if sse_request?

      render json: { status: "created", conversation_id: @conversation.id }, status: :created
    end

    def confirm
      confirmed = Array(params[:confirmed_tool_call_ids]) & params[:confirmed_tool_call_ids].to_s.strip.split(",")
      return head :unprocessable_entity if confirmed.empty?

      stream_response(confirmed_tool_calls: confirmed)
    end

    private

    def find_conversation
      @conversation = Ai::Conversation.for_user(User.current).find(params[:conversation_id])
    end

    def sse_request?
      request.headers["Accept"]&.include?("text/event-stream") || request.format.sse?
    end

    def extend_timeout_for_sse
      return unless sse_request? || action_name == "confirm"

      info = env[Rack::Timeout::ENV_INFO_KEY]
      info.service_timeout = 600 if info
    end

    def stream_response(confirmed_tool_calls: nil)
      response.headers["Content-Type"] = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      response.headers["X-Accel-Buffering"] = "no"

      stream_sse(:connected)

      Ai::ChatService.new(conversation: @conversation, user: User.current).call(
        stream: true, confirmed_tool_calls:
      ) do |event|
        case event[:type]
        when :token
          stream_sse(:token, token: event[:content])
        when :thinking
          stream_sse(:thinking, token: event[:content])
        when :tool_note
          stream_sse(:tool_note, note: event[:note])
        when :need_confirmation
          stream_sse(:need_confirmation, tool_call_ids: event[:tool_calls])
        when :done
          stream_sse(:done, content: event[:content])
        when :error
          stream_sse(:error, message: event[:message])
        when :tool_calls_start
          stream_sse(:tool_calls_start)
        when :tool_call
          stream_sse(:tool_call, name: event[:name], arguments: event[:arguments])
        when :tool_result
          stream_sse(:tool_result, name: event[:name])
        when :tool_calls_end
          stream_sse(:tool_calls_end)
        end
      end

      stream_sse(:completed)
    rescue IOError
      # Client disconnected — clean up gracefully
    rescue StandardError => e
      Rails.logger.error("AI chat stream error: #{e.message}")
      Rails.logger.error(e.backtrace&.join("\n"))
      begin
        stream_sse(:error, message: I18n.t("ai.chat_error"))
      rescue IOError
        # Client disconnected while sending the error event
      end
    ensure
      response.stream.close
    end

    def stream_sse(event, data = {})
      response.stream.write("event: #{event}\ndata: #{data.to_json}\n\n")
    end

    def serialize_message(m)
      { id: m.id, role: m.role, content: m.content, created_at: m.created_at }
    end

    def require_ai_chat
      return true if OpenProject::FeatureDecisions.ai_chat_assistant_active?

      render json: { error: I18n.t("ai.feature_unavailable") }, status: :forbidden
      false
    end
  end
end