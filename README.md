# Task Train

PostgreSQL-backed task orchestration for OpenCode agents. PostgreSQL stores task state, conversations, generated agent configuration, and agent-run audit data. An external Python supervisor listens for ready tasks and starts OpenCode workers.

## Status

This is an experimental system, not a production-ready security boundary. It has known workflow, authorization, and migration limitations documented below. Read them before giving an agent access to a meaningful repository or database.

## Architecture

```text
User
  |
  | tools/conductor_chat.sh
  v
PostgreSQL: user <-> Conductor conversation
  |
  | Conductor creates task rows
  v
tagg.agent_task -- NOTIFY tagg_task_ready --> db_supervisor.py
                                              |
                                              | reserve task, create agent_run token
                                              v
                                      agent-scripts/opencode_agent.sh
                                              |
                                              v
                                          opencode run
```

The database is the source of truth for task and conversation state. The supervisor is the process owner: PostgreSQL does not execute OpenCode, shell commands, or agent processes itself.

### Task Lifecycle

The supervisor reserves a pending task before spawning a worker:

```text
pending (1) -> assigned (2) -> in_progress (3)
```

`agent_run` records the spawned worker, its token hash, start/end time, exit code, and error. A nonzero worker exit requeues a task until `max_attempts` is reached, then moves it to status `5`.

Do not treat these numeric states as a stable public API. The seeded `standard` workflow currently defines statuses `5` and `6` as `tested` and `validated`, while retry handling treats status `5` as failed. This must be reconciled before relying on workflow reports.

## Conversations

`tools/conductor_chat.sh` is the supported interactive interface for the Conductor. It creates or resumes a `user_conductor` conversation, saves the user turn, runs OpenCode, then saves the final Conductor response.

```bash
bash tools/conductor_chat.sh
```

Useful environment variables:

```bash
PROJECT_ID=3 CHAT_USER=kasey CONDUCTOR_NAME=Conductor bash tools/conductor_chat.sh
CONTEXT_LIMIT=30 bash tools/conductor_chat.sh
```

Task assignment messages are stored in agent-pair conversations. Messages are stored in `tagg.message`; task/message associations use `tagg.message_agent_task_crosswalk`.

## Supervisor

`supervisor/db_supervisor.py` uses a dedicated `psycopg` connection to:

```sql
LISTEN tagg_task_ready;
```

The `task_ready_notification` trigger emits a notification whenever a task is inserted or transitions to pending. Notifications provide low-latency wakeups. The supervisor also reconciles pending tasks every 60 seconds because notifications are not durable while the supervisor is offline.

Start it directly:

```bash
python3 supervisor/db_supervisor.py -c supervisor/agents.json
```

Or start the supervisor and durable Conductor chat together:

```bash
bash start.sh
```

`start.sh --supervisor-only` starts only the supervisor. `start.sh --chat-only` requires an existing supervisor.

## Prerequisites

- PostgreSQL server and `psql`
- Python 3
- `psycopg>=3.3,<4`, listed in `requirements.txt`
- OpenCode CLI
- A pre-existing core `tagg` schema, tables, and timestamp/logging helper functions

On Arch-based systems, install the notification dependency with:

```bash
sudo pacman -S python-psycopg
```

## Configuration

The checked-in configuration template is:

```text
supervisor/agents.example.json
```

Create a local configuration before starting the supervisor:

```bash
cp supervisor/agents.example.json supervisor/agents.json
```

Set `db.host`, `db.port`, `db.dbname`, and `db.user` for the local PostgreSQL instance. `supervisor/agents.json` is intentionally ignored by Git.

Agent prompts and OpenCode frontmatter live in `tagg.user`. Run this after changing agent records:

```bash
bash sync_agents.sh
```

It renders generated agent files to `agents/` and `.opencode/agents/`. Both directories are ignored by Git.

## Migrations

The SQL files are historical migrations, not a migration framework. Their current order in `setup.sh` is:

```text
agent_config.sql
permissions.sql
workflow.sql
regress_workflow.sql
role_agents.sql
agent_config_db.sql
conversation_gateway.sql
hardening.sql
```

Important caveats:

- `setup.sh` creates the database but does not create the prerequisite core `tagg` schema.
- Several migrations are non-idempotent and order-dependent.
- `setup.sh` currently suppresses `psql` failures while printing success messages.

For an initial installation, run migrations only against an empty, prepared database and inspect output carefully. Do not represent setup as safely rerunnable until migrations are versioned and transactional.

## Data Model

Key existing tables:

| Table | Purpose |
| --- | --- |
| `tagg.user` | Human users and agents, including DB-stored prompts/configuration. |
| `tagg.agent_task` | Task queue, assignee, workflow, retry state, and failure details. |
| `tagg.workflow`, `tagg.workflow_step` | Data-driven workflow progression. |
| `tagg.conversation`, `tagg.message` | User/Conductor and agent-pair conversation history. |
| `tagg.agent_run` | Spawned worker audit record, token hash, timestamps, exit status, and error. |
| `tagg.artifact` | Task output artifacts. |

`conversation_gateway.sql` adds conversation kind/metadata and helper functions such as `get_or_create_user_conductor_conversation`, `append_conversation_message`, `get_conversation_context`, and `reserve_task`.

`hardening.sql` adds `agent_run`, run-context functions, task retry fields, ownership checks for selected operations, and the task-ready notification trigger.

## Agent Tools

Task workers receive `TASK_ID`, `AGENT_USER_ID`, `CONVERSATION_ID`, `PROJECT_ROOT`, and `AGENT_RUN_TOKEN` from the supervisor.

Mutating task tools require `AGENT_RUN_TOKEN`:

```text
tools/claim_task.sh
tools/create_task.sh
tools/create_artifact.sh
tools/advance_task.sh
tools/fail_task.sh
tools/list_pending_tasks.sh
```

The supplied agent ID arguments are retained for compatibility with existing prompts; the intended identity comes from the run token. `send_message.sh` routes messages through the centralized conversation append function.

## Security And Operational Limits

- Run tokens are audit and routing controls, not complete isolation. If an agent can connect as the shared administrative PostgreSQL role, it can bypass application-level restrictions. Use a dedicated restricted DB role and non-trust authentication before treating permissions as enforcement.
- Several gateway functions are `SECURITY DEFINER` and need tighter caller authorization and explicit grants before multi-user deployment.
- Stale-task recovery uses timestamps, not a worker heartbeat. A long-running worker can be requeued and duplicated.
- The supervisor can only auto-create configured agents when its database identity is authorized for `admin:agent`.
- Current seeded skills do not grant `task:claim`, and `claim_task.sh` prints run-context output before JSON. As a result, task workers cannot currently claim tasks successfully. Fix this before operating the queue.
- `fail_task.sh` calls `regress_workflow`, which does not yet enforce ownership or a defined `task:fail` permission.

## Repository Layout

```text
agent-scripts/   OpenCode worker entry point
sql/             Schema, historical migrations, and prompt maintenance scripts
supervisor/      Notification-driven process supervisor and local config template
tools/           Conversation, task, artifact, and inspection scripts
README.md        This document
requirements.txt Python runtime dependency specification
```

Ignored local state includes the PostgreSQL data directory (`tagg/`), generated agents, OpenCode runtime files, logs, local environment files, and `supervisor/agents.json`.
