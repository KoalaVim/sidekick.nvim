local Config = require("sidekick.config")
local Util = require("sidekick.util")

---@class sidekick.cli.muxer.Rex: sidekick.cli.Session
---@field rex_session_id string
---@field rex_block_id string
---@field rex_pid number
local M = {}
M.__index = M
M.priority = 10
M.external = true

--- Never start a Rex server just to look for sessions.
--- Every call blocks Neovim, so a stuck server fails fast instead of after rex's 10s default.
local REX = { "rex", "--autostart=false", "--timeout=200ms" }

--- Lists every terminal block with its child pid in one round trip.
--- A script only hears sessions it attached to, so it attaches to each one first.
--- With `block_id` set, only that block is described.
local PANES_SCRIPT = [[
local ret = {}
local sessions = rex.call("session.list") or {}
for _, s in ipairs(sessions.sessions or {}) do
  rex.call("session.attach", { session_id = s.session_id })
  local blocks = rex.call("session.list_blocks", { session_id = s.session_id }) or {}
  for _, b in ipairs(blocks.blocks or {}) do
    if b.creator_name == "com.superlogical.terminal" and (not rex.args.block_id or rex.args.block_id == b.block_id) then
      local p = rex.call("block.method", { session_id = s.session_id, block_id = b.block_id, method = "process" })
      if p and p.child and p.child.pid then
        local fg = p.foreground or {}
        ret[#ret + 1] = {
          session_id = s.session_id,
          session = s.label,
          block_id = b.block_id,
          pid = p.child.pid,
          cwd = fg.cwd or (p.ancestors and p.ancestors[1] and p.ancestors[1].cwd),
        }
      end
    end
  end
end
return ret
]]

---@param args string[]
---@param opts? {notify?:boolean, stdin?:string}
local function rex(args, opts)
  local cmd = vim.list_extend(vim.deepcopy(REX), args)
  return Util.exec(cmd, { notify = not opts or opts.notify ~= false, stdin = opts and opts.stdin })
end

---@param opts? {block_id?:string, notify?:boolean}
function M.panes(opts)
  opts = opts or {}
  local args = { "do", "-e", PANES_SCRIPT }
  if opts.block_id then
    args[#args + 1] = "block_id=" .. opts.block_id
  end
  local _, out = rex(args, { notify = opts.notify == true })
  local ok, panes = pcall(vim.json.decode, out or "")
  if not ok or type(panes) ~= "table" then
    return {}
  end
  ---@cast panes {session_id:string, session:string, block_id:string, pid:integer, cwd?:string}[]
  return panes
end

---@return sidekick.cli.terminal.Cmd?
function M:start()
  if not vim.env.REX_SESSION then
    Util.error("The Rex backend can only start sessions from inside Rex")
    return
  end

  local args ---@type string[]
  if Config.cli.mux.create == "window" then
    args = { "run", "-s", vim.env.REX_SESSION }
  else
    -- Rex has no client that can run inside a Neovim terminal, so `terminal` opens a split too
    local split = Config.cli.mux.split
    local size = split.size
    if size > 1 then
      size = size / (split.vertical and vim.o.columns or vim.o.lines)
    end
    local ratio = math.max(1, math.min(99, math.floor(size * 100 + 0.5)))
    args = { "split", "-s", vim.env.REX_SESSION, "--split", split.vertical and "right" or "below" }
    vim.list_extend(args, { "--ratio", tostring(ratio) })
    if vim.env.REX_BLOCK then
      vim.list_extend(args, { "-b", vim.env.REX_BLOCK })
    end
  end
  vim.list_extend(args, { "-c", self.cwd, "--label", self.tool.name, "--focus=false", "--json", "--" })
  self:add_cmd(args)

  local _, out = rex(args)
  local ok, created = pcall(vim.json.decode, out or "")
  local block_id = ok and type(created) == "table" and created.block_ids and created.block_ids[1]
  if not block_id then
    return
  end
  local pane = M.panes({ block_id = block_id, notify = true })[1]
  if not pane then
    -- an untracked block would keep the tool running where sidekick can't reach it
    rex({ "block", "close", "-s", vim.env.REX_SESSION, block_id }, { notify = false })
    Util.error(("Failed to track the Rex block for **%s**"):format(self.tool.name))
    return
  end
  self.id = "rex " .. block_id
  self.rex_session_id = pane.session_id
  self.rex_block_id = block_id
  self.rex_pid = pane.pid
  self.mux_session = pane.session
  self.started = true
  Util.info(("Started **%s** in a new Rex %s"):format(self.tool.name, args[1] == "run" and "window" or "split"))
end

--- Rex sets no per-command environment, so `env` applies the tool's.
---@param ret string[]
function M:add_cmd(ret)
  if next(self.tool.env or {}) then
    ret[#ret + 1] = "env"
    -- `env` stops reading options at the first assignment, so every `-u` goes first
    local set = {} ---@type string[]
    for key, value in pairs(self.tool.env) do
      if value == false then
        vim.list_extend(ret, { "-u", key })
      else
        set[#set + 1] = ("%s=%s"):format(key, tostring(value))
      end
    end
    vim.list_extend(ret, set)
  end
  vim.list_extend(ret, self.tool.cmd)
end

function M:is_running()
  return self.rex_pid and vim.api.nvim_get_proc(self.rex_pid) ~= nil
end

function M.sessions()
  local ret = {} ---@type sidekick.cli.session.State[]
  local tools = Config.tools()
  local Procs = require("sidekick.cli.procs")
  local procs = Procs.new()
  for _, pane in ipairs(M.panes()) do
    procs:walk(pane.pid, function(proc)
      for _, tool in pairs(tools) do
        if tool:is_proc(proc) then
          ret[#ret + 1] = {
            id = "rex " .. pane.block_id,
            cwd = proc.cwd or pane.cwd,
            tool = tool,
            rex_session_id = pane.session_id,
            rex_block_id = pane.block_id,
            rex_pid = pane.pid,
            mux_session = pane.session,
            pids = Procs.pids(pane.pid),
          }
          return true
        end
      end
    end)
  end
  return ret
end

---@param event {type:string, payload:table}
function M:event(event)
  local args = { session_id = self.rex_session_id, block_id = self.rex_block_id, event = event }
  rex({ "api", "call", "-s", self.rex_session_id, "block.event", "-" }, { stdin = vim.json.encode(args) })
end

--- Sent as a paste, so a tool with a modal composer inserts the text instead of
--- interpreting it as keystrokes.
function M:send(text)
  local function send()
    self:event({ type = "paste", payload = { text = text } })
  end
  if self.tool.mux_focus then
    -- some TUI apps like qwen ignore input when unfocused
    self:event({ type = "focus", payload = { action = "in" } })
    vim.defer_fn(send, 50)
  else
    send()
  end
end

function M:submit()
  rex({ "send-key", "-s", self.rex_session_id, "-b", self.rex_block_id, "enter" })
end

function M:focus()
  rex({ "focus", "-s", self.rex_session_id, self.rex_block_id })
end

function M:dump()
  local lines = rex({ "capture", "-s", self.rex_session_id, "-b", self.rex_block_id, "--format=vt", "--trim" })
  if not lines then
    return
  end
  return table.concat(vim.list_slice(lines, math.max(1, #lines - Config.cli.mux.dump + 1)), "\n")
end

return M
