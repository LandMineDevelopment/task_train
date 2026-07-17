import { QueryClient, QueryClientProvider, useMutation, useQuery } from "@tanstack/react-query";
import { type FormEvent, type KeyboardEvent, type ReactNode, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import "./styles.css";

type Conversation = {
  id: number; title: string; project_name: string; owner_name: string | null;
  conductor_name: string | null; last_message: string; last_message_at: string | null; message_count: number;
};
type Message = {
  id: number; message: string; role: string; status: string; created: string;
  sender_name: string; sender_is_agent: boolean; recipient_name: string; task_ids: number[];
  task_states: { id: number; status: string }[];
};
type Artifact = { id: number; name: string; description: string; type: string; body: string | null };
type Task = { id: number; task: string; status: string; assignee_name: string; artifacts: Artifact[]; conversation_id?: number; conversation_title?: string | null };
type ArtifactRecord = Artifact & { task_id: number; conversation_id: number | null; conversation_title: string | null; assignee_name: string; task?: string; created?: string };
type Detail = { conversation: Conversation; messages: Message[]; tasks: Task[] };
type Tab = { key: string; kind: "conversation" | "tasks" | "artifacts" | "task" | "artifact"; id?: number; label: string };

const client = new QueryClient();

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(path, init);
  if (!response.ok) throw new Error(`Request failed: ${response.status}`);
  return response.json() as Promise<T>;
}

function formatTime(value: string | null) {
  return value ? new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }).format(new Date(value)) : "No messages";
}

function taskProgress(taskStates: Message["task_states"]) {
  if (taskStates.some((task) => task.status === "in_progress" || task.status === "reserved")) return "responding";
  if (taskStates.some((task) => task.status === "pending")) return "queued";
  if (taskStates.some((task) => task.status === "failed")) return "failed";
  return null;
}

function CodeBlock({ language, code }: { language: string; code: string }) {
  const lines = code.replace(/\n$/, "").split("\n");
  return <div className="code-block">
    <div className="code-block-header"><span>Code</span>{language && <span>{language}</span>}</div>
    <pre><code>{lines.map((line, index) => <span className="code-line" key={index}><span className="line-number">{index + 1}</span><span>{line || " "}</span></span>)}</code></pre>
  </div>;
}

function FormattedContent({ content }: { content: string }) {
  const blocks: ReactNode[] = [];
  const fencedCode = /```([^\n`]*)\n?([\s\S]*?)```/g;
  let cursor = 0;
  for (const match of content.matchAll(fencedCode)) {
    const text = content.slice(cursor, match.index);
    if (text) blocks.push(<p className="message-text" key={`text-${cursor}`}>{text.trim()}</p>);
    blocks.push(<CodeBlock key={`code-${match.index}`} language={match[1].trim()} code={match[2]} />);
    cursor = (match.index ?? 0) + match[0].length;
  }
  const text = content.slice(cursor);
  if (text) blocks.push(<p className="message-text" key={`text-${cursor}`}>{text.trim()}</p>);
  return <>{blocks}</>;
}

function isCodeArtifact(artifact: Artifact) {
  return artifact.type === "code" || /\.(py|js|ts|tsx|jsx|json|sql|sh|yaml|yml|md)$/i.test(artifact.name);
}

function ArtifactOutput({ artifact, openArtifact }: { artifact: Artifact; openArtifact?: (artifact: Artifact) => void }) {
  const body = artifact.body ?? "";
  const content = body.includes("\n") ? body : body.replaceAll("\\n", "\n");
  return <section className="artifact-output">
    <div className="artifact-heading"><span>{artifact.type.replaceAll("-", " ")}</span><button onClick={() => openArtifact?.(artifact)}>{artifact.name}</button></div>
    <p className="artifact-description">{artifact.description}</p>
    {isCodeArtifact(artifact) ? <CodeBlock language={artifact.name.split(".").at(-1) ?? ""} code={content} /> : <FormattedContent content={content} />}
  </section>;
}

function TaskActivity({ task, action, openTask }: { task: Task; action: string; openTask?: (task: Task) => void }) {
  return <details className="task-activity">
    <summary><button onClick={(event) => { event.preventDefault(); openTask?.(task); }}>Task #{task.id}</button><strong>{task.assignee_name} {action}</strong><em className={`task-state ${task.status}`}>{task.status}</em></summary>
    <p>{task.task}</p>
  </details>;
}

function MessageContent({ content, tasks, openTask, openArtifact }: { content: string; tasks: Task[]; openTask: (task: Task) => void; openArtifact: (artifact: Artifact) => void }) {
  const marker = "\n\nArtifact:\n";
  const artifactStart = content.indexOf(marker);
  const task = tasks.find((candidate) => content.includes(`task #${candidate.id}`));
  const lifecycle = content.match(/\b(started|completed|failed|cancelled) task #\d+:/);
  const summary = artifactStart === -1 ? content : content.slice(0, artifactStart);
  return <>
    {task && lifecycle ? <TaskActivity task={task} action={lifecycle[1]} openTask={openTask} /> : <FormattedContent content={summary} />}
    {artifactStart !== -1 && task?.artifacts.map((artifact) => <ArtifactOutput key={artifact.id} artifact={artifact} openArtifact={openArtifact} />)}
    {artifactStart !== -1 && !task?.artifacts.length && <section className="artifact-output"><div className="artifact-heading">Artifact output</div><FormattedContent content={content.slice(artifactStart + marker.length)} /></section>}
  </>;
}

function TaskList({ tasks, openTask }: { tasks: Task[]; openTask: (task: Task) => void }) {
  return <div className="record-list">{tasks.map((task) => <button className="record" key={task.id} onClick={() => openTask(task)}><span className="record-kicker">Task #{task.id} · {task.status}</span><strong>{task.assignee_name}</strong><span>{task.task}</span></button>)}</div>;
}

function ArtifactList({ artifacts, openArtifact }: { artifacts: ArtifactRecord[]; openArtifact: (artifact: ArtifactRecord) => void }) {
  return <div className="record-list">{artifacts.map((artifact) => <button className="record" key={artifact.id} onClick={() => openArtifact(artifact)}><span className="record-kicker">{artifact.type} · Task #{artifact.task_id}</span><strong>{artifact.name}</strong><span>{artifact.description}</span></button>)}</div>;
}

function App() {
  const [selectedId, setSelectedId] = useState<number | null>(null);
  const [tabs, setTabs] = useState<Tab[]>([]);
  const [activeTabKey, setActiveTabKey] = useState<string | null>(null);
  const [filter, setFilter] = useState("");
  const [draft, setDraft] = useState("");
  const [editingTitle, setEditingTitle] = useState(false);
  const [titleDraft, setTitleDraft] = useState("");
  const [sidebarCollapsed, setSidebarCollapsed] = useState(() => {
    const saved = localStorage.getItem("task-train-sidebar-collapsed");
    return saved === null ? window.matchMedia("(max-width: 720px)").matches : saved === "true";
  });
  const messagesRef = useRef<HTMLDivElement>(null);
  const scrolledConversation = useRef<number | null>(null);
  const lastMessageId = useRef<number | null>(null);
  const conversations = useQuery({ queryKey: ["conversations"], queryFn: () => request<{ conversations: Conversation[] }>("/api/conversations"), refetchInterval: 5000 });
  const visible = (conversations.data?.conversations ?? []).filter((conversation) =>
    `${conversation.title} ${conversation.owner_name ?? ""} ${conversation.last_message}`.toLowerCase().includes(filter.toLowerCase()),
  );
  useEffect(() => {
    if (selectedId !== null && conversations.data && !conversations.data.conversations.some((conversation) => conversation.id === selectedId)) {
      setSelectedId(null);
    }
  }, [conversations.data, selectedId]);
  const detail = useQuery({ queryKey: ["conversation", selectedId], queryFn: () => request<Detail>(`/api/conversations/${selectedId}`), enabled: selectedId !== null, refetchInterval: 5000 });
  const taskList = useQuery({ queryKey: ["tasks"], queryFn: () => request<{ tasks: Task[] }>("/api/tasks") });
  const artifactList = useQuery({ queryKey: ["artifacts"], queryFn: () => request<{ artifacts: ArtifactRecord[] }>("/api/artifacts") });
  const activeTab = tabs.find((tab) => tab.key === activeTabKey) ?? null;
  const taskDetail = useQuery({ queryKey: ["task", activeTab?.id], queryFn: () => request<Task>(`/api/tasks/${activeTab?.id}`), enabled: activeTab?.kind === "task" });
  const artifactDetail = useQuery({ queryKey: ["artifact", activeTab?.id], queryFn: () => request<ArtifactRecord>(`/api/artifacts/${activeTab?.id}`), enabled: activeTab?.kind === "artifact" });

  function openTab(tab: Tab) {
    setTabs((current) => current.some((item) => item.key === tab.key) ? current : [...current, tab]);
    setActiveTabKey(tab.key);
  }
  function openConversation(conversation: Pick<Conversation, "id" | "title">) {
    setSelectedId(conversation.id);
    openTab({ key: `conversation-${conversation.id}`, kind: "conversation", id: conversation.id, label: conversation.title });
  }
  function openTask(task: Pick<Task, "id" | "task">) { openTab({ key: `task-${task.id}`, kind: "task", id: task.id, label: `Task #${task.id}` }); }
  function openArtifact(artifact: Pick<Artifact, "id" | "name">) { openTab({ key: `artifact-${artifact.id}`, kind: "artifact", id: artifact.id, label: artifact.name }); }
  function closeTab(key: string) {
    setTabs((current) => { const next = current.filter((tab) => tab.key !== key); if (activeTabKey === key) setActiveTabKey(next.at(-1)?.key ?? null); return next; });
  }
  useEffect(() => { if (selectedId === null && visible[0]) openConversation(visible[0]); }, [selectedId, visible]);
  useEffect(() => { localStorage.setItem("task-train-sidebar-collapsed", String(sidebarCollapsed)); }, [sidebarCollapsed]);
  const newConversation = useMutation({
    mutationFn: () => request<{ conversation_id: number }>("/api/conversations", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" }),
    onSuccess: ({ conversation_id }) => { openConversation({ id: conversation_id, title: "New chat" }); client.invalidateQueries({ queryKey: ["conversations"] }); },
  });
  const sendMessage = useMutation({
    mutationFn: (message: string) => request(`/api/conversations/${selectedId}/messages`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ message }) }),
    onSuccess: () => { setDraft(""); client.invalidateQueries({ queryKey: ["conversations"] }); client.invalidateQueries({ queryKey: ["conversation", selectedId] }); },
  });
  const renameConversation = useMutation({
    mutationFn: (title: string) => request(`/api/conversations/${selectedId}`, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ title }) }),
    onSuccess: () => { setEditingTitle(false); client.invalidateQueries({ queryKey: ["conversations"] }); client.invalidateQueries({ queryKey: ["conversation", selectedId] }); },
  });

  useEffect(() => { scrolledConversation.current = null; lastMessageId.current = null; setEditingTitle(false); }, [selectedId]);
  useEffect(() => {
    if (detail.data?.conversation.id === selectedId) {
      const newestMessageId = detail.data.messages.at(-1)?.id ?? null;
      if (scrolledConversation.current === selectedId && lastMessageId.current === newestMessageId) return;
      requestAnimationFrame(() => messagesRef.current?.scrollTo({ top: messagesRef.current.scrollHeight }));
      scrolledConversation.current = selectedId;
      lastMessageId.current = newestMessageId;
    }
  }, [detail.data, selectedId]);

  function submitMessage(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (draft.trim() && selectedId !== null && !sendMessage.isPending) sendMessage.mutate(draft);
  }

  function submitRename(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (titleDraft.trim() && !renameConversation.isPending) renameConversation.mutate(titleDraft);
  }

  function handleComposerKeyDown(event: KeyboardEvent<HTMLTextAreaElement>) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      if (draft.trim() && selectedId !== null && !sendMessage.isPending) sendMessage.mutate(draft);
    }
  }

  return <main className={`shell ${sidebarCollapsed ? "sidebar-collapsed" : ""}`}>
    <aside className="sidebar">
      <button
        className="sidebar-toggle"
        aria-label={sidebarCollapsed ? "Expand conversations panel" : "Collapse conversations panel"}
        aria-expanded={!sidebarCollapsed}
        onClick={() => setSidebarCollapsed((collapsed) => !collapsed)}
      >
        <span aria-hidden="true">{sidebarCollapsed ? "›" : "‹"}</span>
      </button>
      <div className="sidebar-content">
        <header><p className="eyebrow">Task Train</p><h1>Conductor Inbox</h1><p className="subtle">User conversations</p></header>
        <button className="new-chat" onClick={() => newConversation.mutate()} disabled={newConversation.isPending}>{newConversation.isPending ? "Starting..." : "New chat"}</button>
        <input aria-label="Search conversations" value={filter} onChange={(event) => setFilter(event.target.value)} placeholder="Search conversations" />
        <section className="conversation-list">
          {conversations.isLoading && <p className="empty">Loading conversations...</p>}
          {visible.map((conversation) => <button key={conversation.id} className={`conversation ${conversation.id === selectedId ? "selected" : ""}`} onClick={() => openConversation(conversation)}>
            <span className="conversation-title">{conversation.title}</span>
            <span className="conversation-meta">{conversation.owner_name ?? "User"} · {formatTime(conversation.last_message_at)}</span>
            <span className="preview">{conversation.last_message || "No messages yet"}</span>
          </button>)}
          {!conversations.isLoading && visible.length === 0 && <p className="empty">No user-Conductor conversations found.</p>}
        </section>
      </div>
    </aside>
    <section className="thread">
      <nav className="workspace-nav"><button onClick={() => openTab({ key: "tasks", kind: "tasks", label: "Tasks" })}>Tasks</button><button onClick={() => openTab({ key: "artifacts", kind: "artifacts", label: "Artifacts" })}>Artifacts</button></nav>
      {tabs.length > 0 && <nav className="tabs">{tabs.map((tab) => <div className={`tab ${tab.key === activeTabKey ? "active" : ""}`} key={tab.key}><button onClick={() => { setActiveTabKey(tab.key); if (tab.kind === "conversation" && tab.id) setSelectedId(tab.id); }}>{tab.label}</button><button aria-label={`Close ${tab.label}`} onClick={() => closeTab(tab.key)}>×</button></div>)}</nav>}
      {activeTab?.kind === "tasks" ? <section className="detail-view"><header className="thread-header"><div><p className="eyebrow">Workspace</p><h2>Tasks</h2></div><span className="count">{taskList.data?.tasks.length ?? 0} tasks</span></header><TaskList tasks={taskList.data?.tasks ?? []} openTask={openTask} /></section>
        : activeTab?.kind === "artifacts" ? <section className="detail-view"><header className="thread-header"><div><p className="eyebrow">Workspace</p><h2>Artifacts</h2></div><span className="count">{artifactList.data?.artifacts.length ?? 0} artifacts</span></header><ArtifactList artifacts={artifactList.data?.artifacts ?? []} openArtifact={openArtifact} /></section>
          : activeTab?.kind === "task" && taskDetail.data ? <section className="detail-view"><header className="thread-header"><div><p className="eyebrow">{taskDetail.data.conversation_title ?? "Unlinked task"}</p><h2>Task #{taskDetail.data.id}</h2><p className="subtle">{taskDetail.data.assignee_name} · {taskDetail.data.status}</p></div>{taskDetail.data.conversation_id && <button className="record-link" onClick={() => openConversation({ id: taskDetail.data.conversation_id!, title: taskDetail.data.conversation_title ?? "Conversation" })}>Open conversation</button>}</header><div className="detail-body"><p className="message-text">{taskDetail.data.task}</p>{taskDetail.data.artifacts.map((artifact) => <ArtifactOutput key={artifact.id} artifact={artifact} openArtifact={openArtifact} />)}</div></section>
            : activeTab?.kind === "artifact" && artifactDetail.data ? <section className="detail-view"><header className="thread-header"><div><p className="eyebrow">{artifactDetail.data.type}</p><h2>{artifactDetail.data.name}</h2><p className="subtle">Task #{artifactDetail.data.task_id} · {artifactDetail.data.assignee_name}</p></div><button className="record-link" onClick={() => openTask({ id: artifactDetail.data.task_id, task: artifactDetail.data.task ?? "" })}>Open task</button></header><div className="detail-body"><ArtifactOutput artifact={artifactDetail.data} /></div></section>
              : activeTab?.kind === "conversation" && detail.data ? <>
        <header className="thread-header"><div><p className="eyebrow">{detail.data.conversation.project_name}</p>{editingTitle ? <form className="rename-form" onSubmit={submitRename}><input aria-label="Conversation title" value={titleDraft} onChange={(event) => setTitleDraft(event.target.value)} autoFocus /><button type="submit" disabled={renameConversation.isPending}>Save</button><button type="button" onClick={() => setEditingTitle(false)}>Cancel</button></form> : <div className="title-row"><h2>{detail.data.conversation.title}</h2><button className="rename-button" onClick={() => { setTitleDraft(detail.data.conversation.title); setEditingTitle(true); }}>Rename</button></div>}<p className="subtle">{detail.data.conversation.owner_name ?? "User"} ↔ {detail.data.conversation.conductor_name ?? "Conductor"}</p></div><span className="count">{detail.data.messages.length} messages</span></header>
        <div className="messages" ref={messagesRef}>{detail.data.messages.map((message) => <article key={message.id} className={`message ${message.sender_is_agent ? "agent" : "human"}`}><div className="message-meta"><strong>{message.sender_name}</strong><time>{formatTime(message.created)}</time></div><MessageContent content={message.message} tasks={detail.data.tasks} openTask={openTask} openArtifact={openArtifact} />{message.task_ids.map((id) => <button className="task-link" key={id} onClick={() => openTask({ id, task: "" })}>Task #{id}</button>)}{taskProgress(message.task_states) === "queued" && <span className="conductor-status queued">Message queued for Conductor</span>}{taskProgress(message.task_states) === "responding" && <span className="conductor-status responding"><i />Conductor has seen your message and is responding</span>}{taskProgress(message.task_states) === "failed" && <span className="conductor-status failed">Conductor could not respond. Check OpenCode authentication.</span>}</article>)}{detail.data.messages.length === 0 && <p className="empty">Start this conversation with the Conductor.</p>}</div>
        <form className="composer" onSubmit={submitMessage}><textarea aria-label="Message Conductor" value={draft} onChange={(event) => setDraft(event.target.value)} onKeyDown={handleComposerKeyDown} placeholder="Tell the Conductor what you need..." disabled={sendMessage.isPending} /><div><span>{sendMessage.isPending ? "Queueing workflow..." : "Enter to send · Shift+Enter for a new line."}</span><button type="submit" disabled={!draft.trim() || sendMessage.isPending}>{sendMessage.isPending ? "Sending..." : "Send"}</button></div>{sendMessage.isError && <p className="form-error">The message could not be queued. Check the local services and try again.</p>}</form>
      </> : <div className="empty-state">Select a conversation, task, or artifact.</div>}
    </section>
  </main>;
}

createRoot(document.getElementById("root")!).render(<QueryClientProvider client={client}><App /></QueryClientProvider>);
