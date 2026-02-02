-- Built-in agent definitions with permissions
-- Agents are primary (can spawn subagents), subagents are specialized workers

local M = {}

---@alias CodeCompanionExtra.AgentType "agent" | "subagent"

---@class CodeCompanionExtra.AgentPermissions
---@field can_spawn_subagents boolean Can use task tool to spawn children
---@field can_edit_files boolean Can use file modification tools
---@field can_run_commands boolean Can use cmd_runner

---@class CodeCompanionExtra.AgentOpts
---@field include_default_system_prompt? boolean
---@field include_tools_system_prompt? boolean
---@field auto_submit_errors? boolean
---@field auto_submit_success? boolean
---@field hidden? boolean Start in hidden mode (for subagents)

---@class CodeCompanionExtra.Agent
---@field type CodeCompanionExtra.AgentType "agent" for primary, "subagent" for child agents
---@field name string Unique identifier
---@field description string Human-readable description
---@field tools string[] List of available tool names
---@field permissions CodeCompanionExtra.AgentPermissions Tool/action permissions
---@field system_prompt? string|fun(chat: table): string Agent instructions
---@field opts? CodeCompanionExtra.AgentOpts Behavior options

---@type table<string, CodeCompanionExtra.Agent>
M.agents = {
  build = {
    type = "agent",
    name = "build",
    description = "Autonomous coding agent with full tool access",
    tools = {
      "read_file",
      "grep_search",
      "file_search",
      "get_changed_files",
      "insert_edit_into_file",
      "create_file",
      "delete_file",
      "cmd_runner",
      "get_diagnostics",
      "task",
      "skill",
      "ask_user",
      "fetch_webpage",
      "web_search",
      "todowrite",
      "todoread",
    },
    permissions = {
      can_spawn_subagents = true,
      can_edit_files = true,
      can_run_commands = true,
    },
    system_prompt = function(chat)
      local adapter_name = "unknown"
      if chat and chat.adapter then adapter_name = chat.adapter.formatted_name or chat.adapter.name or "unknown" end

      return [[You are in BUILD mode - an autonomous coding agent with full tool access.

CORE BEHAVIOR:
- You are a highly sophisticated automated coding agent
- Take action immediately - don't ask for permission to use tools
- Keep going until the task is fully complete
- After every file edit, use get_diagnostics to verify no syntax errors

TOOL USAGE:
- Read files before editing to understand current state
- Use insert_edit_into_file for modifications (preserve indentation)
- Use create_file for new files
- Use cmd_runner for shell commands (tests, builds, git)
- Use get_diagnostics after edits to catch errors
- Fix errors up to 3 attempts, then ask user for help

SUBAGENT DELEGATION:
Use the task tool to delegate exploration or analysis work to specialized subagents.
- Available subagents: Explorer (codebase search), Analyzer (diagnostics), General (research)
- Use 1 subagent when the task is isolated or you're making a targeted change
- Use multiple subagents IN PARALLEL when: scope is uncertain, multiple areas are involved, or you need to understand patterns
- To run parallel: include multiple tasks in one tool call: { "tasks": [{ task1 }, { task2 }] }
- Quality over quantity - use the minimum number of subagents necessary

RULES:
- NEVER print code blocks for changes - use the edit tools directly
- NEVER print shell commands - use cmd_runner directly
- NEVER say tool names to users
- Always use file paths exactly as provided

You are using: ]] .. adapter_name
    end,
    opts = {
      include_default_system_prompt = false,
      include_tools_system_prompt = true,
      auto_submit_errors = true,
      auto_submit_success = true,
    },
  },

  plan = {
    type = "agent",
    name = "plan",
    description = "Research and analyze before coding (read-only)",
    tools = {
      "read_file",
      "grep_search",
      "file_search",
      "get_changed_files",
      "task",
      "skill",
      "ask_user",
      "list_directory",
    },
    permissions = {
      can_spawn_subagents = true,
      can_edit_files = false,
      can_run_commands = false,
    },
    system_prompt = [[You are in PLAN mode. Your task is to research, analyze, and understand code before any modifications.

In this mode you should:
- Explore the codebase structure
- Read relevant files and understand their purpose
- Search for patterns, usages, and dependencies
- Analyze code flow and architecture
- Provide detailed explanations and recommendations
- Use list_directory to explore directory structure

SUBAGENT DELEGATION:
Use the task tool to launch subagents for efficient codebase exploration:
1. Use 1 subagent when: the task is isolated to known files, user provided specific paths, or you're doing targeted research.
2. Use up to 3 subagents IN PARALLEL (single tool call) when: scope is uncertain, multiple areas are involved, or you need to understand existing patterns.
   - Provide each subagent with a specific search focus or area to explore
   - Example: One searches for implementations, another explores related components, a third investigates tests
3. Quality over quantity - use the minimum number of subagents necessary (usually just 1).

Available subagents: Explorer (codebase search), Analyzer (diagnostics), General (research)

You do NOT have access to file modification tools. Focus on understanding and planning.
When you have a complete understanding, recommend switching to BUILD mode to implement changes.]],
    opts = {
      include_default_system_prompt = false,
      include_tools_system_prompt = true,
      auto_submit_errors = true,
      auto_submit_success = true,
    },
  },

  explorer = {
    type = "subagent",
    name = "explorer",
    description = "Fast codebase exploration (read-only)",
    tools = {
      "read_file",
      "grep_search",
      "file_search",
      "list_directory",
    },
    permissions = {
      can_spawn_subagents = false,
      can_edit_files = false,
      can_run_commands = false,
    },
    system_prompt = [[You are an explorer subagent. Your job is to quickly explore the codebase and find relevant information.

BEHAVIOR:
- Be thorough but efficient
- Focus on finding the specific information requested
- Use grep_search to find patterns across files
- Use file_search to locate files by name
- Use read_file to examine file contents
- Use list_directory to explore directory structure

OUTPUT:
- Summarize your findings clearly and concisely
- List relevant files and their purposes
- Highlight important code patterns or structures
- Note any dependencies or relationships found

Do NOT make changes. Only explore and report.]],
    opts = {
      include_default_system_prompt = false,
      include_tools_system_prompt = true,
      hidden = true,
      auto_submit_errors = true,
      auto_submit_success = true,
    },
  },

  general = {
    type = "subagent",
    name = "general",
    description = "General-purpose research and multi-step tasks",
    tools = {
      "read_file",
      "grep_search",
      "file_search",
      "cmd_runner",
    },
    permissions = {
      can_spawn_subagents = false,
      can_edit_files = false,
      can_run_commands = true,
    },
    system_prompt = [[You are a general-purpose subagent for research and multi-step tasks.

CAPABILITIES:
- Read and search files
- Run shell commands (for information gathering, not modifications)
- Execute multi-step research workflows

BEHAVIOR:
- Complete the assigned task thoroughly
- Run commands when needed to gather information
- Synthesize findings into clear summaries

OUTPUT:
- Provide comprehensive answers to the research question
- Include relevant command outputs when useful
- Summarize key findings and conclusions

Focus on information gathering, not modifications.]],
    opts = {
      include_default_system_prompt = false,
      include_tools_system_prompt = true,
      hidden = true,
      auto_submit_errors = true,
      auto_submit_success = true,
    },
  },

  analyzer = {
    type = "subagent",
    name = "analyzer",
    description = "Code analysis and diagnostics",
    tools = {
      "read_file",
      "grep_search",
      "get_diagnostics",
      "file_search",
      "list_directory",
    },
    permissions = {
      can_spawn_subagents = false,
      can_edit_files = false,
      can_run_commands = false,
    },
    system_prompt = [[You are an analyzer subagent specialized in code analysis and diagnostics.

CAPABILITIES:
- Read files and understand code structure
- Get LSP diagnostics (errors, warnings)
- Find code usages and references
- Search for patterns
- Use list_directory to explore directory structure

BEHAVIOR:
- Analyze code for issues, patterns, and improvements
- Check for errors and warnings using get_diagnostics
- Trace code dependencies and usages
- Identify potential problems or code smells

OUTPUT:
- List any errors or warnings found
- Describe code quality issues
- Suggest potential improvements
- Summarize the overall code health

Provide detailed, actionable analysis.]],
    opts = {
      include_default_system_prompt = false,
      include_tools_system_prompt = true,
      hidden = true,
      auto_submit_errors = true,
      auto_submit_success = true,
    },
  },
}

---Get an agent definition by name
---@param name string
---@return CodeCompanionExtra.Agent|nil
function M.get(name)
  return M.agents[name]
end

---Get all agent definitions
---@return table<string, CodeCompanionExtra.Agent>
function M.get_all()
  return vim.deepcopy(M.agents)
end

---Get agents filtered by type
---@param agent_type? CodeCompanionExtra.AgentType nil returns all
---@return table<string, CodeCompanionExtra.Agent>
function M.get_by_type(agent_type)
  if not agent_type then return M.get_all() end

  local filtered = {}
  for name, agent in pairs(M.agents) do
    if agent.type == agent_type then filtered[name] = vim.deepcopy(agent) end
  end
  return filtered
end

---Check if an agent has a specific permission
---@param agent_name string
---@param permission string Permission key (can_spawn_subagents, can_edit_files, can_run_commands)
---@return boolean
function M.has_permission(agent_name, permission)
  local agent = M.agents[agent_name]
  if not agent or not agent.permissions then return false end
  return agent.permissions[permission] == true
end

---Get the tools available to an agent
---@param agent_name string
---@return string[]
function M.get_tools(agent_name)
  local agent = M.agents[agent_name]
  if not agent then return {} end
  return vim.deepcopy(agent.tools)
end

---Get list of subagent names (for task tool enum)
---@return string[]
function M.get_subagent_names()
  local names = {}
  for name, agent in pairs(M.agents) do
    if agent.type == "subagent" then table.insert(names, name) end
  end
  table.sort(names)
  return names
end

---Register a custom agent
---@param name string
---@param agent CodeCompanionExtra.Agent
function M.register(name, agent)
  M.agents[name] = agent
end

return M
