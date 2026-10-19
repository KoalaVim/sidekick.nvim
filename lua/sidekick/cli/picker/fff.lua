local M = {}

-- fff.nvim only provides a file picker, other sources use the first available fallback
local FALLBACKS = { "snacks", "telescope", "fzf-lua" }

-- fff's `on_submit` only receives the cursor item, and the multi-selection is
-- cleared when the picker closes. Capture it right before fff handles the select.
local selected = {} ---@type { edit_path: string }[]
local patched = false
local function patch_select()
  if patched then
    return
  end
  patched = true
  local ui = require("fff.picker_ui.picker_ui")
  local state = require("fff.picker_ui.picker_ui_state")
  local select = ui.select
  ui.select = function(...)
    selected = state.get_selected_file_entries()
    return select(...)
  end
end

---@param source string
---@param cb fun(items:sidekick.context.Loc[])
---@param opts? table
function M.open(source, cb, opts)
  opts = opts or {}
  if source ~= "files" then
    for _, name in ipairs(FALLBACKS) do
      if pcall(require, name) then
        return require("sidekick.cli.picker." .. name).open(source, cb, opts)
      end
    end
    return require("sidekick.util").error(("fff.nvim does not support the `%s` picker"):format(source))
  end

  patch_select()
  -- fff has no `on_show` hook, the picker is shown right away
  local on_show = opts.on_show
  opts.on_show = nil
  require("fff").find_files(vim.tbl_extend("force", opts, {
    on_submit = M.action(cb),
  }))
  if on_show then
    on_show()
  end
end

---@param cb fun(items:sidekick.context.Loc[])
function M.action(cb)
  ---@param ctx { path: string, location?: { line?: integer, col?: integer } }
  return function(_, ctx)
    local entries = selected
    selected = {}
    if #entries > 0 then
      return cb(vim.tbl_map(function(entry)
        return { name = vim.fn.fnamemodify(entry.edit_path, ":p") }
      end, entries))
    end
    local loc = ctx.location or {}
    cb({
      {
        name = ctx.path,
        row = loc.line,
        col = loc.line and (loc.col or 1) or nil,
      },
    })
  end
end

return M
