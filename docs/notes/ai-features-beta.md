# AI Features - Future Workstream: Beta on yojana.matteralchemy.ai

**Created:** 2026-09-12
**Owner:** girishm (to pick up later)
**Status:** Not started - broken AI features need fixing, then release to beta on `yojana.matteralchemy.ai`.

## Background

Yojana prod (`element`, https://yojana.girishm.info) has OpenProject's AI integration module
(`modules/ai`) enabled, backed by a locally running Ollama (`llama3.2:3b`, `OLLAMA_HOST=0.0.0.0:11434`)
on the element VM. The AI features are buggy and need to be fixed. User decision: the fixed AI
features will be released for beta on the new mirror VM `yojana-ma` (https://yojana.matteralchemy.ai)
before any prod rollout.

The mirror `yojana-ma` (aether startup-credit sub `6ea62dea-...`, RG `aether-rg`, westus2,
`Standard_D2s_v3`, 128 GiB, public IP `52.246.252.242`, NSG `yojana-ma-nsg` = 22/80/443) is already
live and serving the cloned data on `girish17/yojana:dev-azure-18`.

## What exists already (checked 2026-09-12)

- `modules/ai` is committed on `dev` and ships inside `dev-azure-18` (already deployed on `yojana-ma`).
  3 commits: `e699bd0b3d6` (add AI: Ollama chat, inline AI, agents), `28801382c87` (fixes: stop JSON
  tool-call output, markdown rendering, NL search), `fc62a88de54` (chat SSE timing fix).
- Full module tree in container `/app/modules/ai/`: chat, agents (custom + daily summary), search,
  suggestions, summaries, conversations/messages controllers, tools (create/update/search work
  packages, project info, list projects, user tasks), frontend stimulus controller, hooks
  (`_chat_button`, `_chat_panel`, `_search_bar`, `_smart_fill`, `_summarize_button`), workers
  (`agent_run_job`, `agent_scheduler_job`), specs, migrations (2026-05-12 + 2026-05-15).
- DB on `yojana-ma` has all AI tables (cloned from prod): `ai_settings`, `ai_conversations`,
  `ai_agents`, `ai_messages`, `ai_agent_executions` (also group_details/paper_trail_audits exist).
- `ai_settings` row: `ollama_endpoint=http://172.17.0.1:11434`, `default_model=llama3.2:3b`,
  `max_tokens=2048`, `temperature=0.7`.

## What's missing / broken

- **No Ollama on `yojana-ma`**: no `ollama` binary, port 11434 unreachable, so AI endpoints on the
  mirror currently fail. Needs Ollama install + `llama3.2:3b` pull (match prod:
  `OLLAMA_HOST=0.0.0.0:11434`, reached via docker bridge `172.17.0.1:11434`).
- **AI features themselves are buggy** (user reported). Known pain points from the fix commits:
  JSON tool-call output, SSE/streaming timing, chat reliability. Exact bug list to be reproduced and
  defined when this workstream is picked up.

## Plan (when picked up)

1. Install Ollama on `yojana-ma`, pull `llama3.2:3b`, bind `OLLAMA_HOST=0.0.0.0:11434`, confirm
   `172.17.0.1:11434` reachable from the container.
2. Reproduce AI bugs on the mirror; define issue list.
3. Fix in `modules/ai`, build next image (`dev-azure-19`), deploy to `yojana-ma` via existing Jenkins
   pipeline (creds: github-yojana / dockerhub / yojana-azure-sp / yojana-azure-tenant) or direct pull.
4. Beta-test end to end on https://yojana.matteralchemy.ai (login + chat/agents/search/summarize).
5. Only after beta is solid, consider prod rollout (deploy #19 to `yojana.girishm.info` had been
   paused pending approval; element keeps running `dev-azure-locale-v5`).

## Access shortcuts

- Mirror VM: `ssh -o BatchMode=yes -i ~/.ssh/id_rsa azureuser@52.246.252.242` (docker needs sudo).
- Prod VM element: `ssh -i ~/.ssh/id_rsa azureuser@172.210.60.214`, docker without sudo.
- Prod Ollama check: `curl -s http://127.0.0.1:11434/api/tags` on element.
- CI: Jenkins tunnel `localhost:8081`, auth `jenkins-admin/...` from
  `/Users/admin/azure-deployment/yojana/.env`; pipeline `yojana-pipeline`.