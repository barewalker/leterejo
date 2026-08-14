-- The himalaya CLI call layer.
--
-- himalaya v2 opens a fresh TCP+TLS+SASL session per command, so every
-- operation costs hundreds of milliseconds to several seconds. Everything runs
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
  -- arguments, such as `envelope search`, would otherwise swallow it as part
  -- of the query (`cannot parse search emails query 'x --json'`).
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

-- Fetch pre-rendered text as is (message bodies and the like).
function M.text(args, account, on_done)
  run(args, account, on_done)
end

-- Fetch a page of envelopes.
--
-- --has-attachment fetches BODYSTRUCTURE as well, measured at about 0.1 s
-- extra. Showing attachment status in the list is worth more than that, so it
-- is always requested.
function M.list_envelopes(account, mailbox, page, page_size, on_done)
  -- Accounts that keep a local copy read from the index instead. The screen
  -- gets the same shape either way.
  local notmuch = require("leterejo.notmuch")
  if notmuch.is_local(account) then
    return notmuch.list(notmuch.query_for(account, mailbox), page, page_size, on_done)
  end

  local args = { "envelope", "list", "-p", tostring(page), "--has-attachment" }

  if mailbox then
    vim.list_extend(args, { "-m", mailbox })
  end
  if page_size then
    vim.list_extend(args, { "-s", tostring(page_size) })
  end

  M.json(args, account, function(ok, res)
    if not ok then
      return on_done(false, res)
    end
    -- v2 returns { envelopes = [...] }, not a bare array.
    on_done(true, res.envelopes or {})
  end)
end

-- Fetch a run of envelopes starting at an arbitrary offset.
--
-- Paging asks for page N of a fixed size; a continuous list asks for "the next
-- hundred after the four hundred I already have", which is not the same request
-- once rows have been added or removed underneath. Only the local index can
-- answer it exactly. Over IMAP the offset is rounded to a page boundary, which
-- is why continuous listing is not the default there.
function M.list_envelopes_at(account, mailbox, offset, limit, on_done)
  local notmuch = require("leterejo.notmuch")
  if notmuch.is_local(account) then
    return notmuch.list_at(notmuch.query_for(account, mailbox), offset, limit, on_done)
  end

  local page = math.floor(offset / limit) + 1
  return M.list_envelopes(account, mailbox, page, limit, on_done)
end

-- Fetch a run of conversations. Local accounts only; see M.can_thread.
function M.list_threads(account, mailbox, offset, limit, on_done)
  local notmuch = require("leterejo.notmuch")
  if not notmuch.is_local(account) then
    return on_done(false, lang.t("no_threads_here"))
  end
  return notmuch.list_threads(notmuch.query_for(account, mailbox), offset, limit, on_done)
end

-- The messages of one conversation, oldest first.
function M.thread_messages(account, thread, on_done)
  local notmuch = require("leterejo.notmuch")
  if not notmuch.is_local(account) then
    return on_done(false, lang.t("no_threads_here"))
  end
  return notmuch.thread_messages(thread, on_done)
end

-- Whether this account can group its list into conversations.
--
-- himalaya's envelope list reports no thread at all, and reconstructing threads
-- from References across pages of IMAP fetches would cost far more than it is
-- worth. So this is a property of the account, not a preference.
function M.can_thread(account)
  return require("leterejo.notmuch").is_local(account)
end

-- How many messages, or conversations, the mailbox holds.
--
-- nil means "cannot be known cheaply": himalaya reports no total, and finding
-- one would mean listing everything. A continuous list without a total simply
-- keeps asking until a batch comes back short.
function M.count_envelopes(account, mailbox, threaded, on_done)
  local notmuch = require("leterejo.notmuch")
  if not notmuch.is_local(account) then
    return on_done(true, nil)
  end
  return notmuch.count(notmuch.query_for(account, mailbox), threaded, on_done)
end

-- Fetch the mailboxes (labels, on Gmail).
function M.list_mailboxes(account, on_done)
  -- Accounts on the local index list what was actually synced down, not what
  -- the server holds; offering a name with nothing behind it just looks broken.
  local notmuch = require("leterejo.notmuch")
  if notmuch.is_local(account) then
    return notmuch.folders(account, on_done)
  end

  M.json({ "mailbox", "list" }, account, function(ok, res)
    if not ok then
      return on_done(false, res)
    end

    local names = {}
    for _, m in ipairs(res.mailboxes or {}) do
      table.insert(names, m.id or m.name)
    end
    on_done(true, names)
  end)
end

-- Fetch the configured accounts.
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

-- Read a body. himalaya uses BODY.PEEK, so this does not mark it as read.
function M.read_message(account, mailbox, id, on_done)
  local notmuch = require("leterejo.notmuch")
  if notmuch.is_local(account) then
    return notmuch.read(id, on_done)
  end

  local args = { "message", "read", tostring(id) }
  if mailbox then
    vim.list_extend(args, { "-m", mailbox })
  end
  M.text(args, account, on_done)
end

-- Fetch a message's MIME structure.
--
-- `message read` and `attachment list` download the whole message before
-- parsing it, which takes seconds when attachments are large (5 s for a 1.4 MiB
-- message). The structure alone carries no content, costing only the connection
-- (2.4 s). Use this to learn what attachments exist.
--
-- This is an IMAP-specific command and does not work on other backends.
function M.fetch_structure(account, mailbox, id, on_done)
  local args = { "imap", "fetch", tostring(id), "--structure" }
  if mailbox then
    vim.list_extend(args, { "-m", mailbox })
  end

  M.json(args, account, function(ok, res)
    if not ok then
      return on_done(false, res)
    end
    local msg = (res.messages or {})[1]
    on_done(true, msg and msg.structure or nil)
  end)
end

-- Collect the attachments of a message.
--
-- Reading from the local index costs nothing: notmuch already parsed the MIME
-- tree when it indexed the file. Over IMAP this is a fresh connection, which
-- is why opening a message used to stall for seconds even when the body came
-- back instantly — the screen waits for both.
function M.list_attachments(account, mailbox, id, on_done)
  local notmuch = require("leterejo.notmuch")
  if notmuch.is_local(account) then
    return notmuch.attachments(id, on_done)
  end

  M.fetch_structure(account, mailbox, id, function(ok, structure)
    if not ok then
      return on_done(false, structure)
    end
    local util = require("leterejo.ui.util")
    on_done(true, structure and util.collect_attachments(structure) or {})
  end)
end

-- Save every attachment. Omitting the directory uses himalaya's downloads-dir.
--
-- The reply carries the paths actually written. himalaya appends "(1)" when a
-- name is taken, so always open the returned path rather than a guessed one.
function M.download_attachments(account, mailbox, id, dir, on_done)
  local notmuch = require("leterejo.notmuch")
  if notmuch.is_local(account) then
    return notmuch.save_attachments(id, dir, on_done)
  end

  local args = { "attachment", "download", tostring(id) }
  if mailbox then
    vim.list_extend(args, { "-m", mailbox })
  end
  if dir then
    vim.list_extend(args, { "-d", dir })
  end
  M.json(args, account, on_done)
end

-- Flags -----------------------------------------------------------------
--
-- v2 names flags by their IANA keyword without the backslash, one -f per flag,
-- and accepts only seen, answered, flagged and draft. \Deleted is not on that
-- list, so there is no way to mark a message deleted through this command —
-- deleting means moving to the trash mailbox instead (see M.move_messages).
-- Turn whatever the screen is holding into ids himalaya will accept.
--
-- Accounts read from the local index carry the message id, because that is the
-- only handle notmuch can look a message up by. IMAP wants its own UID, which
-- mbsync happens to leave in the file name as ",U=<n>" — so recover it here.
-- Reads and writes therefore disagree on what an id is, and this is the one
-- place that has to know.
local function resolve_ids(account, ids, on_done)
  local notmuch = require("leterejo.notmuch")
  if not notmuch.is_local(account) then
    return on_done(true, ids)
  end

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
  resolve_ids(account, ids, function(ok, resolved)
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
  resolve_ids(account, ids, function(ok, resolved)
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

-- Warm the passphrase cache.
--
-- himalaya invokes pass on every operation. Called from Neovim with a cold
-- cache, pinentry seizes the terminal and leaves the screen garbled for tens of
-- seconds. One cheap query up front gets the unlock done first.
function M.warm_up(account, on_done)
  M.json({ "account", "list" }, account, function(ok, res)
    on_done(ok, res)
  end)
end

return M
