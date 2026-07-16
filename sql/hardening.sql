-- Run-scoped agent identity and retry bookkeeping.
SET search_path TO tagg, pg_catalog, pg_temp;

ALTER TABLE tagg.agent_task
  ADD COLUMN IF NOT EXISTS attempt_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS max_attempts integer NOT NULL DEFAULT 3,
  ADD COLUMN IF NOT EXISTS last_error text,
  ADD COLUMN IF NOT EXISTS failed_at timestamptz;
ALTER TABLE tagg.agent_task DROP CONSTRAINT IF EXISTS agent_task_attempts_check;
ALTER TABLE tagg.agent_task ADD CONSTRAINT agent_task_attempts_check CHECK (attempt_count >= 0 AND max_attempts > 0);

CREATE TABLE IF NOT EXISTS tagg.agent_run (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  task_id bigint NOT NULL REFERENCES tagg.agent_task(id),
  agent_user_id bigint NOT NULL REFERENCES tagg.user(id),
  conversation_id bigint REFERENCES tagg.conversation(id),
  token_hash text NOT NULL UNIQUE,
  status text NOT NULL DEFAULT 'running' CHECK (status IN ('running','completed','failed','abandoned')),
  started_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  finished_at timestamptz, exit_code integer, error_text text,
  expires_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP + interval '30 minutes'
);

CREATE OR REPLACE FUNCTION tagg.start_agent_run(p_task bigint,p_agent bigint,p_token text,p_conversation bigint DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg','pg_catalog','pg_temp' AS $$
DECLARE v_id bigint; BEGIN
  IF length(p_token)<32 THEN RAISE EXCEPTION 'Run token is too short'; END IF;
  INSERT INTO tagg.agent_run(task_id,agent_user_id,conversation_id,token_hash) VALUES(p_task,p_agent,p_conversation,md5(p_token)) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION tagg.set_agent_run_context(p_token text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg','pg_catalog','pg_temp' AS $$
DECLARE v_run tagg.agent_run%ROWTYPE; BEGIN
  SELECT * INTO v_run FROM tagg.agent_run WHERE token_hash=md5(p_token) AND status='running' AND expires_at>CURRENT_TIMESTAMP;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invalid, expired, or closed agent run'; END IF;
  PERFORM set_config('tagg.agent_id',v_run.agent_user_id::text,false);
  PERFORM set_config('tagg.agent_run_id',v_run.id::text,false); RETURN v_run.agent_user_id;
END $$;

CREATE OR REPLACE FUNCTION tagg.finish_agent_run(p_run bigint,p_exit integer,p_error text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg','pg_catalog','pg_temp' AS $$
DECLARE v tagg.agent_run%ROWTYPE; BEGIN
  SELECT * INTO v FROM tagg.agent_run WHERE id=p_run FOR UPDATE; IF NOT FOUND OR v.status<>'running' THEN RETURN; END IF;
  UPDATE tagg.agent_run SET finished_at=CURRENT_TIMESTAMP,exit_code=p_exit,error_text=p_error,status=CASE WHEN p_exit=0 THEN 'completed' ELSE 'failed' END WHERE id=p_run;
  IF p_exit<>0 THEN UPDATE tagg.agent_task SET attempt_count=attempt_count+1,last_error=COALESCE(p_error,format('agent exited with code %s',p_exit)),failed_at=CASE WHEN attempt_count+1>=max_attempts THEN CURRENT_TIMESTAMP ELSE NULL END,task_status_id=CASE WHEN attempt_count+1>=max_attempts THEN 5 ELSE 1 END WHERE id=v.task_id AND task_status_id IN (2,3); END IF;
END $$;

CREATE OR REPLACE FUNCTION tagg.advance_workflow(p_task_id bigint)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg','pg_catalog','pg_temp' AS $$
DECLARE v_agent bigint; v_workflow bigint; v_current bigint; v_next bigint; BEGIN
  PERFORM tagg.require_permission('task:advance'); v_agent:=current_setting('tagg.agent_id')::bigint;
  SELECT workflow_id,task_status_id INTO v_workflow,v_current FROM tagg.agent_task WHERE id=p_task_id AND to_user_id=v_agent AND is_active FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Task % is not assigned to this agent',p_task_id; END IF;
  SELECT ws.task_status_id INTO v_next FROM tagg.workflow_step ws JOIN tagg.workflow_step cur ON cur.workflow_id=ws.workflow_id AND cur.task_status_id=v_current WHERE ws.workflow_id=v_workflow AND ws.seq_num>cur.seq_num AND ws.is_active AND cur.is_active ORDER BY ws.seq_num LIMIT 1;
  IF v_next IS NULL THEN RETURN NULL; END IF; UPDATE tagg.agent_task SET task_status_id=v_next WHERE id=p_task_id; RETURN v_next;
END $$;

CREATE OR REPLACE FUNCTION tagg.agent_task_add(p_from_user_id bigint,p_to_user_id bigint,p_task text,p_project_id bigint,p_parent_id bigint DEFAULT NULL,p_workflow_id bigint DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg','pg_catalog','pg_temp' AS $$
DECLARE v_id bigint; v_agent bigint; BEGIN
  v_agent:=current_setting('tagg.agent_id')::bigint;
  IF p_from_user_id<>v_agent THEN RAISE EXCEPTION 'Agents may only create tasks as themselves'; END IF;
  PERFORM tagg.require_permission('task:create');
  IF p_from_user_id=p_to_user_id THEN PERFORM tagg.require_permission('task:assign:self'); ELSE PERFORM tagg.require_permission('task:assign:any'); END IF;
  INSERT INTO tagg.agent_task(from_user_id,to_user_id,task,project_id,parent_id,workflow_id) VALUES(p_from_user_id,p_to_user_id,p_task,p_project_id,p_parent_id,COALESCE(p_workflow_id,(SELECT id FROM tagg.workflow WHERE name='standard'))) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION tagg.artifact_add(p_agent_task_id bigint,p_name varchar(50),p_descr varchar(400),p_artifact_type varchar(50),p_body text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg','pg_catalog','pg_temp' AS $$
DECLARE v_id bigint; v_agent bigint; BEGIN
  PERFORM tagg.require_permission('artifact:create'); v_agent:=current_setting('tagg.agent_id')::bigint;
  IF NOT EXISTS(SELECT 1 FROM tagg.agent_task WHERE id=p_agent_task_id AND to_user_id=v_agent AND is_active) THEN RAISE EXCEPTION 'Task % is not assigned to this agent',p_agent_task_id; END IF;
  INSERT INTO tagg.artifact(agent_task_id,name,descr,artifact_type,body) VALUES(p_agent_task_id,p_name,p_descr,p_artifact_type,p_body) RETURNING id INTO v_id; RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION tagg.notify_task_ready()
RETURNS trigger LANGUAGE plpgsql SET search_path TO 'tagg','pg_catalog','pg_temp' AS $$
BEGIN
  IF NEW.is_active AND NEW.task_status_id = 1
     AND (TG_OP = 'INSERT' OR OLD.task_status_id IS DISTINCT FROM 1) THEN
    PERFORM pg_notify('tagg_task_ready', NEW.id::text);
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS task_ready_notification ON tagg.agent_task;
CREATE TRIGGER task_ready_notification
AFTER INSERT OR UPDATE OF task_status_id ON tagg.agent_task
FOR EACH ROW EXECUTE FUNCTION tagg.notify_task_ready();

REVOKE EXECUTE ON FUNCTION tagg.set_agent_id(bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION tagg.set_agent_run_context(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION tagg.start_agent_run(bigint,bigint,text,bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION tagg.finish_agent_run(bigint,integer,text) FROM PUBLIC;
RESET search_path;
