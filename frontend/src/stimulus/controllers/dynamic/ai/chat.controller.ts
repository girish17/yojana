import { Controller } from "@hotwired/stimulus"

export default class AiChatController extends Controller<HTMLElement> {
  static targets = ["messages", "input", "sendButton", "conversationsList", "loadingIndicator"]
  static values = {
    hidden: { type: Boolean, default: true },
    conversationId: { type: String, default: "" },
    streaming: { type: Boolean, default: false }
  }

  declare readonly messagesTarget: HTMLElement
  declare readonly inputTarget: HTMLTextAreaElement
  declare readonly sendButtonTarget: HTMLButtonElement
  declare readonly conversationsListTarget: HTMLElement
  declare readonly loadingIndicatorTarget: HTMLElement
  declare hiddenValue: boolean
  declare conversationIdValue: string
  declare streamingValue: boolean

  private currentMessageEl: HTMLElement | null = null
  private abortController: AbortController | null = null
  private toolIndicatorEl: HTMLElement | null = null
  private thinkingEl: HTMLElement | null = null
  private confirmBarEl: HTMLElement | null = null
  private pendingConfirmation: string[] | null = null
  private pendingConversations: boolean = false
  private scrollRafId: number | null = null

  connect(): void {
    window.addEventListener("ai:chat:toggle", this.handleToggle)
    document.addEventListener("keydown", this.handleEscape)
  }

  disconnect(): void {
    window.removeEventListener("ai:chat:toggle", this.handleToggle)
    document.removeEventListener("keydown", this.handleEscape)
  }

  toggle(): void {
    this.hiddenValue = !this.hiddenValue
    if (this.hiddenValue) {
      this.abortStream()
    } else {
      this.loadConversations()
      setTimeout(() => this.inputTarget.focus(), 300)
    }
  }

  private handleToggle = (): void => {
    this.toggle()
  }

  onKeydown(event: KeyboardEvent): void {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault()
      this.send()
    }
  }

  async send(): Promise<void> {
    if (this.streamingValue) return
    const content = this.inputTarget.value.trim()
    if (!content) return

    this.inputTarget.value = ""
    this.addUserMessage(content)
    this.setLoading(true)

    this.streamingValue = true
    this.abortController = new AbortController()

    try {
      if (!this.conversationIdValue) {
        this.clearWelcome()
        const conv = await this.createConversation(content)
        this.conversationIdValue = conv.id
      }

      this.currentMessageEl = this.addAssistantMessage("")
      this.thinkingEl = null

      const resp = await fetch(`/ai/conversations/${this.conversationIdValue}/messages`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "text/event-stream",
          "X-CSRF-Token": this.getCsrfToken()
        },
        body: JSON.stringify({ content }),
        signal: this.abortController.signal
      })

      if (!resp.ok) {
        const text = await resp.text().catch(() => "Request failed")
        this.setMessageContent(this.currentMessageEl, `Error: ${text}`)
        return
      }

      await this.readStream(resp)
    } catch (err: unknown) {
      if (err instanceof Error && err.name !== "AbortError") {
        const el = this.currentMessageEl || this.messagesTarget
        this.setMessageContent(el, `Error: ${err.message}`)
      }
    } finally {
      this.setLoading(false)
      this.streamingValue = false
      this.currentMessageEl = null
      this.abortController = null
      if (!this.pendingConversations) {
        this.loadConversations()
      }
    }
  }

  async newConversation(): Promise<void> {
    this.abortStream()
    this.conversationIdValue = ""
    this.messagesTarget.innerHTML = `<div class="ai-chat-welcome">${this.welcomeText()}</div>`
  }

  selectConversation(event: Event): void {
    const target = (event.currentTarget as HTMLElement)
    const id = target.dataset.conversationId
    if (!id) return

    this.abortStream()
    this.conversationIdValue = id
    this.loadMessages(id)
    this.highlightConversation(id)
  }

  async deleteConversation(event: Event): Promise<void> {
    event.stopPropagation()
    const target = (event.currentTarget as HTMLElement)
    const id = target.dataset.conversationId
    if (!id) return

    try {
      const resp = await fetch(`/ai/conversations/${id}`, {
        method: "DELETE",
        headers: { "X-CSRF-Token": this.getCsrfToken() }
      })
      if (resp.ok) {
        if (this.conversationIdValue === id) {
          this.newConversation()
        }
        this.loadConversations()
      }
    } catch {
      // silently fail
    }
  }

  private async readStream(resp: Response): Promise<void> {
    const reader = resp.body!.getReader()
    const decoder = new TextDecoder()
    let buffer = ""

    while (true) {
      const { done, value } = await reader.read()
      if (done) break

      buffer += decoder.decode(value, { stream: true })

      const parts = buffer.split("\n\n")
      buffer = parts.pop() || ""

      for (const part of parts) {
        if (!part.trim()) continue
        this.processSSEEvent(part)
      }
    }

    if (buffer.trim()) {
      this.processSSEEvent(buffer)
    }
  }

  private processSSEEvent(part: string): void {
    const lines = part.split("\n")
    let eventType = ""
    let dataStr = ""

    for (const line of lines) {
      if (line.startsWith("event: ")) {
        eventType = line.slice(7)
      } else if (line.startsWith("data: ")) {
        dataStr = line.slice(6)
      }
    }

    if (!dataStr) return

    let data: Record<string, unknown>
    try {
      data = JSON.parse(dataStr)
    } catch {
      return
    }

    switch (eventType) {
      case "token":
        if (this.currentMessageEl) {
          this.appendMessageContent(this.currentMessageEl, data.token as string || "")
        }
        break
      case "thinking":
        this.showThinking(data.token as string || "")
        break
      case "need_confirmation":
        this.showConfirmationBar(data.tool_call_ids as string[])
        break
      case "tool_calls_start":
        this.showToolIndicator("Using tools...")
        break
      case "tool_call":
        this.showToolIndicator(this.toolLabel(data.name as string))
        break
      case "tool_result":
        break
      case "tool_calls_end":
        this.hideToolIndicator()
        break
      case "done":
        if (this.currentMessageEl && data.content) {
          this.setMessageContent(this.currentMessageEl, data.content as string)
        }
        break
      case "error":
        this.hideToolIndicator()
        const el = this.currentMessageEl || this.messagesTarget
        this.setMessageContent(el, `Error: ${data.message || "Unknown error"}`)
        break
      case "connected":
      case "completed":
        break
    }
  }

  private async createConversation(title: string): Promise<{ id: string }> {
    const resp = await fetch("/ai/conversations", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": this.getCsrfToken()
      },
      body: JSON.stringify({ title: title.slice(0, 50) })
    })
    return resp.json()
  }

  private async loadConversations(): Promise<void> {
    this.pendingConversations = true
    try {
      const resp = await fetch("/ai/conversations", {
        headers: { "Accept": "application/json" }
      })
      if (!resp.ok) return
      const conversations: Array<{ id: string; title: string; message_count: number }> = await resp.json()

      if (conversations.length === 0) {
        this.conversationsListTarget.hidden = true
        return
      }

      this.conversationsListTarget.hidden = false
      this.conversationsListTarget.innerHTML = conversations.map(c => `
        <div class="ai-chat-conversation-item${this.conversationIdValue === c.id ? " active" : ""}"
             data-conversation-id="${c.id}"
             data-action="click->ai--chat#selectConversation">
          <span class="ai-chat-conversation-title">${this.escapeHtml(c.title)}</span>
          <span class="ai-chat-conversation-meta">${c.message_count}</span>
          <button class="ai-chat-conversation-delete"
                  data-conversation-id="${c.id}"
                  data-action="click->ai--chat#deleteConversation"
                  title="Delete">×</button>
        </div>
      `).join("")
    } finally {
      this.pendingConversations = false
    }
  }

  private async loadMessages(conversationId: string): Promise<void> {
    try {
      const resp = await fetch(`/ai/conversations/${conversationId}`, {
        headers: { "Accept": "application/json" }
      })
      if (!resp.ok) return
      const data = await resp.json()

      this.messagesTarget.innerHTML = ""
      for (const msg of data.messages || []) {
        if (msg.role === "user") {
          this.addUserMessage(msg.content)
        } else if (msg.role === "assistant" && msg.content) {
          this.addAssistantMessage(msg.content)
        }
      }
      this.scrollToBottom()
    } catch {
      this.messagesTarget.innerHTML = `<div class="ai-chat-welcome">Failed to load messages</div>`
    }
  }

  private addUserMessage(content: string): HTMLElement {
    const div = document.createElement("div")
    div.className = "ai-message user"
    div.innerHTML = `
      <div class="ai-message-avatar">U</div>
      <div class="ai-message-bubble">${this.escapeHtml(content)}</div>
    `
    this.messagesTarget.appendChild(div)
    this.scrollToBottom()
    return div
  }

  private addAssistantMessage(content: string): HTMLElement {
    const div = document.createElement("div")
    div.className = "ai-message assistant"
    div.innerHTML = `
      <div class="ai-message-avatar">AI</div>
      <div class="ai-message-bubble">${this.markdownToHtml(content)}</div>
    `
    this.messagesTarget.appendChild(div)
    return div
  }

  private appendMessageContent(el: HTMLElement, token: string): void {
    const bubble = el.querySelector(".ai-message-bubble")
    if (bubble) {
      bubble.textContent += token
      this.requestScrollToBottom()
    }
  }

  private requestScrollToBottom(): void {
    if (this.scrollRafId !== null) return
    this.scrollRafId = requestAnimationFrame(() => {
      this.scrollRafId = null
      this.scrollToBottom()
    })
  }

  private setMessageContent(el: HTMLElement, content: string): void {
    if (el.classList.contains("ai-message")) {
      const bubble = el.querySelector(".ai-message-bubble")
      if (bubble) {
        bubble.innerHTML = this.markdownToHtml(content)
      } else {
        el.textContent = content
      }
    } else {
      el.innerHTML = `<div class="ai-message assistant"><div class="ai-message-avatar">AI</div><div class="ai-message-bubble">${this.markdownToHtml(content)}</div></div>`
    }
    this.scrollToBottom()
  }

  private showToolIndicator(text: string): void {
    this.hideToolIndicator()
    this.toolIndicatorEl = document.createElement("div")
    this.toolIndicatorEl.className = "ai-message-tool-calls ai-tool-call"
    this.toolIndicatorEl.innerHTML = `<span class="ai-chat-spinner" style="width:12px;height:12px;"></span> ${this.escapeHtml(text)}`
    this.messagesTarget.appendChild(this.toolIndicatorEl)
    this.scrollToBottom()
  }

  private showThinking(token: string): void {
    const bubble = this.currentMessageEl?.querySelector(".ai-message-bubble")
    if (!bubble) return
    if (!this.thinkingEl) {
      this.thinkingEl = document.createElement("div")
      this.thinkingEl.className = "ai-chat-thinking"
      bubble.appendChild(this.thinkingEl)
    }
    this.thinkingEl.textContent += token
    this.requestScrollToBottom()
  }

  private showConfirmationBar(toolIds: string[]): void {
    this.hideConfirmationBar()
    this.pendingConfirmation = toolIds
    this.confirmBarEl = document.createElement("div")
    this.confirmBarEl.className = "ai-chat-confirm-bar"

    const toolNames = toolIds.map(id => {
      const name = String(id).replace(/^(text-|call-)?/, "")
      return this.toolLabel(name) || name
    }).join(", ")

    this.confirmBarEl.innerHTML = `
      <span class="ai-chat-confirm-text">Proceed with: ${this.escapeHtml(toolNames)}?</span>
      <button class="ai-chat-confirm-ok" data-action="click->ai--chat#confirmActions">Confirm</button>
      <button class="ai-chat-confirm-cancel" data-action="click->ai--chat#cancelConfirmation">Cancel</button>
    `
    this.messagesTarget.appendChild(this.confirmBarEl)
    this.scrollToBottom()
  }

  private hideConfirmationBar(): void {
    this.confirmBarEl?.remove()
    this.confirmBarEl = null
    this.pendingConfirmation = null
  }

  async confirmActions(event: Event): Promise<void> {
    event.stopPropagation()
    if (!this.pendingConfirmation) return
    const ids = this.pendingConfirmation
    this.hideConfirmationBar()

    this.streamingValue = true
    this.abortController = new AbortController()

    try {
      const resp = await fetch(`/ai/conversations/${this.conversationIdValue}/messages/confirm`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "text/event-stream",
          "X-CSRF-Token": this.getCsrfToken()
        },
        body: JSON.stringify({ confirmed_tool_call_ids: ids.join(",") }),
        signal: this.abortController.signal
      })
      if (resp.ok) await this.readStream(resp)
    } catch (err: unknown) {
      if (err instanceof Error && err.name !== "AbortError") {
        const el = this.currentMessageEl || this.messagesTarget
        this.setMessageContent(el, `Error: ${err.message}`)
      }
    } finally {
      this.streamingValue = false
      this.setLoading(false)
      this.abortController = null
      this.hideToolIndicator()
    }
  }

  cancelConfirmation(event: Event): void {
    event.stopPropagation()
    this.hideConfirmationBar()
    this.abortStream()
  }

  private hideToolIndicator(): void {
    this.toolIndicatorEl?.remove()
    this.toolIndicatorEl = null
  }

  private clearWelcome(): void {
    const welcome = this.messagesTarget.querySelector(".ai-chat-welcome")
    welcome?.remove()
  }

  private scrollToBottom(): void {
    this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight
  }

  private setLoading(loading: boolean): void {
    this.sendButtonTarget.disabled = loading
    this.inputTarget.disabled = loading
    this.loadingIndicatorTarget.hidden = !loading
  }

  private highlightConversation(id: string): void {
    this.conversationsListTarget.querySelectorAll(".ai-chat-conversation-item").forEach(el => {
      el.classList.toggle("active", el.getAttribute("data-conversation-id") === id)
    })
  }

  private abortStream(): void {
    this.abortController?.abort()
    this.abortController = null
    this.streamingValue = false
    this.setLoading(false)
    this.hideToolIndicator()
  }

  private handleEscape = (e: KeyboardEvent): void => {
    if (e.key === "Escape" && !this.hiddenValue) {
      this.toggle()
    }
  }

  private welcomeText(): string {
    const el = this.element.querySelector(".ai-chat-welcome")
    return el?.innerHTML || "Ask me anything about your projects..."
  }

  private toolLabel(name: string): string {
    const labels: Record<string, string> = {
      search_work_packages: "Searching work packages...",
      create_work_package: "Creating work package...",
      update_work_package: "Updating work package...",
      get_project_info: "Looking up project...",
      get_user_tasks: "Finding your tasks...",
      list_projects: "Listing projects..."
    }
    return labels[name] || `Running ${name}...`
  }

  private getCsrfToken(): string {
    const meta = document.querySelector('meta[name="csrf-token"]')
    return meta?.getAttribute("content") || ""
  }

  private escapeHtml(text: string): string {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }

  private markdownToHtml(text: string): string {
    const escaped = this.escapeHtml(text)
    return escaped
      .replace(/```([\s\S]*?)```/g, "<pre><code>$1</code></pre>")
      .replace(/`([^`]+)`/g, "<code>$1</code>")
      .replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>")
      .replace(/\*([^*\n]+)\*/g, "<em>$1</em>")
      .replace(/^(#{1,6})\s+(.+)$/gm, (_, hashes, text) => `<h${hashes.length}>${text}</h${hashes.length}>`)
      .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>')
      .replace(/\n/g, "<br>")
  }
}
