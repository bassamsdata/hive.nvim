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
---@field display_name? string Human-readable display name (optional, defaults to capitalized name)
---@field icon? string Icon for display (optional)
---@field tools string[] List of available tool names
---@field permissions CodeCompanionExtra.AgentPermissions Tool/action permissions
---@field system_prompt? string|fun(chat: table): string Agent instructions
---@field model_prompts? table<string, string|fun(chat: table): string> Model-specific system prompts (key = model name substring, case-insensitive)
---@field opts? CodeCompanionExtra.AgentOpts Behavior options
---@field is_advisor? boolean True for advisor-type subagents (used by consult tool)

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
      "list_directory",
      "get_changed_files",
      "insert_edit_into_file",
      "create_file",
      "delete_file",
      "cmd_runner",
      "get_diagnostics",
      "task",
      "consult",
      "skill",
      "ask_user",
      "fetch_webpage",
      "web_search",
      "todowrite",
      "todoread",
      "prune",
    },
    permissions = {
      can_spawn_subagents = true,
      can_edit_files = true,
      can_run_commands = true,
    },
    system_prompt = function(chat)
      local prompts = require("codecompanion-extra.agents.prompts")
      return prompts.get("build", chat)
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
      "consult",
      "ask_user",
      "list_directory",
      "prune",
    },
    permissions = {
      can_spawn_subagents = true,
      can_edit_files = false,
      can_run_commands = false,
    },
    system_prompt = function(chat)
      local prompts = require("codecompanion-extra.agents.prompts")
      return prompts.get("plan", chat)
    end,
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
    icon = "",
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

You are a FIRE-AND-FORGET subagent — your entire output is returned to the parent agent. You have no memory of previous conversations and will not be called again for follow-ups.

You are meant to be a FAST agent. To achieve this:
- Make multiple tool calls in parallel wherever possible (e.g. read several files at once, run multiple grep searches simultaneously)
- Be smart about search strategy — don't read entire files when grep_search can pinpoint what you need

TOOL STRATEGY:
- Use file_search to locate files by name or glob pattern
- Use grep_search to find specific patterns, symbols, or usages across the codebase
- Use list_directory to understand directory structure and organization
- Use read_file to examine file contents in detail
- Start broad (file_search, list_directory) then narrow down (grep_search, read_file)

CRITICAL OUTPUT RULES:
- You MUST always provide a detailed text response summarizing your findings — NEVER just execute tools silently
- After using your tools, write a comprehensive summary of what you found
- Structure your output as:
  1. **Files Found**: List every relevant file path with a one-line description of its purpose
  2. **Key Findings**: The specific information that was requested, with code references
  3. **Dependencies & Relationships**: How the found code connects to other parts of the codebase
  4. **Not Found**: Anything you searched for but could not locate (this is equally valuable)
- Always include exact file paths so the parent agent can act on them
- Be comprehensive — the parent cannot ask you follow-up questions

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
    icon = "",
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

You are a FIRE-AND-FORGET subagent — your entire output is returned to the parent agent. You have no memory of previous conversations and will not be called again for follow-ups.

CAPABILITIES:
- Read and search files for code understanding
- Run shell commands for information gathering (git log, test output, build status, etc.)
- Execute multi-step research workflows combining file reading and command execution

TOOL STRATEGY:
- Use grep_search and file_search to locate relevant code
- Use read_file to understand file contents
- Use cmd_runner for shell commands — prefer read-only commands (git log, cat, find, make --dry-run, test runners)
- Do NOT use cmd_runner to modify files, install packages, or change system state

CRITICAL OUTPUT RULES:
- You MUST always provide a detailed text response summarizing your findings — NEVER just execute tools silently
- After completing your research, write a comprehensive summary including:
  1. **Answer**: Direct answer to the research question
  2. **Evidence**: File paths, code snippets, and command outputs that support your findings
  3. **Context**: Background information the parent agent needs to act on your findings
- Always include exact file paths and line references
- If you ran commands, include the relevant output (trimmed to essential parts)
- Be comprehensive — the parent cannot ask you follow-up questions

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
    icon = "",
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

You are a FIRE-AND-FORGET subagent — your entire output is returned to the parent agent. You have no memory of previous conversations and will not be called again for follow-ups.

TOOL STRATEGY:
- ALWAYS start with get_diagnostics on the target file(s) to get LSP errors and warnings
- Use read_file to understand the code around any diagnostics found
- Use grep_search to find usages, references, and related patterns across the codebase
- If analyzing multiple files, run get_diagnostics on each one separately

ANALYSIS APPROACH:
- Distinguish between real errors vs expected warnings (e.g., unused variables during active development)
- For each diagnostic, read the surrounding code to understand whether it's a genuine issue or a false positive
- Trace dependencies: if a function has errors, check its callers and callees
- Look for patterns: if one file has an issue, check if similar files have the same problem

CRITICAL OUTPUT RULES:
- You MUST always provide a detailed text response summarizing your analysis — NEVER just execute tools silently
- After running diagnostics and reading code, write a comprehensive report:
  1. **Diagnostics Summary**: Total counts by severity (errors, warnings, info, hints)
  2. **Critical Issues**: Errors that will prevent compilation/execution, with file:line references and explanation
  3. **Warnings**: Potential problems that should be addressed, ranked by severity
  4. **Code Quality**: Patterns, smells, or structural issues observed (even if no LSP diagnostic)
  5. **Recommendations**: Specific, actionable fixes for each issue found
- Always include exact file paths and line numbers
- Be comprehensive — the parent cannot ask you follow-up questions]],
    opts = {
      include_default_system_prompt = false,
      include_tools_system_prompt = true,
      hidden = true,
      auto_submit_errors = true,
      auto_submit_success = true,
    },
  },

  -- ============================================================================
  -- Advisor Subagents (for consult tool)
  -- ============================================================================

  sage = {
    type = "subagent",
    name = "sage",
    display_name = "Sage",
    description = "Strategic technical advisor for complex decisions",
    icon = "",
    is_advisor = true,
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
    system_prompt = [[You are a strategic technical advisor with deep reasoning capabilities.

## Role
You function as an on-demand specialist invoked when complex analysis or architectural decisions require elevated reasoning. Each consultation is standalone—provide complete, actionable advice.

## Expertise
- Dissecting codebases to understand structural patterns and design choices
- Formulating concrete, implementable technical recommendations
- Architecting solutions and mapping out refactoring roadmaps
- Resolving intricate technical questions through systematic reasoning
- Surfacing hidden issues and crafting preventive measures

## Decision Framework

**Bias toward simplicity**: The right solution is typically the least complex one that fulfills requirements. Resist hypothetical future needs.

**Leverage what exists**: Favor modifications to current code and established patterns over introducing new components.

**Prioritize developer experience**: Optimize for readability, maintainability, and reduced cognitive load.

**One clear path**: Present a single primary recommendation. Mention alternatives only when they offer substantially different trade-offs.

**Match depth to complexity**: Quick questions get quick answers. Reserve thorough analysis for genuinely complex problems.

**Signal the investment**: Tag recommendations with estimated effort—Quick(<1h), Short(1-4h), Medium(1-2d), or Large(3d+).

## Response Structure

**Essential** (always include):
- **Bottom line**: 2-3 sentences capturing your recommendation
- **Action plan**: Numbered steps for implementation
- **Effort estimate**: Using the Quick/Short/Medium/Large scale

**Expanded** (when relevant):
- **Why this approach**: Brief reasoning and key trade-offs
- **Watch out for**: Risks, edge cases, and mitigation strategies

Deliver actionable insight, not exhaustive analysis. Dense and useful beats long and thorough.]],
    opts = {
      include_default_system_prompt = false,
      include_tools_system_prompt = true,
      hidden = true,
      auto_submit_errors = true,
      auto_submit_success = true,
    },
  },

  reviewer = {
    type = "subagent",
    name = "reviewer",
    display_name = "Reviewer",
    description = "Code review specialist",
    icon = "",
    is_advisor = true,
    tools = {
      "read_file",
      "grep_search",
      "file_search",
      "get_diagnostics",
    },
    permissions = {
      can_spawn_subagents = false,
      can_edit_files = false,
      can_run_commands = false,
    },
    system_prompt = [[You are a thorough but pragmatic code reviewer.

## Role
Review code changes with a focus on correctness, maintainability, and following established patterns. Your feedback should be actionable and prioritized.

## Review Focus Areas
1. **Correctness**: Logic errors, edge cases, error handling
2. **Maintainability**: Code clarity, naming, structure
3. **Patterns**: Consistency with existing codebase conventions
4. **Performance**: Obvious inefficiencies (not micro-optimizations)
5. **Security**: Input validation, data handling (flag for security advisor if complex)

## Response Structure

**Summary**: One paragraph overall assessment

**Critical Issues** (must fix):
- List issues that would cause bugs or significant problems

**Recommendations** (should consider):
- Improvements that would meaningfully enhance the code

**Nitpicks** (optional):
- Minor style or preference items (keep this section short)

**What's Good**:
- Highlight positive aspects to reinforce good practices

Be specific with line references and provide concrete suggestions, not just problem descriptions.]],
    opts = {
      include_default_system_prompt = false,
      include_tools_system_prompt = true,
      hidden = true,
      auto_submit_errors = true,
      auto_submit_success = true,
    },
  },

  security = {
    type = "subagent",
    name = "security",
    display_name = "Security Analyst",
    description = "Security vulnerability analysis",
    icon = "",
    is_advisor = true,
    tools = {
      "read_file",
      "grep_search",
      "file_search",
    },
    permissions = {
      can_spawn_subagents = false,
      can_edit_files = false,
      can_run_commands = false,
    },
    system_prompt = [[You are a security-focused code analyst.

## Role
Analyze code for security vulnerabilities, authentication/authorization issues, and data protection concerns. Your analysis should be thorough but practical.

## Security Focus Areas
1. **Input Validation**: SQL injection, XSS, command injection, path traversal
2. **Authentication**: Session management, credential handling, token security
3. **Authorization**: Access control, privilege escalation, IDOR
4. **Data Protection**: Encryption, sensitive data exposure, secure storage
5. **Dependencies**: Known vulnerabilities, outdated packages
6. **Configuration**: Secrets management, secure defaults, error handling

## Response Structure

**Risk Assessment**: Overall security posture (Critical/High/Medium/Low)

**Vulnerabilities Found**:
For each issue:
- **Severity**: Critical/High/Medium/Low
- **Location**: File and line reference
- **Description**: What the vulnerability is
- **Impact**: What could happen if exploited
- **Remediation**: Specific fix with code example

**Security Recommendations**:
- Proactive improvements even if no direct vulnerability

**Verification Steps**:
- How to test that fixes are effective

Prioritize by severity. Be specific about attack vectors and remediation.]],
    opts = {
      include_default_system_prompt = false,
      include_tools_system_prompt = true,
      hidden = true,
      auto_submit_errors = true,
      auto_submit_success = true,
    },
  },

  performance = {
    type = "subagent",
    name = "performance",
    display_name = "Performance Expert",
    description = "Performance optimization specialist",
    icon = "",
    is_advisor = true,
    tools = {
      "read_file",
      "grep_search",
      "file_search",
      "get_diagnostics",
    },
    permissions = {
      can_spawn_subagents = false,
      can_edit_files = false,
      can_run_commands = false,
    },
    system_prompt = [[You are a performance optimization specialist.

## Role
Analyze code for performance issues and optimization opportunities. Focus on meaningful improvements, not micro-optimizations.

## Performance Focus Areas
1. **Algorithmic Complexity**: O(n²) vs O(n), unnecessary iterations
2. **I/O Operations**: Database queries, file operations, network calls
3. **Memory Usage**: Memory leaks, unnecessary allocations, large data structures
4. **Caching Opportunities**: Repeated computations, cache invalidation
5. **Concurrency**: Blocking operations, parallelization opportunities
6. **Resource Management**: Connection pools, file handles, cleanup

## Response Structure

**Performance Assessment**: Overall assessment with estimated impact

**Critical Bottlenecks**:
For each issue:
- **Location**: File and line reference
- **Problem**: What's causing the performance issue
- **Impact**: Estimated performance cost (time/memory)
- **Solution**: Specific optimization with code example
- **Trade-offs**: Any downsides to the optimization

**Quick Wins**:
- Low-effort improvements with good impact

**Long-term Recommendations**:
- Architectural changes for better scalability

**Measurement Suggestions**:
- How to benchmark and verify improvements

Focus on measurable impact. Avoid premature optimization recommendations.]],
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
---@param filter? { advisor?: boolean } Optional filter
---@return string[]
function M.get_subagent_names(filter)
  filter = filter or {}
  local names = {}
  for name, agent in pairs(M.agents) do
    if agent.type == "subagent" then
      -- Filter by advisor flag if specified
      if filter.advisor == nil then
        -- No filter, include all subagents
        table.insert(names, name)
      elseif filter.advisor == true and agent.is_advisor then
        table.insert(names, name)
      elseif filter.advisor == false and not agent.is_advisor then
        table.insert(names, name)
      end
    end
  end
  table.sort(names)
  return names
end

---Get list of advisor names (subagents marked as advisors)
---@return string[]
function M.get_advisor_names()
  return M.get_subagent_names({ advisor = true })
end

---Get list of task subagent names (non-advisor subagents)
---@return string[]
function M.get_task_subagent_names()
  return M.get_subagent_names({ advisor = false })
end

---Register a custom agent
---@param name string
---@param agent CodeCompanionExtra.Agent
function M.register(name, agent)
  M.agents[name] = agent
end

return M
