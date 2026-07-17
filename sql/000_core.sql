-- Minimal base schema for a new Task Train database.
CREATE SCHEMA IF NOT EXISTS tagg;
SET search_path TO tagg, pg_catalog, pg_temp;

CREATE OR REPLACE FUNCTION tagg.trigger_update_timestamp() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated = CURRENT_TIMESTAMP; RETURN NEW; END $$;

CREATE TABLE tagg.user (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name varchar(50) NOT NULL UNIQUE,
  descr varchar(400) NOT NULL DEFAULT '', is_agent boolean NOT NULL DEFAULT false,
  is_active boolean NOT NULL DEFAULT true, created timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE tagg.project (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name varchar(50) NOT NULL UNIQUE,
  descr varchar(400) NOT NULL DEFAULT '', created_by_id bigint REFERENCES tagg.user(id),
  is_active boolean NOT NULL DEFAULT true, created timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE tagg.task_status (id bigint PRIMARY KEY, name varchar(50) NOT NULL UNIQUE);
INSERT INTO tagg.task_status(id,name) VALUES
  (1,'pending'),(2,'reserved'),(3,'in_progress'),(4,'completed'),(5,'tested'),(6,'validated'),(7,'failed'),(8,'cancelled');
CREATE TABLE tagg.agent_task (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, from_user_id bigint NOT NULL REFERENCES tagg.user(id),
  to_user_id bigint NOT NULL REFERENCES tagg.user(id), parent_id bigint REFERENCES tagg.agent_task(id),
  task text NOT NULL, seq_num integer NOT NULL DEFAULT 1, project_id bigint NOT NULL REFERENCES tagg.project(id),
  task_status_id bigint NOT NULL DEFAULT 1 REFERENCES tagg.task_status(id), is_active boolean NOT NULL DEFAULT true,
  created timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, updated timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE tagg.conversation (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, title varchar(200) NOT NULL,
  original_theme text NOT NULL, project_id bigint NOT NULL REFERENCES tagg.project(id),
  is_active boolean NOT NULL DEFAULT true, created timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE tagg.message (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, conversation_id bigint NOT NULL REFERENCES tagg.conversation(id),
  parent_id bigint REFERENCES tagg.message(id), seq_num integer NOT NULL DEFAULT 1, message text NOT NULL,
  from_user bigint NOT NULL REFERENCES tagg.user(id), to_user bigint NOT NULL REFERENCES tagg.user(id),
  original_theme_alignment real NOT NULL DEFAULT 0, is_active boolean NOT NULL DEFAULT true,
  created timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, updated timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE tagg.message_agent_task_crosswalk (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, message_id bigint NOT NULL REFERENCES tagg.message(id),
  agent_task_id bigint NOT NULL REFERENCES tagg.agent_task(id), UNIQUE(message_id,agent_task_id)
);
CREATE TABLE tagg.artifact (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, agent_task_id bigint NOT NULL REFERENCES tagg.agent_task(id), name varchar(50) NOT NULL, descr varchar(400) NOT NULL, artifact_type varchar(50) NOT NULL, body text, created timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE tagg.operation_type (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name varchar(50) NOT NULL UNIQUE, descr varchar(400) NOT NULL DEFAULT '');
CREATE TABLE tagg.operation_log (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, operation_type_id bigint, object_type text, object_id bigint, created timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE tagg.error_log (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, operation text, error_message text, error_code text, details jsonb, created timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE OR REPLACE FUNCTION tagg.log_operation(p_object_type text,p_object_id bigint,p_operation text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN RETURN; END $$;
CREATE OR REPLACE FUNCTION tagg.log_error(p_operation text,p_message text,p_code text,p_details jsonb) RETURNS void LANGUAGE plpgsql AS $$ BEGIN RETURN; END $$;
CREATE OR REPLACE FUNCTION tagg.assert_valid_entity(p_table_name text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN RETURN; END $$;
INSERT INTO tagg.user(name,descr,is_agent) VALUES ('local-user','Default local user',false);
INSERT INTO tagg.user(name,descr,is_agent) VALUES ('Admin-Agent','Administrative configuration agent',true);
INSERT INTO tagg.project(name,descr,created_by_id) VALUES ('default','Default local project',(SELECT id FROM tagg.user WHERE name='local-user'));
