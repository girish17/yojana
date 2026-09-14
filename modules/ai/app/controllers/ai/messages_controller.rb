# frozen_string_literal: true

module Ai
  class MessagesController < ApplicationController
    no_authorization_required! :index, :create
    before_action :require_login
    before_action :require_ai_chat
    before_action :find_conversation

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

    private

    def find_conversation
      @conversation = Ai::Conversation.for_user(User.current).find(params[:conversation_id])
    end

    def sse_request?
      request.headers["Accept"]&.include?("text/event-stream") || request.format.sse?
    end

    def stream_response
      response.headers["Content-Type"] = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      response.headers["X-Accel-Buffering"] = "no"

      stream_sse(:connected)

      Ai::ChatService.new(conversation: @conversation, user: User.current).call(stream: true) do |event|
        case event[:type]
        when :token
          stream_sse(:token, token: event[:content])
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
