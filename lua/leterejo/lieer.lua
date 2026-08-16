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

-- The first line worth showing out of what a run said.
--
-- The first *non-empty* one, because stdout and stderr are joined with a
-- newline between them and lieer reports on stdout: taking the literal first
-- line of that gave the empty string ahead of the separator every time stderr
-- was quiet, and the caller then fell back to "gmi failed to run" — throwing
-- away the only sentence that said what actually happened.
local function first_line(s)
  for line in tostring(s or ""):gmatch("[^\n]+") do
    line = vim.trim(line)
    if line ~= "" then
      return line
    end
  end
  return ""
end

-- An interrupted full pull, left behind for the next run to carry on from.
--
-- It has to be finished before anything else can work: without it lieer has no
-- history point to sync from, so every `gmi sync` starts the whole pull again —
-- twenty minutes for 32,000 messages. Which cannot end well on a five-minute
-- timer with a two-minute patience: the run is killed part way, the resume file
-- survives, and the same thing happens again five minutes later, for ever. That
-- is what happened here, and the account went a day without mail while every
-- round reported a failure that said nothing.
--
-- So it is refused rather than attempted, and said once in words that name the
-- way out.
local function resuming(dir)
  return vim.fn.filereadable(dir .. "/.resume-pull.gmailieer.json") == 1
end

-- Running more than one Neovim ------------------------------------------------
--
-- Two editors on one mailbox is an ordinary way to work — one in the mail
-- window, one beside whatever is being written about — and nothing here may
-- assume it is the only one. Three things follow.
--
-- notmuch needs no help: two `notmuch tag` processes on one index wait for each
-- other rather than fail. Measured at twenty at once, all of them successful,
-- and one waited 51 ms for a reindex to let go.
--
-- lieer does need help, twice. It takes its lock without waiting and then
-- *raises* rather than exits, which apport turns into a crash dialog for
-- something working exactly as designed — so a gmi is never started into a
-- repository that is already busy. And two timers on one repository is twice
-- the traffic to Gmail for the same mail, which matters because Gmail's rate
-- limit is real: the second pull here was slowed 26 minutes by it. So a sync
-- leaves a stamp, and a timer that finds a fresh one lets the other editor's
-- round stand for its own.

-- Whether another gmi holds this repository right now.
--
-- A glance, not a reservation: the lock can be taken in the moment between this
-- and the process starting, which is why the retry below stays. It removes the
-- ordinary collisions, not the race.
local function busy(dir, on_done)
  local ok = pcall(vim.system, { "flock", "-n", dir .. "/.lock", "true" }, { text = true }, function(res)
    vim.schedule(function()
      on_done(res.code ~= 0)
    end)
  end)

  -- No flock to ask with: carry on as before and let gmi decide.
  if not ok then
    on_done(false)
  end
end

-- Where the last successful sync of an account is recorded.
--
-- Outside the mail repository on purpose: that directory is lieer's, and a file
-- of ours in it is one more thing for a future `gmi` to have an opinion about.
local function stamp_file(account)
  local dir = vim.fn.stdpath("state") .. "/leterejo"
  vim.fn.mkdir(dir, "p")
  return dir .. "/synced-" .. tostring(account or "default"):gsub("[^%w%-_]", "_")
end

local function stamp(account)
  pcall(vim.fn.writefile, {}, stamp_file(account))
end

-- How long ago some editor last synced this account, in seconds.
local function since_sync(account)
  local at = vim.fn.getftime(stamp_file(account))
  if at < 0 then
    return math.huge
  end
  return os.time() - at
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

  if resuming(dir) then
    return on_done(false, lang.e("lieer_resume_needed", dir))
  end

  local opts = config.options.lieer or {}
  local attempts = (opts.retries or 2) + 1

  -- What gmi needs in its environment.
  --
  -- lieer registers what it fetched in notmuch itself, so it is an indexer, and
  -- an indexer that runs without XAPIAN_CJK_NGRAM=1 writes messages that cannot
  -- be searched inside a run of Japanese — the failure §13.4 of the design
  -- notes describes, which says nothing and shows nothing until someone
  -- searches for a word inside a longer one.
  --
  -- And the index has to be this account's: lieer reads notmuch's configuration
  -- for the database path and for new.tags.
  local env = { XAPIAN_CJK_NGRAM = "1" }

  local a = (config.options.accounts or {})[account] or {}
  local notmuch_config = a.notmuch_config or (config.options.notmuch or {}).config
  if notmuch_config then
    env.NOTMUCH_CONFIG = vim.fn.expand(notmuch_config)
  end

  local attempt

  local function try_later(n)
    if n < attempts then
      return vim.defer_fn(function()
        attempt(n + 1)
      end, opts.retry_delay or 3000)
    end
    on_done(false, lang.t("err_lieer_busy"))
  end

  local function start(n)
    vim.system({
      opts.executable or "gmi",
      "sync",
    }, { text = true, cwd = dir, env = env, timeout = opts.timeout or 120000 }, function(res)
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

          -- Say when this account was last brought up to date, so another
          -- editor's timer can let this round stand for its own.
          stamp(account)

          return on_done(true, nil, refused or nil)
        end

        -- The lock was free a moment ago and is not now. Rare, since the glance
        -- below removes the ordinary case, but the race is real.
        if text:find(BUSY, 1, true) then
          return try_later(n)
        end

        on_done(false, first_line(text) ~= "" and first_line(text) or lang.t("err_lieer"))
      end)
    end)
  end

  -- Look before starting one. A gmi that cannot take the lock does not decline
  -- — it raises, and apport puts a crash report on the screen for it.
  attempt = function(n)
    busy(dir, function(taken)
      if taken then
        return try_later(n)
      end
      start(n)
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

-- Whether another gmi holds this repository right now.
--
-- Asked before the timer starts one, because a gmi that cannot take the lock
-- does not decline — it raises, and on Ubuntu an unhandled Python exception is
-- caught by apport, which puts a crash report on the screen. Nothing is broken
-- when that happens (the write path retries and the timer has another round in
-- five minutes), but a dialog saying an application stopped unexpectedly is not
-- what "the other one is still going" should look like.
--
-- It happens without anything being wrong: a second Neovim is a second timer on
-- the same repository, and a long `gmi pull` holds the lock for hours.
--
-- Only the timer asks. A write must not skip — the change has to go up — so it
-- still starts gmi and retries, which is what `retries` is for. And this is a
-- glance, not a reservation: the lock can be taken in the moment between, which
-- is why the retry stays.
local function busy(dir, on_done)
  local ok = pcall(vim.system, { "flock", "-n", dir .. "/.lock", "true" }, { text = true }, function(res)
    vim.schedule(function()
      on_done(res.code ~= 0)
    end)
  end)

  -- No flock to ask with: carry on as before and let gmi decide.
  if not ok then
    on_done(false)
  end
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

    local name = names[i]

    local function go()
      M.sync(name, function(ok, res)
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

    local dir = repository(name)
    if not dir then
      return go()
    end

    -- Another editor has already fetched this account within this round. Its
    -- mail is this one's mail: the index is shared, so there is nothing left
    -- for a second fetch to find. Half the interval, so a single editor never
    -- skips its own turn.
    local minutes = (config.options.lieer or {}).interval or 0
    if since_sync(name) < minutes * 30 then
      return step()
    end

    busy(dir, function(taken)
      if taken then
        -- Someone else is working in there. Nothing to report and nothing to
        -- wait for: the next round is one interval away.
        return step()
      end
      go()
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
