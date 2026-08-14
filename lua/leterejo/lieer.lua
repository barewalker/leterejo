-- Carrying what changed here up to Gmail.
--
-- lieer talks to the Gmail API and keeps a Maildir and its notmuch tags in step
-- with the labels on the other side. It holds an OAuth token in a file and
-- never touches gpg, so unlike mbsync it can run without anyone present.
--
-- `sync` pushes first and then pulls. The order matters: a pull that ran first
-- would overwrite the very change we are trying to send.
local config = require("leterejo.config")
local lang = require("leterejo.lang")

local M = {}

-- lieer takes an exclusive lock on the repository and, for sync, takes it
-- without waiting — a second one exits at once saying this. That is the
-- behaviour we want (nothing queues up unseen), so recognise it and come back
-- rather than report it as a failure.
local BUSY = "failed to lock repository"

-- The repository to work in.
--
-- One directory per account, holding .gmailieer.json and the mail. There is
-- deliberately no guess: the notmuch database can span several repositories
-- and picking the wrong one would push one account's changes at another.
local function repository(account)
  local a = (config.options.accounts or {})[account] or {}
  local dir = a.lieer_dir or (config.options.lieer or {}).dir
  return dir and vim.fn.expand(dir) or nil
end

function M.configured(account)
  return repository(account) ~= nil
end

local function first_line(s)
  return vim.trim((tostring(s or ""):match("([^\n]*)")))
end

-- Push what changed here, then pull what changed there.
--
--   on_done(ok, message)
--
-- Coming back ok means gmi ran and exited zero. It does not mean the change
-- arrived: lieer refuses to push onto a remote that has moved on, and the pull
-- in the same run then puts the old state back. Only reading the tags again
-- settles that, which is what actions.lua does.
function M.sync(account, on_done)
  local dir = repository(account)
  if not dir then
    return on_done(false, lang.t("err_no_lieer_dir"))
  end

  local opts = config.options.lieer or {}
  local attempts = (opts.retries or 2) + 1

  local function attempt(n)
    vim.system({
      opts.executable or "gmi",
      "sync",
    }, { text = true, cwd = dir, timeout = opts.timeout or 120000 }, function(res)
      -- vim.system finishes in a fast-event context where touching the screen
      -- crashes; hop back to the main loop first.
      vim.schedule(function()
        if res.code == 0 then
          return on_done(true)
        end

        local text = (res.stderr or "") .. "\n" .. (res.stdout or "")

        if text:find(BUSY, 1, true) and n < attempts then
          -- A timer and a write have met. Wait for the other one to finish.
          return vim.defer_fn(function()
            attempt(n + 1)
          end, opts.retry_delay or 3000)
        end

        if text:find(BUSY, 1, true) then
          return on_done(false, lang.t("err_lieer_busy"))
        end

        on_done(false, first_line(text) ~= "" and first_line(text) or lang.t("err_lieer"))
      end)
    end)
  end

  attempt(1)
end

return M
