-- Generic entities and tags shared by projects, tasks, artifacts, and conversations.
SET search_path TO tagg, pg_catalog, pg_temp;

CREATE TABLE IF NOT EXISTS tagg.artifact_type (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name varchar(50) NOT NULL UNIQUE,
  descr varchar(400) NOT NULL, created timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, is_active boolean NOT NULL DEFAULT true
);
CREATE TABLE IF NOT EXISTS tagg.file (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, file_ext varchar(10) NOT NULL,
  name varchar(50) NOT NULL, descr varchar(400) NOT NULL, body bytea,
  created timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, updated timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  is_active boolean NOT NULL DEFAULT true
);
CREATE TABLE IF NOT EXISTS tagg.note (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name varchar(50) NOT NULL,
  descr varchar(400) NOT NULL, body text NOT NULL,
  created timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, updated timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  is_active boolean NOT NULL DEFAULT true
);
CREATE TABLE IF NOT EXISTS tagg.obj_type (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name varchar(50) NOT NULL UNIQUE,
  descr varchar(400) NOT NULL, created timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, is_active boolean NOT NULL DEFAULT true
);
CREATE TABLE IF NOT EXISTS tagg.object (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, obj_type_id bigint NOT NULL REFERENCES tagg.obj_type(id),
  name varchar(50) NOT NULL, descr varchar(400) NOT NULL, body jsonb,
  created timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, updated timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  is_active boolean NOT NULL DEFAULT true
);
CREATE TABLE IF NOT EXISTS tagg.tag (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name varchar(50) NOT NULL UNIQUE,
  descr varchar(400) NOT NULL, created timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, is_active boolean NOT NULL DEFAULT true
);

CREATE TABLE IF NOT EXISTS tagg.tag_project_crosswalk (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, tag_id bigint NOT NULL REFERENCES tagg.tag(id), project_id bigint NOT NULL REFERENCES tagg.project(id), created timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, updated timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, is_active boolean NOT NULL DEFAULT true, UNIQUE(tag_id,project_id));
CREATE TABLE IF NOT EXISTS tagg.tag_file_crosswalk (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, tag_id bigint NOT NULL REFERENCES tagg.tag(id), file_id bigint NOT NULL REFERENCES tagg.file(id), created timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, updated timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, is_active boolean NOT NULL DEFAULT true, UNIQUE(tag_id,file_id));
CREATE TABLE IF NOT EXISTS tagg.tag_note_crosswalk (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, tag_id bigint NOT NULL REFERENCES tagg.tag(id), note_id bigint NOT NULL REFERENCES tagg.note(id), created timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, updated timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, is_active boolean NOT NULL DEFAULT true, UNIQUE(tag_id,note_id));
CREATE TABLE IF NOT EXISTS tagg.tag_object_crosswalk (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, tag_id bigint NOT NULL REFERENCES tagg.tag(id), object_id bigint NOT NULL REFERENCES tagg.object(id), created timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, updated timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, is_active boolean NOT NULL DEFAULT true, UNIQUE(tag_id,object_id));
CREATE TABLE IF NOT EXISTS tagg.tag_conversation_crosswalk (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, tag_id bigint NOT NULL REFERENCES tagg.tag(id), conversation_id bigint NOT NULL REFERENCES tagg.conversation(id), created timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, updated timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, is_active boolean NOT NULL DEFAULT true, UNIQUE(tag_id,conversation_id));
CREATE TABLE IF NOT EXISTS tagg.tag_message_crosswalk (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, tag_id bigint NOT NULL REFERENCES tagg.tag(id), message_id bigint NOT NULL REFERENCES tagg.message(id), created timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, updated timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, is_active boolean NOT NULL DEFAULT true, UNIQUE(tag_id,message_id));
CREATE TABLE IF NOT EXISTS tagg.tag_agent_task_crosswalk (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, tag_id bigint NOT NULL REFERENCES tagg.tag(id), agent_task_id bigint NOT NULL REFERENCES tagg.agent_task(id), created timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, updated timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, is_active boolean NOT NULL DEFAULT true, UNIQUE(tag_id,agent_task_id));
CREATE TABLE IF NOT EXISTS tagg.tag_artifact_crosswalk (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, tag_id bigint NOT NULL REFERENCES tagg.tag(id), artifact_id bigint NOT NULL REFERENCES tagg.artifact(id), created timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, updated timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, is_active boolean NOT NULL DEFAULT true, UNIQUE(tag_id,artifact_id));

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['artifact_type','file','note','obj_type','object','tag','tag_project_crosswalk','tag_file_crosswalk','tag_note_crosswalk','tag_object_crosswalk','tag_conversation_crosswalk','tag_message_crosswalk','tag_agent_task_crosswalk','tag_artifact_crosswalk'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS set_timestamp ON tagg.%I', t);
    EXECUTE format('CREATE TRIGGER set_timestamp BEFORE INSERT OR UPDATE ON tagg.%I FOR EACH ROW EXECUTE FUNCTION tagg.trigger_update_timestamp()', t);
  END LOOP;
END $$;

RESET search_path;
