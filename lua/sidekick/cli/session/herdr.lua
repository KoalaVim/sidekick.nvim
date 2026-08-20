local Config = require("sidekick.config")
local Util = require("sidekick.util")

---@class sidekick.cli.muxer.Herdr: sidekick.cli.Session
---@field herdr_pane_id string
local M = {}
M.__index = M

-- Maps tool names to the agent kinds herdr detects natively.
-- Only used to resolve agents reported by `herdr agent list` back to a tool.
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

--- Extract a pane id from a `herdr pane split` response.
--- Results are wrapped as `{id, result = {type = "pane_info", pane = {pane_id}}}`
---@param raw string
---@return string?
local function parse_pane_id(raw)
  local ok, data = pcall(vim.json.decode, raw)
  if not ok or type(data) ~= "table" then
    return nil
  end
  local result = type(data.result) == "table" and data.result or data
  local pane = type(result.pane) == "table" and result.pane or result
  return pane.pane_id and tostring(pane.pane_id) or nil
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

--- The command that starts the tool in the pane.
--- Unlike the other backends, the pane is spawned by the herdr server instead of Neovim,
--- so nothing is inherited from the terminal job and the env has to be set on exec.
--- Setting it on the pane itself is not enough, since shell startup files run after that.
---@return string[]
function M:run_cmd()
  ---@type table<string, string|false>
  local env = { NVIM = vim.v.servername }
  local editor_proxy = vim.api.nvim_get_runtime_file("bin/sidekick-editor-proxy", false)[1]
  if editor_proxy then
    env.EDITOR = editor_proxy
    env.VISUAL = editor_proxy
  end
  env = vim.tbl_extend("force", env, self.tool.config.env or {}, self.tool.env or {})

  -- `pane run` joins its arguments into a command line for the pane's shell,
  -- so anything that ends up there needs to be quoted.
  -- `exec` replaces the shell, so the pane closes as soon as the tool exits.
  local ret = { "herdr", "pane", "run", self.herdr_pane_id, "exec", "env" }
  for key, value in pairs(env) do
    if value == false then
      vim.list_extend(ret, { "-u", key })
    else
      ret[#ret + 1] = vim.fn.shellescape(("%s=%s"):format(key, tostring(value)))
    end
  end
  for _, arg in ipairs(self.tool.cmd) do
    ret[#ret + 1] = vim.fn.shellescape(arg)
  end
  return ret
end

---@return sidekick.cli.terminal.Cmd?
function M:start()
  local split_cmd = { "herdr", "pane", "split" }
  -- split the pane running Neovim, not whatever pane happens to be focused
  if vim.env.HERDR_PANE_ID then
    vim.list_extend(split_cmd, { "--pane", vim.env.HERDR_PANE_ID })
  end
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

  local pane_id = parse_pane_id(raw)
  if not pane_id then
    Util.error(("Failed to get pane_id from herdr pane split:\n%s"):format(raw))
    return
  end
  self.herdr_pane_id = pane_id

  -- a pane next to Neovim is only wanted for `split`. `terminal` shows the tool in a
  -- Neovim terminal, so the pane is moved out of sight, and `window` gets its own tab
  if Config.cli.mux.create ~= "split" then
    self:move_to_tab()
  end

  if not Util.exec(self:run_cmd(), { notify = true }) then
    Util.exec({ "herdr", "pane", "close", self.herdr_pane_id }, { notify = false })
    return
  end

  self.id = "herdr:" .. self.herdr_pane_id
  self.started = true

  if not self.external then
    return { cmd = { "herdr", "agent", "attach", self.herdr_pane_id } }
  end

  Util.info(
    ("Started **%s** in a herdr %s"):format(self.tool.name, Config.cli.mux.create == "split" and "split" or "tab")
  )
end

--- Move the pane to a tab of its own, keeping the focus where it is
function M:move_to_tab()
  if not Util.exec({ "herdr", "pane", "move", self.herdr_pane_id, "--new-tab" }, { notify = true }) then
    return
  end
  -- `pane move --new-tab` focuses the tab it created
  if vim.env.HERDR_TAB_ID then
    Util.exec({ "herdr", "tab", "focus", vim.env.HERDR_TAB_ID }, { notify = false })
  end
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
  if not self.herdr_pane_id then
    return false
  end
  -- the tool replaced the pane's shell, so the pane lives exactly as long as the tool
  return Util.exec({ "herdr", "pane", "get", self.herdr_pane_id }, { notify = false }) ~= nil
end

function M:dump()
  if not self.herdr_pane_id then
    return
  end
  -- stylua: ignore
  local _, raw = Util.exec({
    "herdr", "pane", "read", self.herdr_pane_id,
    "--source", "recent",
    "--lines", tostring(Config.cli.mux.dump),
    "--ansi",
  }, { notify = false })
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

  local kind_to_tool = {} ---@type table<string, string>
  for name in pairs(Config.tools()) do
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
        mux_session = tool_name,
        pids = {},
      }
    end
  end

  return ret
end

return M
