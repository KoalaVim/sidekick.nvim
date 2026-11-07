local Config = require("sidekick.config")
local Herdr = require("sidekick.cli.session.herdr")
local Select = require("sidekick.cli.ui.select")
local State = require("sidekick.cli.state")
local Util = require("sidekick.util")

describe("herdr split reuse", function()
  local exec, tools, get, mux, env
  before_each(function()
    exec, tools, get = Util.exec, Config.tools, State.get
    mux, env = Config.cli.mux, vim.env.HERDR_PANE_ID
    Config.cli.mux = { create = "split" }
    vim.env.HERDR_PANE_ID = "editor"
    Config.tools = function()
      return { claude = {} }
    end
    Util.exec = function(cmd)
      if cmd[2] == "agent" then
        return true,
          vim.json.encode({
            result = {
              agents = {
                {
                  pane_id = "same",
                  tab_id = "tab1",
                  agent = "claude",
                  cwd = "/changed",
                  tokens = { sidekick = "owned" },
                },
                {
                  pane_id = "other",
                  tab_id = "tab2",
                  agent = "claude",
                  cwd = "/changed",
                  tokens = { sidekick = "owned" },
                },
              },
            },
          })
      end
      return true, vim.json.encode({ result = { pane = { tab_id = cmd[4] == "other" and "tab2" or "tab1" } } })
    end
  end)
  after_each(function()
    Util.exec, Config.tools, State.get = exec, tools, get
    Config.cli.mux, vim.env.HERDR_PANE_ID = mux, env
  end)

  it("discovers only panes in the editor tab", function()
    local sessions = Herdr.sessions()
    assert.are.equal(1, #sessions)
    assert.are.equal("same", sessions[1].herdr_pane_id)
  end)

  it("stops using an attached pane moved to another tab", function()
    assert.is_true(Herdr.is_running({ herdr_pane_id = "same" }))
    assert.is_false(Herdr.is_running({ herdr_pane_id = "other" }))
  end)

  it("does not reuse panes when the editor tab cannot be resolved", function()
    local stub = Util.exec
    Util.exec = function(cmd)
      if cmd[2] == "pane" then
        return nil
      end
      return stub(cmd)
    end
    assert.are.equal(0, #Herdr.sessions())
    assert.is_false(Herdr.is_running({ herdr_pane_id = "same" }))
  end)

  it("keeps sessions in other tabs available in window mode", function()
    Config.cli.mux.create = "window"
    assert.are.equal(2, #Herdr.sessions())
  end)

  it("passes the host Neovim executable to the editor proxy", function()
    local cmd = Herdr.run_cmd({ herdr_pane_id = "same", tool = { cmd = { "claude" }, config = {} } })
    local expected = vim.fn.shellescape("SIDEKICK_NVIM=" .. vim.v.progpath)
    assert.is_true(vim.tbl_contains(cmd, expected))
  end)

  for _, owned in ipairs({ true, false }) do
    it(
      owned and "reuses an owned pane despite a different cwd" or "creates a pane when none is sidekick-owned",
      function()
        local fresh = { installed = true, tool = { name = "claude" } }
        local running = {
          installed = true,
          session = {
            backend = "herdr",
            cwd = "/different",
            herdr_token = owned and "owned" or nil,
          },
        }
        State.get = function()
          return { running, fresh }
        end
        local selected
        Select.select({
          auto = true,
          filter = { name = "claude" },
          cb = function(value)
            selected = value
          end,
        })
        assert.are.equal(owned and running or fresh, selected)
      end
    )
  end
end)
