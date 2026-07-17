-- Links browser-originated Conductor tasks to their user conversation.
ALTER TABLE tagg.agent_task
    ADD COLUMN IF NOT EXISTS conversation_id bigint REFERENCES tagg.conversation(id);

CREATE INDEX IF NOT EXISTS agent_task_conversation_id_idx
    ON tagg.agent_task (conversation_id)
    WHERE conversation_id IS NOT NULL;
