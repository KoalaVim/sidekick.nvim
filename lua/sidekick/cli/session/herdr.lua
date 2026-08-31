local Config = require("sidekick.config")
local Util = require("sidekick.util")

---@class sidekick.cli.muxer.Herdr: sidekick.cli.Session
---@field herdr_pane_id string
---@field herdr_embedded? boolean the tool runs in a Neovim terminal, not in a herdr pane
local M = {}
M.__index = M

--- Bracketed paste framing for `pane send-text`, which writes its bytes to the pane tty
--- unmodified. An unframed payload is therefore indistinguishable from typing: a tool with a
--- modal composer runs it through its mode machine, consuming the leading characters as
--- commands and inserting only the remainder. Framing makes it a paste, which an input layer
--- inserts as text regardless of the mode it is in.
local PASTE_START = "\27[200~"
local PASTE_END = "\27[201~"

--- Cap on a single socket round trip. herdr's socket is a local unix socket, so this is a
--- stuck-server backstop rather than an expected wait.
local SOCKET_TIMEOUT = 200 -- ms

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

--- herdr's agent status mapped onto sidekick's. herdr's `done` has no sidekick
--- equivalent: an agent that finished its turn is an idle agent.
-- stylua: ignore
local status_map = {
  idle    = "idle",
  working = "working",
  blocked = "blocked",
  done    = "idle",
  unknown = "unknown",
}

--- Live `pane.agent_status_changed` subscriptions, by pane id.
--- Keyed at module level because `M.sessions()` recreates session objects on every poll.
M._watch = {} ---@type table<string, uv.uv_pipe_t>

--- Last status herdr pushed for a pane.
M._status = {} ---@type table<string, sidekick.cli.session.Status>

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

--- Issue one request against herdr's socket API and wait briefly for its response.
--- `M.watch` streams events and never needs a reply; this is the request/response half.
--- The socket is the only route to methods the CLI does not expose, such as `pane.focus`.
---@param method string
---@param params table
---@return boolean ok whether herdr answered without an error
local function request(method, params)
  local path = vim.env.HERDR_SOCKET_PATH
  if not path then
    return false
  end
  local pipe = vim.uv.new_pipe(false)
  if not pipe then
    return false
  end

  local done, ok = false, false
  local function finish(result)
    if not done then
      done, ok = true, result
    end
    pcall(function()
      pipe:read_stop()
    end)
    if not pipe:is_closing() then
      pipe:close()
    end
  end

  pipe:connect(path, function(err)
    if err then
      return finish(false)
    end
    local buf = ""
    pipe:read_start(function(read_err, data)
      if read_err or not data then
        return finish(false)
      end
      buf = buf .. data
      local line = buf:match("^([^\n]*)\n")
      if not line then
        return -- response not complete yet
      end
      local decoded, msg = pcall(vim.json.decode, line)
      finish(decoded and type(msg) == "table" and msg.error == nil)
    end)
    pipe:write(vim.json.encode({ id = "sidekick:" .. method, method = method, params = params }) .. "\n")
  end)

  -- bounded so focus resolves before the text is sent, without hanging on a stuck server
  vim.wait(SOCKET_TIMEOUT, function()
    return done
  end, 5)
  finish(false)
  return ok
end

function M:init()
  if self.started then
    self.external = self.sid ~= self.mux_session
  else
    -- `terminal` runs the tool in a Neovim terminal and registers it on Neovim's own
    -- pane, so it is the only mode that is not external.
    self.external = vim.env.HERDR_ENV ~= nil and Config.cli.mux.create ~= "terminal"
    self.mux_session = self.sid
  end
  self.status = self.status or (self.herdr_pane_id and M._status[self.herdr_pane_id]) or "unknown"
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
  if self.external then
    return self:start_native()
  end
  return self:start_embedded()
end

--- `create = "terminal"`: the tool runs in a Neovim terminal, exactly like the `terminal`
--- backend runs it. No herdr pane is created, so there is no attach race and no pane gets
--- resized. herdr detects the tool natively on Neovim's own pane -- the full herdr
--- environment (including `HERDR_PANE_ID`) is left intact for the tool -- so sidekick just
--- subscribes to status for that pane instead of registering anything itself.
---@return sidekick.cli.terminal.Cmd?
function M:start_embedded()
  self.herdr_embedded = true
  self.herdr_pane_id = vim.env.HERDR_PANE_ID
  self.status = "idle"
  self.started = true
  M.watch(self.herdr_pane_id)
  return { cmd = self.tool.cmd }
end

--- `create = "split"` / `"window"`: a real herdr pane, detected and driven by herdr
--- itself. Sidekick only stamps the pane as its own and listens for status.
---@return sidekick.cli.terminal.Cmd?
function M:start_native()
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

  -- a pane next to Neovim is only wanted for `split`. `window` gets its own tab.
  if Config.cli.mux.create ~= "split" then
    self:move_to_tab()
  end

  if not Util.exec(self:run_cmd(), { notify = true }) then
    Util.exec({ "herdr", "pane", "close", self.herdr_pane_id }, { notify = false })
    return
  end

  self.id = "herdr:" .. self.herdr_pane_id
  self.started = true

  M.watch(self.herdr_pane_id)

  Util.info(
    ("Started **%s** in a herdr %s"):format(self.tool.name, Config.cli.mux.create == "split" and "split" or "tab")
  )
end

--- Move the pane to a tab of its own, without stealing focus.
--- Pane ids are stable across a move inside the same workspace, so the stored id stays valid.
function M:move_to_tab()
  Util.exec({ "herdr", "pane", "move", self.herdr_pane_id, "--new-tab", "--no-focus" }, { notify = true })
end

--- Subscribe to herdr's `pane.agent_status_changed` for a pane.
--- Best effort: without a subscription the status simply stays where it was.
---@param pane_id string
function M.watch(pane_id)
  local path = vim.env.HERDR_SOCKET_PATH
  if not path or M._watch[pane_id] then
    return
  end
  local pipe = vim.uv.new_pipe(false)
  if not pipe then
    return
  end
  M._watch[pane_id] = pipe

  pipe:connect(path, function(err)
    if err then
      vim.schedule(function()
        Util.debug("herdr: no status events for `" .. pane_id .. "`: " .. err)
      end)
      return M.unwatch(pane_id)
    end
    local req = vim.json.encode({
      id = "sidekick:watch:" .. pane_id,
      method = "events.subscribe",
      params = { subscriptions = { { type = "pane.agent_status_changed", pane_id = pane_id } } },
    })
    pipe:write(req .. "\n")

    local buf = ""
    pipe:read_start(function(read_err, data)
      if read_err or not data then
        return M.unwatch(pane_id)
      end
      buf = buf .. data
      while true do
        local line, rest = buf:match("^([^\n]*)\n(.*)$")
        if not line then
          break
        end
        buf = rest
        local ok, msg = pcall(vim.json.decode, line)
        if ok and type(msg) == "table" and msg.event == "pane.agent_status_changed" then
          local d = type(msg.data) == "table" and msg.data or {}
          M._status[tostring(d.pane_id or pane_id)] = status_map[d.agent_status] or "unknown"
        end
      end
    end)
  end)
end

---@param pane_id string
function M.unwatch(pane_id)
  local pipe = M._watch[pane_id]
  M._watch[pane_id] = nil
  if pipe then
    pcall(function()
      pipe:read_stop()
    end)
    if not pipe:is_closing() then
      pipe:close()
    end
  end
end

--- No `Cmd` is returned: an embedded session's tool ran in a Neovim terminal that is now
--- gone, and a native session lives in a herdr pane that sidekick drives over the pane API.
---@return sidekick.cli.terminal.Cmd?
function M:attach()
  if self.herdr_pane_id then
    M.watch(self.herdr_pane_id) -- keep status flowing for a rediscovered session
  end
end

--- Give the pane's status watch back to herdr. herdr keeps managing the agent lifecycle
--- itself, so there is nothing else to tear down.
function M:detach()
  if self.herdr_pane_id then
    M.unwatch(self.herdr_pane_id)
  end
end

--- Bring the session's pane in front of the user. Best effort: a failure is silent, so it
--- never raises a notification on every send.
---
--- `pane.focus` and not `herdr agent focus`: the latter resolves against herdr's agent
--- registry, which reports a freshly started tool only after ~600ms (measured), so it would
--- miss the very send that creates the session and work on every one after it. Targeting the
--- pane has nothing to detect, and also covers a tool herdr never sees as an agent.
function M:focus()
  if self.herdr_embedded or not self.herdr_pane_id then
    -- the tool runs in a Neovim terminal, which the terminal window focuses itself, and
    -- Neovim's own pane is already where the user is
    return
  end
  if request("pane.focus", { pane_id = self.herdr_pane_id }) then
    return
  end
  -- no socket in the environment: the CLI resolves herdr's socket on its own, at the cost of
  -- resolving through the agent registry again
  Util.exec({ "herdr", "agent", "focus", self.herdr_pane_id }, { notify = false })
end

function M:send(text)
  if self.herdr_embedded then
    return -- the tool runs in a Neovim terminal; sending here would type into Neovim
  end
  -- the trailing newline stays inside the framing, so it is a newline in the input
  -- rather than a submit. `submit()` is what sends Enter.
  Util.exec({ "herdr", "pane", "send-text", self.herdr_pane_id, PASTE_START .. text .. PASTE_END })
end

function M:submit()
  if self.herdr_embedded then
    return
  end
  Util.exec({ "herdr", "pane", "send-keys", self.herdr_pane_id, "Enter" })
end

function M:is_running()
  if not self.herdr_pane_id then
    return false
  end
  return Util.exec({ "herdr", "pane", "get", self.herdr_pane_id }, { notify = false }) ~= nil
end

function M:dump()
  if not self.herdr_pane_id or self.herdr_embedded then
    return -- an embedded tool's output is in the Neovim terminal, not in the pane
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

  local nvim_pane = vim.env.HERDR_PANE_ID
  local ret = {} ---@type sidekick.cli.session.State[]
  for _, agent in ipairs(agents) do
    local pane_id = tostring(agent.pane_id)
    local status = status_map[agent.agent_status] or "unknown"
    M._status[pane_id] = status

    if pane_id == nvim_pane then
      -- Neovim's own pane. Herdr detects the embedded tool natively, but that session
      -- is already managed by the terminal backend — skip it to avoid a duplicate entry.
    else
      local tool_name = kind_to_tool[agent.agent]
      if tool_name then
        ret[#ret + 1] = {
          id = "herdr:" .. pane_id,
          cwd = agent.cwd or "",
          tool = tool_name,
          herdr_pane_id = pane_id,
          -- `mux_session` names the pane rather than matching `sid` -- `init()` reads
          -- `sid ~= mux_session` as "external", and a per-pane name is also unique,
          -- which the bare tool name was not.
          mux_session = "herdr:" .. pane_id,
          status = status,
          pids = {},
        }
      end
    end
  end

  return ret
end

return M
