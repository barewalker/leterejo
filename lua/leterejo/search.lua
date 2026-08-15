-- Filtering messages.
--
-- Every query is answered by the index, which searches bodies as well as
-- headers and comes back in tens of milliseconds. Japanese works because the
-- index was built with XAPIAN_CJK_NGRAM=1 and the same variable is passed on
-- every call — the one thing IMAP could not do at all, since himalaya v2's
-- `envelope search` cannot send a non-ASCII term (it needs a CHARSET argument
-- and a synchronising literal, and fails with `BAD Could not parse command`).
local config = require("leterejo.config")
local util = require("leterejo.ui.util")

local M = {}

-- The field names this plugin accepted before notmuch, kept so the keys
-- already in the user's fingers keep working.
local QUERY_HEADS = {
  ["not"] = true,
  ["date"] = true,
  ["after"] = true,
  ["from"] = true,
  ["to"] = true,
  ["subject"] = true,
  ["body"] = true,
  ["flag"] = true,
}

-- Accept the older shape ("subject foo") as well as notmuch's own
-- ("subject:foo"). Anything else is handed over untouched: notmuch understands
-- far more than the short list above.
local function to_notmuch_query(query)
  local field, value = query:match("^%s*([%a%-]+)%s+(.+)$")
  if field and QUERY_HEADS[field:lower()] and not query:find(":", 1, true) then
    return field:lower() .. ":" .. vim.trim(value)
  end
  return query
end

-- Filters the index cannot answer -----------------------------------------
--
-- Two of the markers in the list are searchable and one is not. The attachment
-- mark comes from a tag notmuch applied while indexing, so `tag:attachment` is
-- a real query. The suspicion mark does not exist in the index at all: it is
-- computed while drawing, from invisible characters in the sender and subject,
-- and Xapian never saw those because they are not word characters.
--
-- So `is:suspicious` is answered by reading the mailbox back and looking. That
-- is honest but not free, and the header says how many were examined.

local SUSPICIOUS = "is:suspicious"
local OBFUSCATED = "is:obfuscated"

local SCANNED = { [SUSPICIOUS] = true, [OBFUSCATED] = true }

local ALIASES = {
  ["is:attachment"] = "tag:attachment",
  -- notmuch indexes the MIME type of every part, so this is a real query
  -- rather than a scan: "mimetype:image" reaches image/jpeg, image/png and the
  -- rest, which "tag:attachment" cannot separate from a PDF.
  ["is:image"] = "mimetype:image",
  ["has:image"] = "mimetype:image",
  ["has:attachment"] = "tag:attachment",
  ["is:unread"] = "tag:unread",
  ["is:flagged"] = "tag:flagged",
}

-- Whether an envelope carries the thing being looked for.
--
--   is:suspicious  a direction control — the name shown is not the name sent
--   is:obfuscated  zero-width padding, which defeats a plain string match
local function marked(envelope, want)
  local _, bidi_a, pad_a = util.strip_invisible(util.address_label(envelope.from))
  local _, bidi_b, pad_b = util.strip_invisible(envelope.subject or "")
  if want == SUSPICIOUS then
    return bidi_a + bidi_b > 0
  end
  return pad_a + pad_b > 0
end

-- The query notmuch is actually asked, scoped to the mailbox on screen.
local function scoped_query(account, mailbox, query)
  local notmuch = require("leterejo.notmuch")
  return string.format(
    "(%s) and %s",
    to_notmuch_query(query),
    notmuch.query_for(account, mailbox)
  )
end

-- Whether a result can be read on, a batch at a time.
--
-- A query the index answers can: it is addressed by offset and resumes exactly
-- where it left off. A scan cannot — it already read as far as it was going to
-- and looked at every row, so there is no offset to continue from.
function M.resumable(query)
  local q = query and (ALIASES[tostring(query):lower()] or tostring(query):lower())
  return not (q and SCANNED[q])
end

-- How many messages a query reaches, or nil where that cannot be known cheaply.
function M.count(account, mailbox, query, on_done)
  if not M.resumable(query) then
    return on_done(true, nil)
  end
  local notmuch = require("leterejo.notmuch")
  return notmuch.count(account, scoped_query(account, mailbox, ALIASES[query:lower()] or query), false, on_done)
end

-- Run a query.
--
--   offset, limit: honoured for anything the index answers; a scan returns one
--                  batch whatever the offset says, so callers check
--                  M.resumable first.
--
--   on_done(ok, envelopes, info)
--     info.index   = the index answered, covering every message
--     info.scanned = how many messages were examined by a scan
function M.run(account, mailbox, query, offset, limit, on_done)
  query = vim.trim(query or "")
  if query == "" then
    return on_done(false, nil, nil)
  end

  query = ALIASES[query:lower()] or query

  local notmuch = require("leterejo.notmuch")

  -- The filters the index cannot answer. Read the mailbox and look.
  if SCANNED[query:lower()] then
    local want = query:lower()
    local cap = config.options.suspicious_scan_limit or 5000
    return notmuch.list_at(account, notmuch.query_for(account, mailbox), 0, cap, function(ok, res)
      if not ok then
        return on_done(false, res, nil)
      end

      local found = {}
      for _, e in ipairs(res) do
        if marked(e, want) then
          table.insert(found, e)
        end
      end
      -- Not resumable: the whole scan happened here, so there is no offset to
      -- continue from and the header reports the reach as a count.
      on_done(true, found, { scanned = #res })
    end)
  end

  local scoped = scoped_query(account, mailbox, query)
  return notmuch.list_at(account, scoped, offset or 0, limit or config.options.chunk_size, function(ok, res)
    if not ok then
      return on_done(false, res, nil)
    end
    on_done(true, res, { index = true })
  end)
end

return M
