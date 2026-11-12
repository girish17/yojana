# frozen_string_literal: true

#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

# Use rack-timeout if we run in clustered mode with at least 2 workers
# so that workers, should a timeout occur, can be restarted without interruption.
if OpenProject::Configuration.web_workers >= 2
  service_timeout = OpenProject::Configuration.web_timeout
  wait_timeout = OpenProject::Configuration.web_wait_timeout
  term_on_timeout = OpenProject::Configuration.term_on_timeout

  Rails.logger.debug { "Enabling Rack::Timeout (service=#{service_timeout}s wait=#{wait_timeout}s)" }

  Rails.application.config.middleware.insert_before(
    Rack::Runtime,
    Rack::Timeout,
    service_timeout:, # time after which a request being served times out
    wait_timeout:, # time after which a request waiting to be served times out
    term_on_timeout:, # shut down worker (gracefully) right away on timeout to be restarted
    service_past_wait: true # Treat the service timeout as independent from the wait timeout
  )

  # Allow longer-running SSE chat streams while keeping the global timeout for
  # the rest of the application.
  module OpenProject::AiChatRackTimeoutOverride
    THREAD_KEY = :op_ai_chat_rack_timeout_service_timeout_override
    CHAT_SSE_TIMEOUT = 600
    CHAT_SSE_PATH = %r{\A/ai/conversations/\d+/messages(?:/confirm)?\z}

    def call(env)
      previous = Thread.current[THREAD_KEY]
      Thread.current[THREAD_KEY] = CHAT_SSE_TIMEOUT if ai_chat_sse_request?(env)
      super
    ensure
      Thread.current[THREAD_KEY] = previous
    end

    def service_timeout
      Thread.current[THREAD_KEY] || super
    end

    private

    def ai_chat_sse_request?(env)
      path = env["PATH_INFO"].to_s
      return false unless path.match?(CHAT_SSE_PATH)

      accept = env["HTTP_ACCEPT"].to_s
      accept.include?("text/event-stream") || path.end_with?("/confirm")
    end
  end

  unless Rack::Timeout < OpenProject::AiChatRackTimeoutOverride
    Rack::Timeout.prepend(OpenProject::AiChatRackTimeoutOverride)
  end

  Rails.application.config.after_initialize do
    # remove default logger (logging uninteresting extra info with each not timed out request)
    Rack::Timeout.unregister_state_change_observer(:logger)

    Rack::Timeout.register_state_change_observer(:wait_timeout_logger) do |env|
      details = env[Rack::Timeout::ENV_INFO_KEY]

      if details.state == :timed_out && details.wait.present?
        OpenProject.logger.error "Request timed out waiting to be served!"
      end
    end

    # The timeout itself is already reported so no need to
    # report the generic internal server error too as it doesn't
    # add any more information. Even worse, it's not immediately
    # clear that the two reports are related.
    require "rack/timeout/suppress_internal_error_report_on_timeout"

    OpenProjectErrorHelper.prepend Rack::Timeout::SuppressInternalErrorReportOnTimeout
  end
else
  Rails.logger.debug { "Not enabling Rack::Timeout since we are not running in cluster mode with at least 2 workers" }
end
