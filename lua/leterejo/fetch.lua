-- Fetching for an account something other than lieer fills.
--
-- On a lieer account `u` runs `gmi sync`, and the plugin knows what that is.
-- A directory account is filled by whatever the owner runs — mbsync behind a
-- systemd timer here — and the plugin knows nothing about it except that the
-- store is theirs to write. Every five minutes is the right cadence for a
-- timer and the wrong one for someone who has just been told a message is on
-- its way; so the account may name the command that fetches, and `u` runs it.
--
-- The command is run as given, in the account's notmuch environment, and
-- whatever it does is its own business — the one here fetches, indexes,
-- classifies and files, and holds a lock so a run started here and one the
-- timer starts do not overlap. The plugin only waits for it and reads the
-- list again.
local config = require("leterejo.config")
local lang = require("leterejo.lang")

local M = {}

local function command(account)
  local a = (config.options.accounts or {})[account] or {}
  local cmd = a.fetch_command
  if type(cmd) == "string" then
    return { cmd }
  end
  if type(cmd) == "table" and #cmd > 0 then
    return cmd
  end
  return nil
end

function M.configured(account)
  return command(account) ~= nil
end

-- The last line worth showing out of what a run said: the last non-empty one,
-- with stderr ahead of stdout so a failure's reason comes first.
local function last_line(s)
  local found
  for line in tostring(s or ""):gmatch("[^\n]+") do
    line = vim.trim(line)
    if line ~= "" then
      found = line
    end
  end
  return found
end

-- Run the account's fetch command.
--
--   on_done(ok, message)
--
-- ok means the command exited zero. What it did is not known here: the list
-- is read again either way, since a fetch that failed leaves the index as it
-- was, and that is still worth drawing.
function M.run(account, on_done)
  local cmd = command(account)
  if not cmd then
    return on_done(false, lang.t("err_no_fetch_command"))
  end

  local a = (config.options.accounts or {})[account] or {}

  -- The same environment the plugin gives notmuch: the account's index, and
  -- the n-gram switch without which anything indexed on this run cannot be
  -- searched inside a run of Japanese.
  local env = { XAPIAN_CJK_NGRAM = "1" }
  local notmuch_config = a.notmuch_config or (config.options.notmuch or {}).config
  if notmuch_config then
    env.NOTMUCH_CONFIG = vim.fn.expand(notmuch_config)
  end

  local expanded = {}
  for _, word in ipairs(cmd) do
    table.insert(expanded, vim.fn.expand(word))
  end

  vim.system(expanded, {
    text = true,
    env = env,
    timeout = a.fetch_timeout or 300000,
  }, function(res)
    -- vim.system finishes in a fast-event context where touching the screen
    -- crashes; hop back to the main loop first.
    vim.schedule(function()
      if res.code == 0 then
        return on_done(true, nil)
      end
      local said = last_line(res.stderr) or last_line(res.stdout)
      if res.signal == 15 and (res.stderr or "") == "" then
        said = lang.t("err_fetch_timeout", math.floor((a.fetch_timeout or 300000) / 1000))
      end
      on_done(false, said or lang.t("err_fetch"))
    end)
  end)
end

return M
