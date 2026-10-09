module Ai::Tools
  class AddComment < Base
    def tool_spec
      {
        type: "function",
        function: {
          name: "add_comment",
          description: "Add a comment (journal note) to a work package.",
          parameters: {
            type: "object",
            properties: {
              id: {
                type: "integer",
                description: "ID of the work package to comment on"
              },
              comment: {
                type: "string",
                description: "The comment text to add"
              }
            },
            required: ["id", "comment"]
          }
        }
      }
    end

    def execute(params)
      wp = WorkPackage.visible.find(params[:id])

      unless User.current.allowed_in_project?(:add_work_package_notes, wp.project)
        return { error: "You don't have permission to comment on work packages in project '#{wp.project.name}'" }
      end

      wp.journal_notes = params[:comment]

      if wp.save
        { id: wp.id, subject: wp.subject, comment_added: true, url: "/work_packages/#{wp.id}" }
      else
        { error: wp.errors.full_messages.join(", ") }
      end
    rescue ActiveRecord::RecordNotFound
      { error: "Work package not found" }
    end
  end
end