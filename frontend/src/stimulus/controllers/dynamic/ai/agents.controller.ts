import { Controller } from "@hotwired/stimulus";

interface Agent {
  id: number;
  name: string;
  prompt: string;
  cron_expression: string;
  active: boolean;
  agent_type: string;
  project_id: number | null;
  created_at: string;
  updated_at: string;
  execution_count?: number;
  last_run_at?: string | null;
  executions?: Execution[];
}

interface Execution {
  id: number;
  status: string;
  result: string | null;
  error_message: string | null;
  started_at: string;
  completed_at: string | null;
}

export default class AgentsController extends Controller {
  static targets = [
    "list", "form", "newButton",
    "agentId", "nameInput", "typeInput", "cronInput", "promptInput", "activeInput",
    "executions", "executionList"
  ];

  declare readonly listTarget: HTMLElement;
  declare readonly formTarget: HTMLElement;
  declare readonly newButtonTarget: HTMLButtonElement;
  declare readonly agentIdTarget: HTMLInputElement;
  declare readonly nameInputTarget: HTMLInputElement;
  declare readonly typeInputTarget: HTMLSelectElement;
  declare readonly cronInputTarget: HTMLInputElement;
  declare readonly promptInputTarget: HTMLTextAreaElement;
  declare readonly activeInputTarget: HTMLInputElement;
  declare readonly executionsTarget: HTMLElement;
  declare readonly executionListTarget: HTMLElement;

  connect() {
    this.fetchAgents();
  }

  async fetchAgents() {
    try {
      const res = await fetch("/ai/agents", {
        headers: { Accept: "application/json" }
      });
      const agents: Agent[] = await res.json();
      this.renderList(agents);
    } catch (e) {
      console.error("Failed to fetch agents:", e);
    }
  }

  renderList(agents: Agent[]) {
    if (agents.length === 0) {
      this.listTarget.innerHTML = `<p class="ai-agents-empty">No AI agents configured yet.</p>`;
      return;
    }

    this.listTarget.innerHTML = agents.map(a => `
      <div class="ai-agent-card ${a.active ? "active" : ""}"
           data-action="click->ai--agents#showExecutions"
           data-agent-id="${a.id}">
        <div>
          <div class="ai-agent-name">${this.escape(a.name)}</div>
          <div class="ai-agent-meta">
            ${this.escape(a.agent_type)} &middot; ${a.cron_expression || "manual"}
            ${a.last_run_at ? `&middot; Last run: ${new Date(a.last_run_at).toLocaleString()}` : ""}
          </div>
        </div>
        <div style="display:flex;align-items:center;gap:8px">
          <span class="ai-agent-status ${a.active ? "active" : "inactive"}">
            ${a.active ? "Active" : "Inactive"}
          </span>
          <button class="Button Button--small" data-action="click->ai--agents#edit" data-agent-id="${a.id}">
            Edit
          </button>
          <button class="Button Button--small Button--danger" data-action="click->ai--agents#delete" data-agent-id="${a.id}">
            Delete
          </button>
        </div>
      </div>
    `).join("");
  }

  async showExecutions(e: Event) {
    const card = (e.currentTarget as HTMLElement).closest(".ai-agent-card") as HTMLElement;
    const agentId = card.dataset.agentId;
    if (!agentId) return;
    this.executionsTarget.hidden = false;

    try {
      const res = await fetch(`/ai/agents/${agentId}/executions`, {
        headers: { Accept: "application/json" }
      });
      const data: { executions: Execution[] } = await res.json();
      const execs = data.executions || [];
      if (execs.length === 0) {
        this.executionListTarget.innerHTML = `<p>No executions yet.</p>`;
      } else {
        this.executionListTarget.innerHTML = execs.map(e => `
          <div class="ai-execution-item">
            <span class="ai-execution-status ${e.status}">${e.status}</span>
            <span>${new Date(e.started_at).toLocaleString()}</span>
            ${e.result ? `<span>${this.escape(e.result.substring(0, 200))}</span>` : ""}
            ${e.error_message ? `<span style="color:var(--fgColor-danger,#cf222e)">${this.escape(e.error_message)}</span>` : ""}
          </div>
        `).join("");
      }
    } catch {
      this.executionListTarget.innerHTML = "<p>Failed to load executions</p>";
    }
  }

  async getCsrfToken(): Promise<string> {
    const res = await fetch("/");
    const html = await res.text();
    const match = html.match(/<meta name="csrf-token" content="([^"]+)"/);
    return match ? match[1] : "";
  }

  showForm() {
    this.formTarget.hidden = false;
    this.agentIdTarget.value = "";
    this.nameInputTarget.value = "";
    this.typeInputTarget.value = "custom";
    this.cronInputTarget.value = "";
    this.promptInputTarget.value = "";
    this.activeInputTarget.checked = true;
    this.newButtonTarget.hidden = true;
  }

  cancelForm() {
    this.formTarget.hidden = true;
    this.newButtonTarget.hidden = false;
  }

  async edit(e: Event) {
    e.stopPropagation();
    const btn = e.currentTarget as HTMLElement;
    const agentId = btn.dataset.agentId;
    if (!agentId) return;

    try {
      const res = await fetch(`/ai/agents/${agentId}`, {
        headers: { Accept: "application/json" }
      });
      const agent: Agent = await res.json();
      this.agentIdTarget.value = String(agent.id);
      this.nameInputTarget.value = agent.name;
      this.typeInputTarget.value = agent.agent_type;
      this.cronInputTarget.value = agent.cron_expression || "";
      this.promptInputTarget.value = agent.prompt;
      this.activeInputTarget.checked = agent.active;
      this.formTarget.hidden = false;
      this.newButtonTarget.hidden = true;
    } catch (e) {
      console.error("Failed to fetch agent:", e);
    }
  }

  async delete(e: Event) {
    e.stopPropagation();
    const btn = e.currentTarget as HTMLElement;
    const agentId = btn.dataset.agentId;
    if (!agentId || !confirm("Delete this agent?")) return;

    const csrf = await this.getCsrfToken();

    try {
      const res = await fetch(`/ai/agents/${agentId}`, {
        method: "DELETE",
        headers: {
          "X-CSRF-Token": csrf,
          "Accept": "application/json"
        }
      });
      if (res.ok) {
        this.fetchAgents();
        this.executionsTarget.hidden = true;
      }
    } catch (e) {
      console.error("Failed to delete agent:", e);
    }
  }

  async save() {
    const agentId = this.agentIdTarget.value;
    const method = agentId ? "PUT" : "POST";
    const url = agentId ? `/ai/agents/${agentId}` : "/ai/agents";
    const csrf = await this.getCsrfToken();

    const body = {
      name: this.nameInputTarget.value,
      agent_type: this.typeInputTarget.value,
      cron_expression: this.cronInputTarget.value,
      prompt: this.promptInputTarget.value,
      active: this.activeInputTarget.checked
    };

    try {
      const res = await fetch(url, {
        method,
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrf,
          "Accept": "application/json"
        },
        body: JSON.stringify(body)
      });

      if (res.ok) {
        this.cancelForm();
        this.fetchAgents();
      } else {
        const err = await res.json();
        alert("Error: " + JSON.stringify(err.errors || err));
      }
    } catch (e) {
      console.error("Failed to save agent:", e);
    }
  }

  private escape(s: string): string {
    const d = document.createElement("div");
    d.textContent = s;
    return d.innerHTML;
  }
}
