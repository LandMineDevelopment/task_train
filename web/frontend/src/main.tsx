import { QueryClient, QueryClientProvider, useQuery } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import "./styles.css";

type Conversation = {
  id: number; title: string; project_name: string; owner_name: string | null;
  conductor_name: string | null; last_message: string; last_message_at: string | null; message_count: number;
};
type Message = {
  id: number; message: string; role: string; status: string; created: string;
  sender_name: string; sender_is_agent: boolean; recipient_name: string; task_ids: number[];
};
type Detail = { conversation: Conversation; messages: Message[] };

const client = new QueryClient();

async function request<T>(path: string): Promise<T> {
  const response = await fetch(path);
  if (!response.ok) throw new Error(`Request failed: ${response.status}`);
  return response.json() as Promise<T>;
}

function formatTime(value: string | null) {
  return value ? new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }).format(new Date(value)) : "No messages";
}

function App() {
  const [selectedId, setSelectedId] = useState<number | null>(null);
  const [filter, setFilter] = useState("");
  const conversations = useQuery({ queryKey: ["conversations"], queryFn: () => request<{ conversations: Conversation[] }>("/api/conversations"), refetchInterval: 5000 });
  const visible = (conversations.data?.conversations ?? []).filter((conversation) =>
    `${conversation.title} ${conversation.owner_name ?? ""} ${conversation.last_message}`.toLowerCase().includes(filter.toLowerCase()),
  );
  useEffect(() => {
    if (selectedId === null && visible[0]) setSelectedId(visible[0].id);
  }, [selectedId, visible]);
  const detail = useQuery({ queryKey: ["conversation", selectedId], queryFn: () => request<Detail>(`/api/conversations/${selectedId}`), enabled: selectedId !== null, refetchInterval: 5000 });

  return <main className="shell">
    <aside className="sidebar">
      <header><p className="eyebrow">Task Train</p><h1>Conductor Inbox</h1><p className="subtle">User conversations</p></header>
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
        <header className="thread-header"><div><p className="eyebrow">{detail.data.conversation.project_name}</p><h2>{detail.data.conversation.title}</h2><p className="subtle">{detail.data.conversation.owner_name ?? "User"} ↔ {detail.data.conversation.conductor_name ?? "Conductor"}</p></div><span className="count">{detail.data.messages.length} messages</span></header>
        <div className="messages">{detail.data.messages.map((message) => <article key={message.id} className={`message ${message.sender_is_agent ? "agent" : "human"}`}><div className="message-meta"><strong>{message.sender_name}</strong><time>{formatTime(message.created)}</time></div><p>{message.message}</p>{message.task_ids.length > 0 && <span className="task-link">Tasks #{message.task_ids.join(", #")}</span>}</article>)}{detail.data.messages.length === 0 && <p className="empty">This conversation has no messages yet.</p>}</div>
      </> : <div className="empty-state">{detail.isLoading ? "Loading conversation..." : "Select a conversation to read it."}</div>}
    </section>
  </main>;
}

createRoot(document.getElementById("root")!).render(<QueryClientProvider client={client}><App /></QueryClientProvider>);
