-- Filtering messages.
--
-- himalaya v2's server-side search (`envelope search`) cannot handle non-ASCII.
-- Searching non-ASCII over IMAP requires a CHARSET argument and a synchronising
-- literal, which himalaya does not support, so it fails with
-- `BAD Could not parse command` (sending it through `imap raw` fails the same
-- way).
--
-- Queries containing non-ASCII therefore fetch a batch of envelopes and match
-- locally. Fetching 500 takes about 3.3 s, barely more than 100, because the
-- connection dominates and envelopes themselves are small.
local cli = require("leterejo.cli")
local config = require("leterejo.config")
local lang = require("leterejo.lang")
local util = require("leterejo.ui.util")

local M = {}

-- Whether a string is pure ASCII.
local function is_ascii(s)
  return s:match("^[%z\1-\127]*$") ~= nil
end

-- Whether the input is written in himalaya's query syntax.
--
-- Server-side search always requires naming the field (`from foo`,
-- `subject bar`). A bare word is a syntax error, so such input is routed to
-- local matching instead.
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

local function is_query_syntax(s)
  local first = s:match("^%s*([%w%-]+)")
  if not first then
    return s:match("^%s*%(") ~= nil -- a parenthesised nested filter
  end
  return QUERY_HEADS[first:lower()] == true
end

-- Split a form like "subject meeting" into the field and the term.
-- With no field named, return the term alone (matching subject and addresses).
local function split_field(query)
  local field, value = query:match("^%s*([%a%-]+)%s+(.+)$")
  if field and QUERY_HEADS[field:lower()] then
    return field:lower(), vim.trim(value)
  end
  return nil, vim.trim(query)
end

-- Whether an address list contains the term, checking name and address.
local function addr_matches(addrs, needle)
  for _, addr in ipairs(addrs or {}) do
    local name = addr.name
    if name ~= nil and name ~= vim.NIL and tostring(name):lower():find(needle, 1, true) then
      return true
    end
    if addr.email and tostring(addr.email):lower():find(needle, 1, true) then
      return true
    end
  end
  return false
end

-- Whether one message matches, evaluated locally.
--
-- Envelopes carry no body, so only the subject and addresses are visible.
-- Body search is impossible here: it would mean downloading every message.
local function matches(envelope, field, needle)
  needle = needle:lower()

  local subject = util.strip_invisible(envelope.subject or ""):lower()

  if field == "subject" then
    return subject:find(needle, 1, true) ~= nil
  elseif field == "from" then
    return addr_matches(envelope.from, needle)
  elseif field == "to" then
    return addr_matches(envelope.to, needle)
  elseif field == "flag" then
    for _, f in ipairs(envelope.flags or {}) do
      if tostring(f.iana):lower() == needle then
        return true
      end
    end
    return false
  end

  -- With no field named, look at the subject and both address lists.
  return subject:find(needle, 1, true) ~= nil
    or addr_matches(envelope.from, needle)
    or addr_matches(envelope.to, needle)
end

-- Accept the shape this plugin used before notmuch ("subject foo") as well as
-- notmuch's own ("subject:foo"), so the keys already in your fingers keep
-- working. Anything else is handed over untouched: notmuch understands far
-- more than the short list above.
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

-- Whether a result set can be read a batch at a time.
--
-- Only the local index can: it answers by offset in milliseconds. The other two
-- paths return one fixed batch — the server search collects UIDs and then
-- fetches them one by one, and local matching has to hold every envelope it
-- examined — so both stop where they stop.
function M.can_page(account, query)
  local q = query and (ALIASES[tostring(query):lower()] or tostring(query):lower())
  if q and SCANNED[q] then
    return false -- the scan already returned everything it is going to
  end
  return require("leterejo.notmuch").is_local(account)
end

-- How many messages a query reaches, or nil where that cannot be known cheaply.
function M.count(account, mailbox, query, on_done)
  if not M.can_page(account, query) then
    return on_done(true, nil)
  end
  local notmuch = require("leterejo.notmuch")
  return notmuch.count(scoped_query(account, mailbox, ALIASES[query:lower()] or query), false, on_done)
end

-- Run a query.
--
--   offset, limit: honoured on the local index; elsewhere one batch is
--                  returned whatever the offset says, so callers check
--                  M.can_page first.
--
--   on_done(ok, envelopes, info)
--     info.index   = the local index answered, covering every message
--     info.server  = whether the server did the filtering
--     info.scanned = how many messages were examined locally
function M.run(account, mailbox, query, offset, limit, on_done)
  query = vim.trim(query or "")
  if query == "" then
    return on_done(false, nil, nil)
  end

  query = ALIASES[query:lower()] or query

  local notmuch = require("leterejo.notmuch")

  -- The filters the index cannot answer. Read the mailbox and look.
  if SCANNED[query:lower()] then
    if not notmuch.is_local(account) then
      return on_done(false, lang.t("suspicious_needs_index"), nil)
    end

    local want = query:lower()
    local cap = config.options.suspicious_scan_limit or 5000
    return notmuch.list_at(notmuch.query_for(account, mailbox), 0, cap, function(ok, res)
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
      on_done(true, found, { server = false, scanned = #res })
    end)
  end

  -- With a local index there is no reason to sample: notmuch searches every
  -- message, body included, and answers in tens of milliseconds. Japanese
  -- works because the index was built with XAPIAN_CJK_NGRAM=1 — the very
  -- thing IMAP could not do at all, which is why the fallback below exists.
  if notmuch.is_local(account) then
    local scoped = scoped_query(account, mailbox, query)
    return notmuch.list_at(scoped, offset or 0, limit or config.options.chunk_size, function(ok, res)
      if not ok then
        return on_done(false, res, nil)
      end
      on_done(true, res, { index = true })
    end)
  end

  -- Pure ASCII written in the query syntax can go to the server, which
  -- covers every message and is the more reliable path.
  if is_ascii(query) and is_query_syntax(query) then
    local args = { "envelope", "search" }
    if mailbox then
      vim.list_extend(args, { "-m", mailbox })
    end
    vim.list_extend(args, { "-s", tostring(config.options.server_search_limit) })

    -- The query is variadic and positional, so it goes after the options.
    for _, word in ipairs(vim.split(query, "%s+")) do
      table.insert(args, word)
    end

    return cli.json(args, account, function(ok, res)
      if not ok then
        return on_done(false, res, nil)
      end
      on_done(true, res.envelopes or {}, { server = true })
    end)
  end

  -- Non-ASCII input, or a bare term with no field, is fetched in bulk and
  -- matched here.
  local field, needle = split_field(query)

  cli.list_envelopes(account, mailbox, 1, config.options.search_limit, function(ok, res)
    if not ok then
      return on_done(false, res, nil)
    end

    local found = {}
    for _, e in ipairs(res) do
      if matches(e, field, needle) then
        table.insert(found, e)
      end
    end

    on_done(true, found, { server = false, scanned = #res })
  end)
end

return M
