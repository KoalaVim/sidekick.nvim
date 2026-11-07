local Session = require("sidekick.cli.session")
local State = require("sidekick.cli.state")
local Util = require("sidekick.util")

describe("session creation reporting", function()
  local attach, new, info
  before_each(function()
    attach, new, info = Session.attach, Session.new, Util.info
    Util.info = function() end
    Session.new = function()
      return {
        backend = "herdr",
        tool = { name = "claude" },
        is_attached = function()
          return true
        end,
      }
    end
    Session.attach = function(session)
      session.started = true
      return session
    end
  end)
  after_each(function()
    Session.attach, Session.new, Util.info = attach, new, info
  end)

  for _, case in ipairs({
    { name = "a tool without a session", no_session = true, expected = true },
    { name = "an unstarted session", expected = true },
    { name = "a running session", started = true, expected = false },
    { name = "an already attached session", started = true, attached = true, expected = false },
  }) do
    it("reports creation correctly for " .. case.name, function()
      local session = Session.new()
      session.started = case.started
      local _, _, created = State.attach({
        tool = session.tool,
        attached = case.attached,
        session = not case.no_session and session or nil,
      })
      assert.are.equal(case.expected, created)
    end)
  end
end)
