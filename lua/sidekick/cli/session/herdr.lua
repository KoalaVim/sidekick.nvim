local Config = require("sidekick.config")
local Util = require("sidekick.util")

---@class sidekick.cli.muxer.Herdr: sidekick.cli.Session
---@field herdr_pane_id string
---@field herdr_agent_target string
local M = {}
M.__index = M

-- stylua: ignore
local tool_to_kind = {
  claude   = "claude",
  codex    = "codex",
  cursor   = "cursor",
  pi       = "pi",
  gemini   = "gemini",
  copilot  = "copilot",
  grok     = "grok",
  opencode = "opencode",
  qwen     = "qwen",
}

---@param tool_name string
---@return string?
local function get_kind(tool_name)
  return tool_to_kind[tool_name]
end

---@param raw string
---@return table[]?
local function parse_agent_list(raw)
  local ok, data = pcall(vim.json.decode, raw)
  if not ok or type(data) ~= "table" then
    return nil
  end
  local result = data.result
  if type(result) == "table" and type(result.agents) == "table" then
    return result.agents
  end
  return nil
end

function M:init()
  if self.started then
    self.external = self.sid ~= self.mux_session
  else
    self.external = vim.env.HERDR_ENV and Config.cli.mux.create ~= "terminal"
    self.mux_session = self.sid
  end
  self.priority = self.external and 10 or 50
end

---@return sidekick.cli.terminal.Cmd?
function M:start()
  local kind = get_kind(self.tool.name)
  if not kind then
    Util.error(("Tool **%s** is not supported by the herdr backend (no kind mapping)"):format(self.tool.name))
    return
  end

  local split_cmd = { "herdr", "pane", "split" }
  local direction = Config.cli.mux.split.vertical and "right" or "down"
  vim.list_extend(split_cmd, { "--direction", direction })
  local size = Config.cli.mux.split.size
  if size and size > 0 and size <= 1 then
    vim.list_extend(split_cmd, { "--ratio", tostring(size) })
  end
  vim.list_extend(split_cmd, { "--cwd", self.cwd })

  local _, raw = Util.exec(split_cmd, { notify = true })
  if not raw then
    return
  end

  local ok, split_result = pcall(vim.json.decode, raw)
  if not ok or type(split_result) ~= "table" then
    Util.error("Failed to parse herdr pane split output")
    return
  end
  -- pane split wraps in {id, result: {pane_id}}
  local pane_id = split_result.result and split_result.result.pane_id or split_result.pane_id
  if not pane_id then
    Util.error("Failed to get pane_id from herdr pane split")
    return
  end

  self.herdr_pane_id = tostring(pane_id)

  local start_cmd = { "herdr", "agent", "start", self.tool.name, "--kind", kind, "--pane", self.herdr_pane_id }

  local start_lines = Util.exec(start_cmd, { notify = true })
  if not start_lines then
    return
  end

  self.herdr_agent_target = self.herdr_pane_id
  self.id = "herdr:" .. self.herdr_pane_id
  self.started = true

  if not self.external then
    return { cmd = { "herdr", "agent", "attach", self.herdr_pane_id } }
  end

  Util.info(("Started **%s** in a herdr pane"):format(self.tool.name))
end

function M:send(text)
  Util.exec({ "herdr", "pane", "send-text", self.herdr_pane_id, text })
end

function M:submit()
  Util.exec({ "herdr", "pane", "send-keys", self.herdr_pane_id, "Enter" })
end

---@return sidekick.cli.terminal.Cmd?
function M:attach()
  if self.sid == self.mux_session then
    return { cmd = { "herdr", "agent", "attach", self.herdr_pane_id } }
  end
end

function M:detach() end

function M:is_running()
  local _, raw = Util.exec({ "herdr", "agent", "list" }, { notify = false })
  if not raw then
    return false
  end
  local agents = parse_agent_list(raw)
  if not agents then
    return false
  end
  for _, agent in ipairs(agents) do
    if tostring(agent.pane_id) == self.herdr_pane_id then
      return true
    end
  end
  return false
end

function M:dump()
  if not self.herdr_agent_target then
    return
  end
  local _, raw = Util.exec(
    { "herdr", "agent", "read", self.herdr_agent_target, "--source", "recent", "--ansi" },
    { notify = false }
  )
  return raw
end

function M.sessions()
  local _, raw = Util.exec({ "herdr", "agent", "list" }, { notify = false })
  if not raw then
    return {}
  end
  local agents = parse_agent_list(raw)
  if not agents then
    return {}
  end

  local tools = Config.tools()
  local kind_to_tool = {}
  for name, _ in pairs(tools) do
    local kind = get_kind(name)
    if kind then
      kind_to_tool[kind] = name
    end
  end

  local ret = {} ---@type sidekick.cli.session.State[]
  for _, agent in ipairs(agents) do
    local tool_name = kind_to_tool[agent.agent]
    if tool_name then
      local pane_id = tostring(agent.pane_id)
      ret[#ret + 1] = {
        id = "herdr:" .. pane_id,
        cwd = agent.cwd or "",
        tool = tool_name,
        herdr_pane_id = pane_id,
        herdr_agent_target = pane_id,
        mux_session = tool_name,
        pids = {},
      }
    end
  end

  return ret
end

return M
