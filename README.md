# Task Train

PostgreSQL-backed task orchestration for OpenCode agents. PostgreSQL stores task state, conversations, generated agent configuration, and agent-run audit data. An external Python supervisor listens for ready tasks and starts OpenCode workers.

## Status

This is an experimental system, not a production-ready security boundary. It has known authorization and operational limitations documented below. Read them before giving an agent access to a meaningful repository or database.

## Quick Start With Docker

Docker Compose is the supported full environment. It includes PostgreSQL, Python with `psycopg`, `psql`, Git, Bash, and OpenCode. Docker is the only required local installation, plus credentials for the model provider.

From a new clone:

```bash
git clone https://github.com/LandMineDevelopment/task_train.git
cd task_train
./configure.sh
docker compose up -d --build
docker compose exec app bash tools/smoke_test.sh
```

`configure.sh` creates a local, Git-ignored `.env` file and generates a secure database password unless you provide one. It asks for the Compose project name, host database port, database name, and database user. For automated setup:

```bash
./configure.sh --non-interactive --port 5434 --database task_train --user task_train
```

The Compose database uses port `5433` by default. If it is occupied, choose another port during configuration. The application container always connects internally to `db:5432`; use the selected host port only for DBeaver or other host tools.

Show the current connection details for DBeaver:

```bash
bash tools/show_connection.sh
```

Changing only the host port is safe after first startup. PostgreSQL applies the database name, user, and password only when its data volume is initialized. To change those three values later, run `docker compose down -v`, re-run `./configure.sh`, then start Compose again. Docker credentials are development-only and must not be used outside a local machine.

The database container initializes the supported bootstrap migration sequence on its first start. To discard its local data and initialize again:

```bash
docker compose down -v
docker compose up -d
```

Authenticate OpenCode inside the application container, then start the durable Conductor chat:

```bash
docker compose exec app opencode auth login
docker compose exec app bash start.sh
```

OpenCode configuration is stored in named Docker volumes, so authentication survives application-container replacement. `start.sh` opens the durable Conductor chat; type `/exit` to stop it.

To stop the environment without removing database or OpenCode state:

```bash
docker compose down
```

## Testing

The default test suite uses real PostgreSQL and a fake worker; it does not call a model provider:

```bash
docker compose exec app bash tests/run.sh
```

Run the full clean-install test, including a temporary Docker project and configuration validation, from the host:

```bash
tests/test_fresh_bootstrap.sh
```

The test suite covers schema bootstrap, roles and permissions, run tokens, task reservation/claim/failure transitions, conversation ordering, generic tagging constraints, PostgreSQL notifications, shell tool JSON output, and supervisor worker dispatch.

## Native Install

For an existing local PostgreSQL installation, run:

```bash
bash install.sh
```

The installer checks `psql`, OpenCode, and `psycopg`, initializes an empty database, and creates a local supervisor configuration when needed. It is for a new database only; use Docker Compose to get the reproducible default environment.

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
pending (1) -> reserved (2) -> in_progress (3)
```

`agent_run` records the spawned worker, its token hash, start/end time, exit code, and error. A nonzero worker exit requeues a task until `max_attempts` is reached, then moves it to `failed (7)`.

`failed (7)` and `cancelled (8)` are terminal exceptions rather than linear workflow steps. A worker may fail only its assigned reserved or in-progress task. Cancellation requires the dedicated `task:cancel` permission.

## Roles And Permissions

Active roles use dedicated skills rather than overlapping generic skills:

| Role | Skill | Allowed work |
| --- | --- | --- |
| Conductor | `orchestration` | Create and delegate tasks, link/send task messages, report progress. |
| Coder | `code-python` | Claim, implement, save artifacts, complete or fail assigned work. |
| Tester | `testing` | Claim, write tests, save evidence, complete or fail assigned work. |
| Explorer | `research` | Claim, research, save findings, and complete assigned research. |
| Reviewer | `review` | Claim, review, save findings, complete or fail assigned work. |
| Manager | `orchestration`, `manager-runtime` | Coordinate assigned work and complete or fail Manager-owned tasks. |

`Admin-Agent` retains administrative permissions and is not part of the normal delivery workflow.

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

Set `db.host`, `db.port`, `db.dbname`, `db.user`, and, where required, `db.password` for the local PostgreSQL instance. `supervisor/agents.json` is intentionally ignored by Git.

Agent prompts and OpenCode frontmatter live in `tagg.user`. Run this after changing agent records:

```bash
bash sync_agents.sh
```

It renders generated agent files to `agents/` and `.opencode/agents/`. Both directories are ignored by Git.

## Migrations

The bootstrap applies these files in order:

```text
000_core.sql
agent_config.sql
permissions.sql
workflow.sql
regress_workflow.sql
role_agents.sql
agent_config_db.sql
conversation_gateway.sql
hardening.sql
workflow_hardening.sql
generic_entities.sql
```

`000_core.sql` provides the base schema required by the historical migrations. Bootstrap stops on the first SQL error. Migrations remain order-dependent and are intended for an empty database; Docker Compose is the recommended clean-install path.

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
| `tagg.tag` | Reusable labels for projects, files, notes, objects, conversations, messages, tasks, and artifacts. |
| `tagg.note`, `tagg.file` | Text notes and binary file records. |
| `tagg.obj_type`, `tagg.object` | Typed JSON documents. |
| `tagg.artifact_type` | Artifact type lookup records. |

`conversation_gateway.sql` adds conversation kind/metadata and helper functions such as `get_or_create_user_conductor_conversation`, `append_conversation_message`, `get_conversation_context`, and `reserve_task`.

`hardening.sql` adds `agent_run`, run-context functions, task retry fields, ownership checks for selected operations, and the task-ready notification trigger.

## Agent Tools

Task workers receive `TASK_ID`, `AGENT_USER_ID`, `CONVERSATION_ID`, `PROJECT_ROOT`, and `AGENT_RUN_TOKEN` from the supervisor.

Run-token-scoped task tools include:

```text
tools/claim_task.sh
tools/create_task.sh
tools/create_artifact.sh
tools/advance_task.sh
tools/fail_task.sh
tools/list_pending_tasks.sh
```

All listed tools require `AGENT_RUN_TOKEN`; `list_pending_tasks.sh` is read-only. Supplied agent ID arguments are retained for compatibility with existing prompts; the intended identity comes from the run token. `send_message.sh` routes messages through the centralized conversation append function.

## Security And Operational Limits

- Run tokens are audit and routing controls, not complete isolation. If an agent can connect as the shared administrative PostgreSQL role, it can bypass application-level restrictions. Use a dedicated restricted DB role and non-trust authentication before treating permissions as enforcement.
- Several gateway functions are `SECURITY DEFINER` and need tighter caller authorization and explicit grants before multi-user deployment.
- Stale-task recovery uses timestamps, not a worker heartbeat. A long-running worker can be requeued and duplicated.
- The supervisor can only auto-create configured agents when its database identity is authorized for `admin:agent`.
- `regress_workflow()` remains a legacy function. Use `tools/fail_task.sh`, which calls the ownership-checked `fail_task()` function.

## Repository Layout

```text
agent-scripts/   OpenCode worker entry point
sql/             Schema, historical migrations, and prompt maintenance scripts
supervisor/      Notification-driven process supervisor and local config template
                  (`agents.docker.example.json` is the Docker host config)
docker/          PostgreSQL initialization scripts for Docker Compose
compose.yml      Local development database definition
tools/           Conversation, task, artifact, and inspection scripts
README.md        This document
requirements.txt Python runtime dependency specification
```

Ignored local state includes the PostgreSQL data directory (`tagg/`), generated agents, OpenCode runtime files, logs, local environment files, and `supervisor/agents.json`.
