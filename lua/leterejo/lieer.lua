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
        local text = (res.stderr or "") .. "\n" .. (res.stdout or "")

        if res.code == 0 then
          -- Exit zero does not mean the change went up. lieer refuses to push
          -- a message whose remote state has moved on since the last pull, and
          -- says so on stdout while exiting successfully:
          --
          --   update: remote has changed, will not update: <id> (…) (N > M)
          --   push: not all changes could be pushed, will re-try at next push.
          --
          -- Reading that back is the difference between telling the user what
          -- happened and leaving them with a change that quietly did not.
          local refused = text:match("update: remote has changed[^\n]*")
            or (text:find("not all changes could be pushed", 1, true) and text:match("push: not all changes[^\n]*"))

          return on_done(true, nil, refused or nil)
        end

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

-- Fetching on its own ---------------------------------------------------------
--
-- What lieer made possible. mbsync needed a passphrase out of gpg, so it could
-- not run unattended without leaving one lying around; lieer holds an OAuth
-- token in a file and never touches gpg, so a timer is simply a timer.

local timer, running, last_failure = nil, false, nil

-- The accounts worth syncing: those with a repository of their own, or the one
-- being read when a single repository is shared.
local function syncable()
  local names = {}
  for name, a in pairs(config.options.accounts or {}) do
    if a.lieer_dir then
      table.insert(names, name)
    end
  end
  table.sort(names)

  if #names == 0 and (config.options.lieer or {}).dir then
    names = { require("leterejo.state").account }
  end
  return names
end

-- One round: sync each repository in turn, then let the screen catch up.
--
-- In turn rather than at once, because two gmi processes are two lots of
-- network and CPU for no gain — and if they ever shared a repository, the
-- second would find it locked.
function M.tick(on_done)
  if running then
    return -- the last round has not finished; skip rather than pile up
  end

  local names = syncable()
  if #names == 0 then
    return
  end

  running = true
  local i = 0

  local function step()
    i = i + 1
    if i > #names then
      running = false
      return on_done and on_done()
    end

    M.sync(names[i], function(ok, res)
      -- Say something when it breaks, but not once a minute for the same
      -- reason. A silent background failure is worse than one line.
      if not ok and res ~= last_failure then
        last_failure = res
        vim.notify(lang.t("prefix") .. lang.t("sync_failed", tostring(res)), vim.log.levels.WARN)
      elseif ok then
        last_failure = nil
      end
      step()
    end)
  end

  step()
end

function M.stop()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

-- Start fetching on a timer, if the configuration asks for one.
function M.start()
  M.stop()

  local minutes = (config.options.lieer or {}).interval
  if type(minutes) ~= "number" or minutes <= 0 then
    return
  end

  local period = math.floor(minutes * 60 * 1000)

  timer = vim.uv.new_timer()
  timer:start(period, period, function()
    -- The timer fires in a fast-event context, where most of the API is off
    -- limits; everything real happens back on the main loop.
    vim.schedule(function()
      M.tick(function()
        require("leterejo.ui.envelopes").reload_quietly()
      end)
    end)
  end)
end

return M
