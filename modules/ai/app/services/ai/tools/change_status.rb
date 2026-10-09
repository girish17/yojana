module Ai::Tools
  class ChangeStatus < Base
    def tool_spec
      {
        type: "function",
        function: {
          name: "change_status",
          description: "Change the status of a work package. Accepts status by name (e.g., 'In Progress', 'Closed') or numeric ID.",
          parameters: {
            type: "object",
            properties: {
              id: {
                type: "integer",
                description: "ID of the work package to update"
              },
              status: {
                type: "string",
                description: "New status name (case-insensitive) or numeric status ID"
              }
            },
            required: ["id", "status"]
          }
        }
      }
    end

    def execute(params)
      wp = WorkPackage.visible.find(params[:id])

      unless User.current.allowed_in_project?(:edit_work_packages, wp.project)
        return { error: "You don't have permission to change the status of work packages in project '#{wp.project.name}'" }
      end

      new_status = resolve_status(params[:status])
      return { error: "Status '#{params[:status]}' not found" } unless new_status

      to_name = new_status.name

      if wp.update(status_id: new_status.id)
        { id: wp.id, subject: wp.subject, status: to_name, previous_status: wp.status.name_previously_was, url: "/work_packages/#{wp.id}" }
      else
        { error: wp.errors.full_messages.join(", ") }
      end
    rescue ActiveRecord::RecordNotFound
      { error: "Work package not found" }
    end

    private

    def resolve_status(str)
      if str.match?(/\A\d+\z/)
        Status.find_by(id: str.to_i)
      else
        Status.find_by("LOWER(name) = ?", str.downcase)
      end
    end
  end
end