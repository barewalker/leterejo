-- Remembers fetched envelope lists and message bodies.
--
-- himalaya v2 opens a fresh connection per command, so revisiting the same page
-- costs roughly two seconds every time. What has been seen is kept and drawn
-- first, with a refetch running behind it: the wait disappears and the contents
-- catch up a few seconds later.
--
-- This is only for accounts that still read over IMAP. Accounts on the local
-- index skip it entirely (see `bypass` below) — once a page costs forty
-- milliseconds there is nothing left to hide, and the whole draw-then-catch-up
-- dance becomes a liability rather than a help.
local M = {}

-- Lists: "account/mailbox/page" -> array of envelopes
local envelopes = {}

-- Bodies: "account/mailbox/id" -> rendered text
-- A single message can exceed 1 MiB, so only a few are held.
local messages = {}
local message_order = {}
local MESSAGE_LIMIT = 30

local function key(...)
  local parts = {}
  for _, v in ipairs({ ... }) do
    table.insert(parts, tostring(v or ""))
  end
  return table.concat(parts, "/")
end

-- Accounts that read from the local index need none of this.
--
-- notmuch answers a page in tens of milliseconds, so there is no wait to hide
-- and nothing worth writing to disk. Skipping them also avoids a real hazard:
-- entries captured before the move carry IMAP UIDs, and drawing those first
-- would hand a UID to a layer that only understands message ids.
local function bypass(account)
  local ok, notmuch = pcall(require, "leterejo.notmuch")
  return ok and notmuch.is_local(account)
end

-- Persisting lists ----------------------------------------------------------
--
-- Keeping lists in memory alone means waiting on every Neovim start. An
-- envelope is only a few hundred bytes, so writing them out lets the next
-- session show the list at once; stale contents are refetched in the
-- background.
--
-- Bodies are excluded: at over 1 MiB each they are not worth persisting.

local store_path = nil

-- Cap on stored keys so the file cannot grow without bound.
local ENVELOPE_KEY_LIMIT = 60

local function path()
  if not store_path then
    local dir = vim.fn.stdpath("cache") .. "/leterejo"
    vim.fn.mkdir(dir, "p")
    store_path = dir .. "/envelopes.json"
  end
  return store_path
end

-- Debounce writes; writing on every page turn would be wasteful.
local save_pending = false

local function save_now()
  save_pending = false

  -- Trim when over the cap. Which entries survive does not matter: anything
  -- dropped is refilled by the next fetch.
  local keys = vim.tbl_keys(envelopes)
  if #keys > ENVELOPE_KEY_LIMIT then
    table.sort(keys)
    for i = 1, #keys - ENVELOPE_KEY_LIMIT do
      envelopes[keys[i]] = nil
    end
  end

  local ok, encoded = pcall(vim.json.encode, envelopes)
  if not ok then
    return
  end

  local f = io.open(path(), "w")
  if not f then
    return
  end
  f:write(encoded)
  f:close()
end

local function save_later()
  if save_pending then
    return
  end
  save_pending = true
  vim.defer_fn(save_now, 1000)
end

-- Load what was persisted. Called once at startup.
function M.load()
  local f = io.open(path(), "r")
  if not f then
    return false
  end

  local content = f:read("*a")
  f:close()

  if not content or content == "" then
    return false
  end

  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    return false
  end

  -- Drop anything belonging to an account that now reads from the local
  -- index. Those entries were captured over IMAP and carry UIDs.
  for k in pairs(decoded) do
    local account = tostring(k):match("^([^/]+)/")
    if account and bypass(account) then
      decoded[k] = nil
    end
  end

  envelopes = decoded
  return true
end

-- Flush a pending write when Neovim exits.
function M.flush()
  if save_pending then
    save_now()
  end
end

-- Lists ---------------------------------------------------------------------

function M.get_envelopes(account, mailbox, page)
  if bypass(account) then
    return nil
  end
  return envelopes[key(account, mailbox, page)]
end

function M.set_envelopes(account, mailbox, page, list)
  if bypass(account) then
    return
  end
  envelopes[key(account, mailbox, page)] = list
  save_later()
end

-- Bodies --------------------------------------------------------------------

function M.get_message(account, mailbox, id)
  if bypass(account) then
    return nil
  end
  return messages[key(account, mailbox, id)]
end

function M.set_message(account, mailbox, id, text)
  if bypass(account) then
    return
  end
  local k = key(account, mailbox, id)

  if messages[k] == nil then
    table.insert(message_order, k)
    -- Drop the oldest once over the cap.
    while #message_order > MESSAGE_LIMIT do
      local oldest = table.remove(message_order, 1)
      messages[oldest] = nil
    end
  end

  messages[k] = text
end

-- Eviction ------------------------------------------------------------------

-- Drop everything, including the file on disk. Used when the user explicitly
-- asks for a refetch.
function M.clear()
  envelopes = {}
  messages = {}
  message_order = {}
  os.remove(path())
end

-- Drop the lists for one mailbox, e.g. after moving a message out of it.
function M.invalidate_mailbox(account, mailbox)
  local prefix = key(account, mailbox) .. "/"
  for k in pairs(envelopes) do
    if k:sub(1, #prefix) == prefix then
      envelopes[k] = nil
    end
  end
end

-- Whether a list actually changed; an unchanged refetch skips the redraw.
-- Comparing count, ids and flags catches reads, arrivals and deletions.
function M.envelopes_differ(a, b)
  if a == nil or b == nil then
    return true
  end
  if #a ~= #b then
    return true
  end

  for i = 1, #a do
    if a[i].id ~= b[i].id then
      return true
    end

    local fa, fb = a[i].flags or {}, b[i].flags or {}
    if #fa ~= #fb then
      return true
    end
    for j = 1, #fa do
      if fa[j].iana ~= fb[j].iana then
        return true
      end
    end
  end

  return false
end

return M
