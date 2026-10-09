module Ai::Tools
  class ReassignWorkPackage < Base
    def tool_spec
      {
        type: "function",
        function: {
          name: "reassign_work_package",
          description: "Reassign a work package to a different user. Accepts assignee by name, email, 'me', or numeric ID.",
          parameters: {
            type: "object",
            properties: {
              id: {
                type: "integer",
                description: "ID of the work package to reassign"
              },
              assignee: {
                type: "string",
                description: "Name, email, 'me' (for yourself), or numeric user ID of the new assignee"
              }
            },
            required: ["id", "assignee"]
          }
        }
      }
    end

    def execute(params)
      wp = WorkPackage.visible.find(params[:id])

      unless User.current.allowed_in_project?(:edit_work_packages, wp.project)
        return { error: "You don't have permission to reassign work packages in project '#{wp.project.name}'" }
      end

      user = resolve_user(params[:assignee])
      return { error: "User '#{params[:assignee]}' not found or not a member of this project" } unless user

      if wp.update(assigned_to_id: user.id)
        { id: wp.id, subject: wp.subject, assigned_to: user.name, url: "/work_packages/#{wp.id}" }
      else
        { error: wp.errors.full_messages.join(", ") }
      end
    rescue ActiveRecord::RecordNotFound
      { error: "Work package not found" }
    end

    private

    def resolve_user(str)
      return User.current if str.downcase.strip == "me"

      if str.match?(/\A\d+\z/)
        User.active.find_by(id: str.to_i)
      else
        User.active.find_by("LOWER(login) = :s OR LOWER(firstname) = :s OR LOWER(lastname) = :s OR LOWER(mail) = :s",
                            s: str.downcase.strip).tap do |_u|
          break _u
        end
      end
    end
  end
end