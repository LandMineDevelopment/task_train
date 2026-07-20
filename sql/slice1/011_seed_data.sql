-- Slice 1: Phase 10 — Seed Data

-- 10.1 Standard object types
insert into taxonomy.object_types (object_type, native_schema, native_table, display_name, taggable, relatable, searchable) values
    ('user',       'identity', 'users',              'User',       false, true,  true),
    ('project',    'project',  'projects',            'Project',    true,  true,  true),
    ('task',       'external', 'external_tasks',      'Task',       true,  true,  true),
    ('message',    'external', 'external_messages',   'Message',    true,  true,  true),
    ('document',   'external', 'external_documents',  'Document',   true,  true,  true),
    ('agent',      'external', 'external_agents',     'Agent',      true,  true,  true),
    ('agent_session', 'external', 'external_agent_sessions', 'Agent Session', true, true, true),
    ('tool_call',  'external', 'external_tool_calls', 'Tool Call',  true,  false, true),
    ('tool_def',   'external', 'external_tool_defs',  'Tool Definition', true, true, true),
    ('workflow',   'external', 'external_workflows',  'Workflow',   true,  true,  true),
    ('workflow_run', 'external', 'external_workflow_runs', 'Workflow Run', true, true, true),
    ('event',      'external', 'external_events',     'Event',      true,  true,  true),
    ('note',       'external', 'external_notes',      'Note',       true,  true,  true),
    ('tag',        'taxonomy', 'tags',                'Tag',        false, true,  true),
    ('relationship', 'taxonomy', 'object_relationships', 'Relationship', false, false, false),
    ('file',       'storage',  'storage_files',       'File',       true,  true,  true),
    ('collection', 'external', 'external_collections','Collection', true,  true,  true),
    ('template',   'external', 'external_templates',  'Template',   true,  true,  true);

-- 10.2 Standard relationship types
insert into taxonomy.relationship_types (relationship_type, display_name, inverse_type, is_symmetric) values
    ('member_of',  'Member Of',  'has_member',  false),
    ('has_member', 'Has Member', 'member_of',   false),
    ('depends_on', 'Depends On', 'depended_by', false),
    ('depended_by','Depended By','depends_on',  false),
    ('assigned_to','Assigned To','assigned_by', false),
    ('assigned_by','Assigned By','assigned_to', false),
    ('created_by', 'Created By', 'creator_of',  false),
    ('creator_of', 'Creator Of', 'created_by',  false),
    ('relates_to', 'Relates To', 'referenced_by', false),
    ('referenced_by','Referenced By','relates_to', false),
    ('contains',   'Contains',   'contained_in', false),
    ('contained_in','Contained In','contains',  false),
    ('parent_of',  'Parent Of',  'child_of',    false),
    ('child_of',   'Child Of',   'parent_of',   false),
    ('sibling_of', 'Sibling Of', null,          true),
    ('related_to', 'Related To', null,          true);
