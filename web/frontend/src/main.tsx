import { QueryClient, QueryClientProvider, useMutation, useQuery } from "@tanstack/react-query";
import { type FormEvent, type KeyboardEvent, useEffect, useRef, useState } from "react";
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
type Detail = { conversation: Conversation; messages: Message[] };

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

function App() {
  const [selectedId, setSelectedId] = useState<number | null>(null);
  const [filter, setFilter] = useState("");
  const [draft, setDraft] = useState("");
  const [editingTitle, setEditingTitle] = useState(false);
  const [titleDraft, setTitleDraft] = useState("");
  const messagesRef = useRef<HTMLDivElement>(null);
  const scrolledConversation = useRef<number | null>(null);
  const conversations = useQuery({ queryKey: ["conversations"], queryFn: () => request<{ conversations: Conversation[] }>("/api/conversations"), refetchInterval: 5000 });
  const visible = (conversations.data?.conversations ?? []).filter((conversation) =>
    `${conversation.title} ${conversation.owner_name ?? ""} ${conversation.last_message}`.toLowerCase().includes(filter.toLowerCase()),
  );
  useEffect(() => {
    if (selectedId !== null && conversations.data && !conversations.data.conversations.some((conversation) => conversation.id === selectedId)) {
      setSelectedId(null);
    }
  }, [conversations.data, selectedId]);
  useEffect(() => {
    if (selectedId === null && visible[0]) setSelectedId(visible[0].id);
  }, [selectedId, visible]);
  const detail = useQuery({ queryKey: ["conversation", selectedId], queryFn: () => request<Detail>(`/api/conversations/${selectedId}`), enabled: selectedId !== null, refetchInterval: 5000 });
  const newConversation = useMutation({
    mutationFn: () => request<{ conversation_id: number }>("/api/conversations", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" }),
    onSuccess: ({ conversation_id }) => { setSelectedId(conversation_id); client.invalidateQueries({ queryKey: ["conversations"] }); },
  });
  const sendMessage = useMutation({
    mutationFn: (message: string) => request(`/api/conversations/${selectedId}/messages`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ message }) }),
    onSuccess: () => { setDraft(""); client.invalidateQueries({ queryKey: ["conversations"] }); client.invalidateQueries({ queryKey: ["conversation", selectedId] }); },
  });
  const renameConversation = useMutation({
    mutationFn: (title: string) => request(`/api/conversations/${selectedId}`, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ title }) }),
    onSuccess: () => { setEditingTitle(false); client.invalidateQueries({ queryKey: ["conversations"] }); client.invalidateQueries({ queryKey: ["conversation", selectedId] }); },
  });

  useEffect(() => { scrolledConversation.current = null; setEditingTitle(false); }, [selectedId]);
  useEffect(() => {
    if (detail.data?.conversation.id === selectedId && scrolledConversation.current !== selectedId) {
      messagesRef.current?.scrollTo({ top: messagesRef.current.scrollHeight });
      scrolledConversation.current = selectedId;
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

  return <main className="shell">
    <aside className="sidebar">
      <header><p className="eyebrow">Task Train</p><h1>Conductor Inbox</h1><p className="subtle">User conversations</p></header>
      <button className="new-chat" onClick={() => newConversation.mutate()} disabled={newConversation.isPending}>{newConversation.isPending ? "Starting..." : "New chat"}</button>
      <input aria-label="Search conversations" value={filter} onChange={(event) => setFilter(event.target.value)} placeholder="Search conversations" />
      <section className="conversation-list">
        {conversations.isLoading && <p className="empty">Loading conversations...</p>}
        {visible.map((conversation) => <button key={conversation.id} className={`conversation ${conversation.id === selectedId ? "selected" : ""}`} onClick={() => setSelectedId(conversation.id)}>
          <span className="conversation-title">{conversation.title}</span>
          <span className="conversation-meta">{conversation.owner_name ?? "User"} · {formatTime(conversation.last_message_at)}</span>
          <span className="preview">{conversation.last_message || "No messages yet"}</span>
        </button>)}
        {!conversations.isLoading && visible.length === 0 && <p className="empty">No user-Conductor conversations found.</p>}
      </section>
    </aside>
    <section className="thread">
      {detail.data ? <>
        <header className="thread-header"><div><p className="eyebrow">{detail.data.conversation.project_name}</p>{editingTitle ? <form className="rename-form" onSubmit={submitRename}><input aria-label="Conversation title" value={titleDraft} onChange={(event) => setTitleDraft(event.target.value)} autoFocus /><button type="submit" disabled={renameConversation.isPending}>Save</button><button type="button" onClick={() => setEditingTitle(false)}>Cancel</button></form> : <div className="title-row"><h2>{detail.data.conversation.title}</h2><button className="rename-button" onClick={() => { setTitleDraft(detail.data.conversation.title); setEditingTitle(true); }}>Rename</button></div>}<p className="subtle">{detail.data.conversation.owner_name ?? "User"} ↔ {detail.data.conversation.conductor_name ?? "Conductor"}</p></div><span className="count">{detail.data.messages.length} messages</span></header>
        <div className="messages" ref={messagesRef}>{detail.data.messages.map((message) => <article key={message.id} className={`message ${message.sender_is_agent ? "agent" : "human"}`}><div className="message-meta"><strong>{message.sender_name}</strong><time>{formatTime(message.created)}</time></div><p>{message.message}</p>{message.task_ids.length > 0 && <span className="task-link">Tasks #{message.task_ids.join(", #")}</span>}{taskProgress(message.task_states) === "queued" && <span className="conductor-status queued">Message queued for Conductor</span>}{taskProgress(message.task_states) === "responding" && <span className="conductor-status responding"><i />Conductor has seen your message and is responding</span>}{taskProgress(message.task_states) === "failed" && <span className="conductor-status failed">Conductor could not respond. Check OpenCode authentication.</span>}</article>)}{detail.data.messages.length === 0 && <p className="empty">Start this conversation with the Conductor.</p>}</div>
        <form className="composer" onSubmit={submitMessage}><textarea aria-label="Message Conductor" value={draft} onChange={(event) => setDraft(event.target.value)} onKeyDown={handleComposerKeyDown} placeholder="Tell the Conductor what you need..." disabled={sendMessage.isPending} /><div><span>{sendMessage.isPending ? "Queueing workflow..." : "Enter to send · Shift+Enter for a new line."}</span><button type="submit" disabled={!draft.trim() || sendMessage.isPending}>{sendMessage.isPending ? "Sending..." : "Send"}</button></div>{sendMessage.isError && <p className="form-error">The message could not be queued. Check the local services and try again.</p>}</form>
      </> : <div className="empty-state">{detail.isLoading ? "Loading conversation..." : "Select a conversation to read it."}</div>}
    </section>
  </main>;
}

createRoot(document.getElementById("root")!).render(<QueryClientProvider client={client}><App /></QueryClientProvider>);
