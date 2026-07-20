-- Links browser-originated Conductor tasks to their user conversation.
ALTER TABLE tagg.agent_task
    ADD COLUMN IF NOT EXISTS conversation_id bigint REFERENCES tagg.conversation(id);
ALTER TABLE tagg.agent_task
    ADD COLUMN IF NOT EXISTS source_message_id bigint REFERENCES tagg.message(id);
ALTER TABLE tagg.agent_task DROP CONSTRAINT IF EXISTS agent_task_source_message_id_fkey;
ALTER TABLE tagg.agent_task ADD CONSTRAINT agent_task_source_message_id_fkey
    FOREIGN KEY (source_message_id) REFERENCES tagg.message(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS agent_task_conversation_id_idx
    ON tagg.agent_task (conversation_id)
    WHERE conversation_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS agent_task_source_message_id_idx
    ON tagg.agent_task (source_message_id)
    WHERE source_message_id IS NOT NULL;
