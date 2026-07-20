-- Legacy manual example. Resolve current agent/project IDs by name and create
-- tasks through a valid run-token context; do not rely on these hard-coded IDs.
SELECT tagg.set_agent_id(8);
SELECT tagg.agent_task_add(
  8,   -- from_user_id (Conductor)
  9,   -- to_user_id (Coder)
  'Build a TUI program in C that writes letters of the alphabet (A-Z) one at a time to stdout. Each time the user presses the spacebar, the next letter is printed. When Z is reached, stop and print a newline.

Implementation requirements:
- Use raw terminal mode (tcgetattr/tcsetattr) to read keystrokes without Enter
- Print the current letter, wait for spacebar, then advance to next letter
- Store the source code as an artifact of type "code"
- Store a build/run summary as an artifact of type "summary"
- Store any design notes as an artifact of type "plan"
- Use the project_id from the env var or id=5',
  5,   -- project_id
  NULL,  -- parent_id
  NULL   -- workflow_id (defaults to standard)
);
