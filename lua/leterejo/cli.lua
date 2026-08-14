-- The himalaya CLI call layer.
--
-- Only writing comes through here now: reading is answered by the local notmuch
-- index (see notmuch.lua), which is why nothing in this file is on the path
-- between a keystroke and the list appearing.
--
-- himalaya v2 opens a fresh TCP+TLS+SASL session per command, so every operation
-- costs hundreds of milliseconds to several seconds. Everything runs
-- asynchronously to keep the screen responsive.
local config = require("leterejo.config")
local lang = require("leterejo.lang")

local M = {}

-- Detect a cold passphrase cache.
-- himalaya reports "Secret command error" when the pass call fails, followed by
-- "Timeout" once pinentry waits without an answer. Nothing resolves this until
-- the user types the passphrase in a terminal, so it needs its own message.
local function is_passphrase_error(text)
  if not text then
    return false
  end
  return text:match("Secret command error") ~= nil
    or (text:match("decryption failed") ~= nil and text:match("Timeout") ~= nil)
end

-- Reduce failure output to one line worth showing the user.
local function friendly_error(stderr, stdout)
  local text = (stderr or "") .. "\n" .. (stdout or "")

  if is_passphrase_error(text) then
    return lang.t("err_passphrase")
  end

  -- Name lookup failed. A dropped connection produces this too, so say so
  -- rather than let it read as a misconfiguration.
  if text:match("failed to lookup address information") then
    local host = text:match("connect%s+([%w%.%-]+:%d+)") or ""
    return lang.t("err_dns", host ~= "" and host or "the server")
  end

  -- With --json in play, failures can come back as JSON. Raw JSON is
  -- unreadable, so pull the message out.
  local decoded_ok, decoded = pcall(vim.json.decode, vim.trim(stdout or ""))
  if decoded_ok and type(decoded) == "table" and decoded.error then
    local msg = tostring(decoded.error)
    local sources = decoded.sources
    if type(sources) == "table" and #sources > 0 then
      msg = msg .. " — " .. table.concat(sources, " / ")
    end
    return msg
  end

  -- himalaya errors arrive as "Error: ..."; take the first line only.
  local first = text:match("Error:%s*([^\n]+)")
  if first then
    return first
  end

  first = text:match("([^\n]+)")
  return first or lang.t("err_generic")
end

-- Run himalaya asynchronously.
--   args    : arguments to pass (without the executable itself)
--   account : target account; nil uses himalaya's default
--   on_done : function(ok, result) — on failure, result is the message
local function run(args, account, on_done, opts)
  local cmd = { config.options.executable }

  if account then
    table.insert(cmd, "-a")
    table.insert(cmd, account)
  end

  -- Logs on stderr would confuse failure detection, so silence them.
  table.insert(cmd, "--log-level")
  table.insert(cmd, "off")

  -- --json must precede the subcommand. Commands taking variadic positional
  -- arguments would otherwise swallow it as part of their own arguments.
  if opts and opts.json then
    table.insert(cmd, "--json")
  end

  vim.list_extend(cmd, args)

  vim.system(cmd, { text = true, timeout = config.options.timeout }, function(res)
    -- vim.system completes in a fast-event context where touching the
    -- screen or most APIs crashes; hop back to the main loop first.
    vim.schedule(function()
      if res.code == 0 then
        on_done(true, res.stdout or "")
      else
        on_done(false, friendly_error(res.stderr, res.stdout))
      end
    end)
  end)
end

-- Fetch JSON output and decode it.
function M.json(args, account, on_done)
  run(args, account, function(ok, out)
    if not ok then
      return on_done(false, out)
    end

    local decoded_ok, decoded = pcall(vim.json.decode, out)
    if not decoded_ok then
      return on_done(false, lang.t("err_json", tostring(decoded)))
    end

    on_done(true, decoded)
  end, { json = true })
end

-- Fetch pre-rendered text as is.
function M.text(args, account, on_done)
  run(args, account, on_done)
end

-- Fetch the configured accounts.
--
-- himalaya's own configuration is still where accounts are declared, since it
-- is what sends. The index knows nothing about them.
function M.list_accounts(on_done)
  M.json({ "account", "list" }, nil, function(ok, res)
    if not ok then
      return on_done(false, res)
    end

    local names = {}
    for _, a in ipairs(res.accounts or {}) do
      table.insert(names, a.name or a.id)
    end
    on_done(true, names)
  end)
end

-- Flags -----------------------------------------------------------------
--
-- v2 names flags by their IANA keyword without the backslash, one -f per flag,
-- and accepts only seen, answered, flagged and draft. \Deleted is not on that
-- list, so there is no way to mark a message deleted through this command —
-- deleting means moving to the trash mailbox instead (see M.move_messages).

-- Turn what the screen is holding into ids himalaya will accept.
--
-- The screen carries the Message-ID, because that is the only handle notmuch
-- can look a message up by. IMAP wants its own UID, which mbsync happens to
-- leave in the file name as ",U=<n>" — so recover it here. Reads and writes
-- therefore disagree on what an id is, and this is the one place that knows.
local function resolve_ids(ids, on_done)
  local notmuch = require("leterejo.notmuch")

  local out, pending, failed = {}, #ids, nil
  if pending == 0 then
    return on_done(true, {})
  end

  for i, id in ipairs(ids) do
    notmuch.uid_of(id, function(ok, uid)
      if ok then
        out[i] = uid
      else
        failed = failed or uid
      end
      pending = pending - 1
      if pending == 0 then
        if failed then
          return on_done(false, failed)
        end
        on_done(true, out)
      end
    end)
  end
end

local function send_flag_command(verb, account, mailbox, ids, flags, on_done)
  local args = { "flag", verb }

  if mailbox then
    vim.list_extend(args, { "-m", mailbox })
  end
  for _, f in ipairs(flags) do
    vim.list_extend(args, { "-f", f })
  end
  for _, id in ipairs(ids) do
    table.insert(args, tostring(id))
  end

  M.text(args, account, on_done)
end

local function flag_command(verb, account, mailbox, ids, flags, on_done)
  resolve_ids(ids, function(ok, resolved)
    if not ok then
      return on_done(false, resolved)
    end
    send_flag_command(verb, account, mailbox, resolved, flags, on_done)
  end)
end

function M.add_flags(account, mailbox, ids, flags, on_done)
  flag_command("add", account, mailbox, ids, flags, on_done)
end

function M.remove_flags(account, mailbox, ids, flags, on_done)
  flag_command("remove", account, mailbox, ids, flags, on_done)
end

-- Move messages between mailboxes of the same account.
--
-- Over IMAP this is UID MOVE (RFC 6851), so the copy and the removal happen
-- server-side in one step. Both names go through the account's [mailbox.alias]
-- map, which is why "trash" works without spelling out "[Gmail]/ゴミ箱".
function M.move_messages(account, from, to, ids, on_done)
  resolve_ids(ids, function(ok, resolved)
    if not ok then
      return on_done(false, resolved)
    end

    local args = { "message", "move", "-t", to }

    if from then
      vim.list_extend(args, { "-f", from })
    end
    for _, id in ipairs(resolved) do
      table.insert(args, tostring(id))
    end

    M.text(args, account, on_done)
  end)
end

return M
