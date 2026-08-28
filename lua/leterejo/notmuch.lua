-- The notmuch call layer. Everything that reads comes through here.
--
-- notmuch answers from a local index, so a batch of fifty costs tens of
-- milliseconds instead of the two seconds an IMAP round trip took. Nothing here
-- talks to the network: what the index holds is what a sync put there.
--
-- The envelope shape below is the one the screen draws from — it began as
-- himalaya's, and stayed because there was no reason to change it.
--
-- Japanese search only works when the index was built with XAPIAN_CJK_NGRAM=1,
-- and the same variable has to be set when querying: without it a run of
-- Japanese is indexed as one word, so "勤怠管理" finds nothing inside
-- "ジョブカン勤怠管理". Two-character words happen to survive because a bigram
-- is the whole word, which makes the breakage easy to miss.
local config = require("leterejo.config")
local lang = require("leterejo.lang")

local M = {}

-- Which index an account reads and writes.
--
-- One per account, so that two accounts are two mailboxes rather than one heap.
-- A tag belongs to an account: both of these have an `inbox`, and if they
-- shared a database a message addressed to both would carry the union of their
-- labels and offer each account the other's on the next push.
--
-- Falls back to the shared configuration, which is the whole of it when there
-- is only one account.
local function notmuch_config(account)
  local a = (config.options.accounts or {})[account] or {}
  return a.notmuch_config or (config.options.notmuch or {}).config
end

-- The environment every call needs: the index to use, and the variable without
-- which Japanese cannot be searched (§13.4 of the design notes).
local function environment(account)
  local env = { XAPIAN_CJK_NGRAM = "1" }

  local path = notmuch_config(account)
  if path then
    env.NOTMUCH_CONFIG = vim.fn.expand(path)
  end
  return env
end

local function executable()
  return (config.options.notmuch or {}).executable or "notmuch"
end

-- Run notmuch asynchronously, against one account's index.
local function run(account, args, on_done)
  local env = environment(account)

  local cmd = { executable() }
  vim.list_extend(cmd, args)

  vim.system(cmd, { text = true, env = env }, function(res)
    -- vim.system finishes in a fast-event context where touching the screen
    -- crashes; hop back to the main loop first.
    vim.schedule(function()
      if res.code == 0 then
        on_done(true, res.stdout or "")
      else
        local first = (res.stderr or ""):match("([^\n]+)")
        on_done(false, first or lang.t("err_notmuch"))
      end
    end)
  end)
end

local function run_json(account, args, on_done)
  run(account, args, function(ok, out)
    if not ok then
      return on_done(false, out)
    end
    if vim.trim(out) == "" then
      return on_done(true, {})
    end
    local decoded_ok, decoded = pcall(vim.json.decode, out)
    if not decoded_ok then
      return on_done(false, lang.t("err_json", tostring(decoded)))
    end
    on_done(true, decoded)
  end)
end

-- Shaping ---------------------------------------------------------------

-- Decode one RFC 2047 encoded word.
--
-- Japanese mail encodes header text this way constantly, usually in
-- ISO-2022-JP, so the bytes have to be converted as well as decoded.
local function decode_word(charset, encoding, body)
  local raw

  if encoding:lower() == "b" then
    local ok, decoded = pcall(vim.base64.decode, body)
    raw = ok and decoded or nil
  else
    -- Q encoding: underscore is a space, and =XX is a byte.
    raw = body:gsub("_", " "):gsub("=(%x%x)", function(hex)
      return string.char(tonumber(hex, 16))
    end)
  end

  if not raw then
    return nil
  end

  -- A charset may carry a language after a star (`utf-8*ja`), which is about
  -- the text and not about the bytes; iconv would not know the name.
  charset = charset:gsub("%*.*$", "")

  if charset:lower() == "utf-8" or charset:lower() == "us-ascii" then
    return raw
  end
  return vim.iconv(raw, charset, "utf-8")
end

-- Turn a header value into the text it stands for.
--
-- Whitespace between two encoded words is not content — it is there so the
-- line can be folded — so it goes. This is the rule notmuch is not applying:
-- it takes the first word and stops, which is why a name arrives cut off at
-- whatever the first word happened to end on.
--
-- The charset is read as "everything up to the next ?" rather than as letters
-- and hyphens: `shift_jis` has an underscore in it and was left undecoded on
-- the screen, encoded word and all. Eight messages here, which is few enough
-- to have gone unnoticed and too many to leave unreadable.
local function decode_words(value)
  value = value:gsub("(%?=)%s+(=%?)", "%1%2")

  return (value:gsub("=%?([^%?]+)%?([BbQq])%?(.-)%?=", function(charset, encoding, body)
    return decode_word(charset, encoding, body)
      or ("=?" .. charset .. "?" .. encoding .. "?" .. body .. "?=")
  end))
end

-- Decode a header value for anything outside this module that shows one.
--
-- Exposed because the raw view needs it: a header block read off the disk is
-- the only honest thing to show when the question is what actually arrived,
-- and an encoded word in it is unreadable while still being the truth. Both go
-- on the screen, which is why the decoding has to be reachable from there.
function M.decode_header(value)
  return decode_words(tostring(value or ""))
end

-- Read the headers this screen shows from a message file, decoded.
--
-- Because notmuch's own decoding stops at the first encoded word: a subject
-- written in ISO-2022-JP arrives cut off part way through — 22% of a recent
-- sample here — and an attachment's name loses its extension the same way.
--
-- Only the two headers read at a glance are taken, and the file is opened
-- once for both. The header block is at the front, so a few kilobytes is
-- enough: 200 messages cost a few milliseconds altogether, against the tens
-- that listing them costs anyway.
local HEADER_BYTES = 8192

-- Built once. A case-insensitive class per letter is what Lua patterns offer,
-- and building these per message was most of the cost of doing this at all.
local function header_pattern(name)
  local out = "\n"
  for c in name:gmatch(".") do
    if c:match("%a") then
      out = out .. "[" .. c:upper() .. c:lower() .. "]"
    else
      -- Anything else goes in literally, escaped: "message-id" has a hyphen,
      -- and a hyphen in a pattern is not a hyphen.
      out = out .. "%" .. c
    end
  end
  return out .. ":[ \t]*(.-)\r?\n[^ \t]"
end

local SUBJECT_PATTERN = header_pattern("subject")
local FROM_PATTERN = header_pattern("from")
local MESSAGE_ID_PATTERN = header_pattern("message-id")

local function headers_from_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil, nil
  end

  local text = f:read(HEADER_BYTES) or ""
  f:close()

  -- Stop at the blank line: what follows is the body, which may well contain
  -- something shaped like a header. The sentinel line at the end lets a header
  -- sitting last still match.
  local head = "\n" .. (text:match("^(.-)\r?\n\r?\n") or text) .. "\n."

  local function value(pattern)
    local found = head:match(pattern)
    if not found then
      return nil
    end
    -- Folded across lines; the fold is not part of the value.
    return decode_words(vim.trim((found:gsub("\r?\n[ \t]+", " "))))
  end

  -- The id as notmuch spells it: without the angle brackets it is written in.
  local id = head:match(MESSAGE_ID_PATTERN)
  id = id and vim.trim(id):match("^<?(.-)>?$") or nil

  return value(SUBJECT_PATTERN), value(FROM_PATTERN), id
end

local function parse_addrs(line)
  local out = {}
  for _, part in ipairs(vim.split(line or "", ",", { plain = true })) do
    part = vim.trim(part)
    if part ~= "" then
      local name, email = part:match("^(.-)%s*<([^>]+)>$")
      if email then
        name = vim.trim((name or ""):gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1"))
        table.insert(out, { name = name ~= "" and name or nil, email = email })
      else
        table.insert(out, { email = part })
      end
    end
  end
  return out
end

-- notmuch reports seconds since the epoch; the screen parses ISO 8601.
-- Emitting the Z form keeps ui/util.lua unchanged.
local function iso8601(timestamp)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", timestamp or 0)
end

-- Tags carry what IMAP calls flags. Maildir keeps them in the file name and
-- notmuch mirrors them when maildir.synchronize_flags is on, so these travel
-- back to the server through the sync.
local function flags_of(tags)
  local has = {}
  for _, t in ipairs(tags or {}) do
    has[t] = true
  end

  local flags = {}
  -- Absence means read: notmuch tags what is unread, not what is read.
  if not has.unread then
    table.insert(flags, { iana = "Seen" })
  end
  if has.flagged then
    table.insert(flags, { iana = "Flagged" })
  end
  if has.replied then
    table.insert(flags, { iana = "Answered" })
  end
  if has.draft then
    table.insert(flags, { iana = "Draft" })
  end
  return flags
end

local function envelope_of(msg)
  local h = msg.headers or {}
  local tags = msg.tags or {}

  -- What notmuch reports, corrected from the file where it is wrong.
  --
  -- Only the two headers that are read at a glance: the subject, and who it is
  -- from. Both routinely carry several encoded words in Japanese mail, and
  -- both are shown in the list.
  local path = (config.options.notmuch or {}).repair_headers ~= false
    and type(msg.filename) == "table"
    and msg.filename[1]
    or nil

  local subject, from = h.Subject or "", h.From

  if path then
    local file_subject, file_from = headers_from_file(path)
    subject = file_subject or subject
    from = file_from or from
  end

  local has_attachment = false
  for _, t in ipairs(tags) do
    if t == "attachment" then
      has_attachment = true
      break
    end
  end

  return {
    -- The Message-ID, which is the only handle notmuch looks a message up by.
    -- Reading and writing now agree on that, since writing is tagging.
    id = msg.id,
    subject = subject,
    from = parse_addrs(from),
    to = parse_addrs(h.To),
    cc = parse_addrs(h.Cc),
    date = iso8601(msg.timestamp),
    flags = flags_of(tags),
    ["has-attachment"] = has_attachment,
  }
end

-- `notmuch show` nests messages inside threads inside replies. Rather than
-- walking that shape by index, collect every object that carries headers.
local function collect_messages(node, out)
  if type(node) ~= "table" then
    return out
  end
  if node.headers ~= nil and node.id ~= nil then
    table.insert(out, node)
  end
  for _, child in pairs(node) do
    collect_messages(child, out)
  end
  return out
end

-- Queries ---------------------------------------------------------------

-- Quote a message id for use in a query. Ids routinely contain $ and other
-- characters the query parser would otherwise read as syntax.
local function id_query(id)
  return 'id:"' .. tostring(id):gsub('"', '\\"') .. '"'
end

-- The orders notmuch itself can put a result in.
--
-- Two of its four are no use to a reader: `message-id` and `unsorted` order a
-- list by nothing that is on the screen. The orders that are missing — by
-- sender, by subject — are not notmuch's to give at all: it sorts by date and
-- by nothing else. Those are done here, over a list that has been read whole,
-- which is why they are handled in the list buffer rather than passed down.
local NOTMUCH_SORT = {
  newest = "newest-first",
  oldest = "oldest-first",
}

-- The flag for an order, falling back to newest-first for the ones notmuch
-- cannot give: the rows still have to arrive in some defined order before they
-- can be sorted into another.
function M.sort_flag(sort)
  return NOTMUCH_SORT[sort] or "newest-first"
end

-- Fetch a run of envelopes for a query, starting at an offset.
--
-- Two calls: the first settles which messages and in what order, the second
-- fetches their headers. `show` groups by thread and would otherwise lose the
-- ordering, so the result is put back in the order the search returned.
--
-- Addressed by offset rather than by page: the list grows as it is scrolled and
-- knows how many rows it holds, not which page it is on.
function M.list_at(account, query, offset, size, sort, on_done)
  offset = offset or 0
  size = size or 50

  run(account, {
    "search",
    "--format=json",
    "--output=messages",
    "--sort=" .. M.sort_flag(sort),
    "--offset=" .. offset,
    "--limit=" .. size,
    query,
  }, function(ok, out)
    if not ok then
      return on_done(false, out)
    end

    local decoded_ok, ids = pcall(vim.json.decode, vim.trim(out) ~= "" and out or "[]")
    if not decoded_ok or type(ids) ~= "table" or #ids == 0 then
      return on_done(true, {})
    end

    -- The second call names every message, and the whole disjunction goes as
    -- one argument. A few hundred is fine; a few thousand exceeds what the
    -- kernel will accept in an argv and the spawn fails with E2BIG. So ask in
    -- groups, and put the answers back in the order the search gave.
    local GROUP = 250
    local by_id, pending, failed = {}, 0, nil

    local function finish()
      if pending > 0 then
        return
      end
      if failed then
        return on_done(false, failed)
      end

      local envelopes = {}
      for _, id in ipairs(ids) do
        local msg = by_id[id]
        if msg then
          table.insert(envelopes, envelope_of(msg))
        end
      end
      on_done(true, envelopes)
    end

    for start = 1, #ids, GROUP do
      local parts = {}
      for i = start, math.min(start + GROUP - 1, #ids) do
        table.insert(parts, id_query(ids[i]))
      end

      pending = pending + 1
      run_json(account, {
        "show",
        "--format=json",
        "--body=false",
        "--entire-thread=false",
        table.concat(parts, " or "),
      }, function(ok2, tree)
        if ok2 then
          for _, msg in ipairs(collect_messages(tree, {})) do
            by_id[msg.id] = msg
          end
        else
          failed = failed or tree
        end
        pending = pending - 1
        finish()
      end)
    end
  end)
end

-- How many messages, or how many threads, a query reaches.
--
-- The list needs this to know when it has everything: without a total there is
-- no way to tell "the last batch was short because we reached the end" from
-- "the last batch was short because something went wrong", and the list would
-- keep asking for more forever.
function M.count(account, query, threaded, on_done)
  run(account, {
    "count",
    threaded and "--output=threads" or "--output=messages",
    query,
  }, function(ok, out)
    if not ok then
      return on_done(false, out)
    end
    on_done(true, tonumber(vim.trim(out)) or 0)
  end)
end

-- The ids notmuch lists for a thread, oldest first.
--
-- `search` reports each thread with the query that selects its matching
-- messages, shaped as "id:a id:b id:c". That is not usable as a query — space
-- means AND, so it would match nothing — but the ids in it are what we want.
local function ids_in(query)
  local ids = {}
  for token in tostring(query or ""):gmatch("%S+") do
    if token:sub(1, 3) == "id:" then
      table.insert(ids, token:sub(4))
    end
  end
  return ids
end

-- Who took part in a thread.
--
-- `search` reports display names only, never addresses, and separates the
-- people whose messages matched the query from those whose did not with a
-- vertical bar. The distinction is not worth a column, so both sides are shown
-- in the order given.
local function authors_of(authors)
  local out = {}
  for _, name in ipairs(vim.split(tostring(authors or ""):gsub("|", ","), ",", { plain = true })) do
    name = vim.trim(name)
    if name ~= "" then
      table.insert(out, { name = name })
    end
  end
  return out
end

-- Fetch one batch of threads for a query.
--
-- One call, unlike the message listing: `search` summarises each thread with
-- everything a row needs — subject, who took part, how many messages, the tags
-- of the whole thread — so there is nothing to look up afterwards. 200 threads
-- come back in 40 ms.
--
-- The representative message is the last id notmuch lists, which is the newest:
-- it orders a thread's messages oldest first. Checked against every
-- multi-message thread in a 9,000-message inbox, but fall back to the first id
-- rather than nothing if a future version disagrees.
function M.list_threads(account, query, offset, limit, sort, on_done)
  run(account, {
    "search",
    "--format=json",
    "--output=summary",
    "--sort=" .. M.sort_flag(sort),
    "--offset=" .. tostring(offset or 0),
    "--limit=" .. tostring(limit or 200),
    query,
  }, function(ok, out)
    if not ok then
      return on_done(false, out)
    end

    local decoded_ok, threads = pcall(vim.json.decode, vim.trim(out) ~= "" and out or "[]")
    if not decoded_ok or type(threads) ~= "table" then
      return on_done(true, {})
    end

    local rows = {}
    for _, t in ipairs(threads) do
      local ids = ids_in((t.query or {})[1])
      local id = ids[#ids] or ids[1]
      if id then
        table.insert(rows, {
          id = id,
          thread = t.thread,
          -- The thread's own tags are the union over its messages, so a thread
          -- holding one unread message reads as unread. That is what the
          -- collapsed row should say.
          subject = t.subject or "",
          from = authors_of(t.authors),
          date = iso8601(t.timestamp),
          flags = flags_of(t.tags),
          ["has-attachment"] = vim.tbl_contains(t.tags or {}, "attachment"),
          thread_total = t.total or 1,
          thread_matched = t.matched or 1,
        })
      end
    end

    -- A thread's subject comes from the summary, which is decoded the same
    -- way and cut off the same way. The row stands for one message, so its
    -- file is where the whole subject is.
    --
    -- The files are asked for in one search rather than by fetching each
    -- message's metadata: that costs a fifth as much, and the file itself says
    -- which message it holds, so nothing has to line up by position.
    if (config.options.notmuch or {}).repair_headers == false or #rows == 0 then
      return on_done(true, rows)
    end

    local ids = {}
    for _, row in ipairs(rows) do
      table.insert(ids, id_query(row.id))
    end

    run(account, { "search", "--output=files", table.concat(ids, " or ") }, function(ok2, out2)
      if ok2 then
        local subject_of = {}
        for path in tostring(out2):gmatch("[^\n]+") do
          local subject, _, id = headers_from_file(vim.trim(path))
          if id and subject then
            subject_of[id] = subject
          end
        end

        for _, row in ipairs(rows) do
          row.subject = subject_of[row.id] or row.subject
        end
      end

      on_done(true, rows)
    end)
  end)
end

-- The messages of one thread.
--
-- Only fetched when a thread is expanded. A long thread costs real time — 460
-- ms for one of 174 messages — which is why this is not done for every row up
-- front.
function M.thread_messages(account, thread, on_done)
  run_json(account, {
    "show",
    "--format=json",
    "--body=false",
    "--entire-thread=true",
    "thread:" .. tostring(thread),
  }, function(ok, tree)
    if not ok then
      return on_done(false, tree)
    end

    local envelopes = {}
    for _, msg in ipairs(collect_messages(tree, {})) do
      table.insert(envelopes, envelope_of(msg))
    end

    -- `show` walks a thread in reply order, which is close to but not exactly
    -- chronological once a branch is answered late.
    --
    -- Oldest first by default, which is how a conversation reads. Newest first
    -- suits a long thread one is following rather than reading through, where
    -- what matters is at the bottom otherwise.
    local newest_first = config.options.thread_order == "newest"

    table.sort(envelopes, function(a, b)
      if newest_first then
        return tostring(a.date) > tostring(b.date)
      end
      return tostring(a.date) < tostring(b.date)
    end)

    on_done(true, envelopes)
  end)
end

-- Feed a string to a command and collect what it writes back.
local function pipe_through(cmd, input, on_done)
  vim.system(cmd, { text = true, stdin = input }, function(res)
    vim.schedule(function()
      on_done(res.code == 0, res.stdout or "")
    end)
  end)
end

-- Find the first text/html part of a message.
-- Which part holds the markup, and which text part says the same thing.
--
-- A client that sends multipart/alternative sends one message twice. The two
-- ids come back together so that whichever is shown, the other can be taken
-- out: see M.read. The plain id is returned only for a genuine alternative —
-- a text part that is a part in its own right, as in multipart/mixed, is not
-- something to drop.
local function html_part_id(account, id, on_done)
  run_json(account, {
    "show",
    "--format=json",
    "--body=true",
    "--entire-thread=false",
    id_query(id),
  }, function(ok, tree)
    if not ok then
      return on_done(nil)
    end

    local found, twin
    local function walk(node)
      if type(node) ~= "table" then
        return
      end

      if found == nil and node["content-type"] == "text/html" and node.id ~= nil then
        found = node.id
      end

      if node["content-type"] == "multipart/alternative" and type(node.content) == "table" then
        local html, plain
        for _, child in ipairs(node.content) do
          if type(child) == "table" then
            if child["content-type"] == "text/html" then
              html = child.id
            elseif child["content-type"] == "text/plain" then
              plain = child.id
            end
          end
        end
        if html and plain then
          found, twin = html, plain
        end
      end

      for _, child in pairs(node) do
        walk(child)
      end
    end
    walk(tree)
    on_done(found, twin)
  end)
end

-- Render a message body as text.
--
-- The markup is left out on the first attempt. Asking for it costs notmuch
-- nothing — every call measured under 20 ms — but it inflates the text by ten
-- to seventeen times (9 kB becomes 123 kB, and the worst message here reaches
-- 172 kB). Pouring that into a buffer is what the delay actually was.
--
-- Mail carrying no plain part would then show nothing, and in this mailbox
-- that is 54% of it — the majority, not an edge case. Such messages go through
-- an HTML renderer, which both shrinks them and finally makes them readable:
-- until now they arrived as raw tags, under himalaya too.
-- Take notmuch's structure markers back out of a rendered message.
--
-- `show --format=text` wraps everything in form-feed delimiters — "\fmessage{",
-- "\fheader}", "\fpart{ ID: 2, Content-type: text/plain" and so on. They are
-- there for a program to parse, and reading one at the foot of every message is
-- exactly the sort of thing that makes a client feel unfinished.
--
-- A closing marker is not always on a line of its own: notmuch appends "\fpart}"
-- to the last line of the content, so dropping whole lines is not enough.
--
-- "\fheader}" becomes a blank line rather than nothing, because that blank is
-- what tells the message buffer where the headers stop and the body starts.
-- Fit the HTML renderer's line length to the window it will be read in.
--
-- w3m lays out tables to the width it is given, so a fixed column count means a
-- table is either cut off on a narrow screen or huddled in the corner of a wide
-- one. The configured value stays as the fallback for when there is no window
-- to measure — during a background fetch, say.
function M.render_width(renderer)
  local cols
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(buf):match("leterejo://message$") then
      cols = vim.api.nvim_win_get_width(w)
      break
    end
  end
  cols = cols or vim.o.columns

  local out = vim.deepcopy(renderer)
  for i, arg in ipairs(out) do
    if arg == "-cols" and out[i + 1] then
      -- Leave a little room: a body drawn hard against the edge is unpleasant,
      -- and 'wrap' would fold the overflow onto a line of its own.
      out[i + 1] = tostring(math.max(40, cols - 2))
      return out
    end
  end
  return out
end

-- Remove one part, and whatever it contains, from marked `show` output.
--
-- The markers are the only thing that says where one part ends: the text
-- itself has no boundary, and the parts of an alternative are the same words.
-- So this runs before strip_markers, on output that still has them.
local function without_part(text, part)
  local out, depth = {}, nil

  for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
    if depth == nil and line:match("^\012part{ ID: " .. tostring(part) .. ",") then
      depth = 1
    elseif depth ~= nil then
      if line:match("^\012part{") then
        depth = depth + 1
      elseif line:match("^\012part}") then
        depth = depth - 1
        if depth == 0 then
          depth = nil
        end
      end
    else
      table.insert(out, line)
    end
  end

  return table.concat(out, "\n")
end

local function strip_markers(text)
  local out = {}

  for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
    if line:match("^\012header}") then
      table.insert(out, "")
    elseif not line:match("^\012%a+[{}]") then
      table.insert(out, (line:gsub("\012%a+}%s*$", "")))
    end
  end

  return table.concat(out, "\n")
end

-- The message exactly as it arrived, headers and all.
--
-- `show --format=text`, which M.read below uses, hands over four headers —
-- Subject, From, To, Date — out of the twenty-eight a message here actually
-- carries, so nothing built on it can answer "what did the server say about
-- this". This reads the file.
function M.raw(account, id, on_done)
  run(account, { "show", "--format=raw", "--entire-thread=false", id_query(id) }, on_done)
end

-- Reading a rendering ---------------------------------------------------------
--
-- Two things w3m does that make mail harder to read than it was written, both
-- measured over the mail here rather than assumed.

-- Marks around a quotation, put in before the renderer runs and taken out
-- after. w3m indents a <blockquote> and marks it no further, and indentation
-- alone does not read as someone else's words. Written as characters no mail
-- here contains, so a message that happens to hold one is not misread.
local QUOTE_OPEN, QUOTE_CLOSE = "\239\191\185q\239\191\185", "\239\191\185/q\239\191\185"

local function mark_quotations(html)
  html = html:gsub("<[bB][lL][oO][cC][kK][qQ][uU][oO][tT][eE][^>]*>", "%0" .. QUOTE_OPEN)
  return (html:gsub("</[bB][lL][oO][cC][kK][qQ][uU][oO][tT][eE]%s*>", QUOTE_CLOSE .. "%0"))
end

-- Undo the blank line between every line.
--
-- Outlook writes each line of a message as its own paragraph, and w3m puts a
-- blank line between one block and the next. A message the sender typed with
-- no blank lines in it therefore arrives with more blank lines than text:
-- 175 of 301 lines in the one this was written for.
--
-- What the sender did type survives as a line holding a non-breaking space,
-- which is how the two are told apart — the empty lines are the renderer's and
-- go, the ones with something on them are the sender's and become the blank.
--
-- Only when the rendering is double-spaced throughout: measured as the share
-- of text lines standing alone between two blanks. Over 148 messages here that
-- share separates mail people write (85-100%) from mail that is generated
-- (0-20%), where the blank lines are the only paragraphs there are.
local function single_spaced(text)
  if ((config.options.notmuch or {}).collapse_blank_lines) == false then
    return text
  end

  local lines = vim.split(text or "", "\n", { plain = true })

  -- A line holding nothing but a quotation mark is not the sender's line: it
  -- was put there to be taken out again, and counting it as text would make
  -- every quoted message look double-spaced.
  local function is_text(line)
    line = (line or ""):gsub(QUOTE_OPEN, ""):gsub(QUOTE_CLOSE, "")
    return vim.trim(line) ~= ""
  end

  local written, alone = 0, 0
  for i, line in ipairs(lines) do
    if is_text(line) then
      written = written + 1
      if not is_text(lines[i - 1]) and not is_text(lines[i + 1]) then
        alone = alone + 1
      end
    end
  end

  if written < 6 or alone / written < 0.6 then
    return text
  end

  local out = {}
  for _, line in ipairs(lines) do
    if line == "" then -- the renderer's
      -- dropped
    elseif line:match("^%s+$") then -- the sender's
      if #out > 0 and out[#out] ~= "" then
        table.insert(out, "")
      end
    else
      table.insert(out, line)
    end
  end

  return table.concat(out, "\n")
end

-- Show quoted text as quoted.
--
-- Two kinds, because mail comes in two kinds. A <blockquote> is marked before
-- the renderer runs, above. Outlook does not use one: it appends the message
-- being answered under a header block and leaves it at that, so the block is
-- the boundary and everything below it is someone else's words.
--
-- Of 373 messages here that carry HTML, 18 quote with <blockquote> and 79 the
-- Outlook way.
local QUOTE_HEAD = { "From", "Sent", "差出人", "送信者", "送信日時" }

local function quotation_starts_at(lines)
  local function heads(line, which)
    for _, name in ipairs(which) do
      if line:match("^%s*" .. name .. "%s*:") then
        return true
      end
    end
    return false
  end

  for i, line in ipairs(lines) do
    if heads(line, { "From", "差出人", "送信者" }) then
      -- A line that only looks like a header is not one. The block has a
      -- second line naming when it was sent, within a line or two of the
      -- first, and prose does not.
      for j = i + 1, math.min(i + 5, #lines) do
        if heads(lines[j], { "Sent", "送信日時", "日時" }) then
          return i
        end
      end
    end
  end
  return nil
end

local function with_quote_marks(text)
  local prefix = (config.options.notmuch or {}).quote_prefix
  if prefix == nil then
    prefix = "> "
  end

  local lines = vim.split(text or "", "\n", { plain = true })
  local out, depth = {}, 0

  -- The marks come out either way; what they are for is optional, they are not.
  local strip_only = type(prefix) ~= "string" or prefix == ""

  for _, line in ipairs(lines) do
    local opened, closed = 0, 0
    line, opened = line:gsub(QUOTE_OPEN, "")
    line, closed = line:gsub(QUOTE_CLOSE, "")

    -- A mark of its own is not a line of the message. w3m gives it one because
    -- it sits between two blocks, and leaving it in would leave a blank line
    -- at each end of every quotation.
    local was_a_mark = (opened + closed) > 0 and vim.trim(line) == ""

    depth = depth + opened
    if not strip_only and depth > 0 and not was_a_mark then
      -- w3m indents a quotation by four columns a level. That was its way of
      -- saying what the marks now say, so it goes.
      local room = 4 * depth
      line = line:gsub("^( +)", function(spaces)
        return spaces:sub(math.min(#spaces, room) + 1)
      end)
      line = (prefix:rep(depth) .. line):gsub("%s+$", "")
    end
    depth = math.max(0, depth - closed)

    if not was_a_mark then
      table.insert(out, line)
    end
  end

  if strip_only then
    return table.concat(out, "\n")
  end

  -- The Outlook kind, which has no marks to find: from the header block down.
  local from = quotation_starts_at(out)
  if from then
    for i = from, #out do
      out[i] = vim.trim(prefix) .. (out[i] ~= "" and " " .. out[i] or "")
    end
  end

  return table.concat(out, "\n")
end

-- Whether a rendering carries a table the text half does not.
--
-- A row is a line holding three or more fields separated by runs of two or
-- more spaces: what w3m makes of a table, and what prose does not look like.
-- The text half is measured the same way, because a sender who lined a table
-- up by hand has one on both sides and there is nothing to gain by switching.
local function carries_a_table(rendered, text)
  local function rows(s)
    local n = 0
    for _, line in ipairs(vim.split(s or "", "\n", { plain = true })) do
      if line:find("%S%s%s+%S.-%s%s+%S") then
        n = n + 1
      end
    end
    return n
  end

  local found = rows(rendered)
  return found >= 2 and found > rows(text)
end

-- Read a message body.
--
-- `opts.alternative` overrides the setting of the same name for this read,
-- which is how the key that switches halves asks for the other one. The third
-- value handed to `on_done` says which half was shown — "html", "plain", or
-- nil when the message was not sent twice and there is nothing to switch to.
function M.read(account, id, on_done, opts)
  opts = opts or {}

  -- The markers are kept until the last moment: which alternative is shown is
  -- decided by taking the other one out, and only the markers say where it is.
  local function show(extra, cb)
    local args = { "show", "--format=text", "--entire-thread=false" }
    vim.list_extend(args, extra)
    table.insert(args, id_query(id))
    run(account, args, cb)
  end

  -- Fall back to the raw markup, which is what came before.
  local function raw(cb)
    show({ "--include-html" }, function(ok, out)
      cb(ok, ok and strip_markers(out) or out)
    end)
  end

  show({}, function(ok, out)
    if not ok then
      return on_done(false, out)
    end

    local marker = "Non-text part: text/html"
    if not out:find(marker, 1, true) then
      return on_done(true, strip_markers(out))
    end

    local renderer = (config.options.notmuch or {}).html_renderer
    if not renderer or vim.fn.executable(renderer[1]) ~= 1 then
      return raw(on_done)
    end
    renderer = M.render_width(renderer)

    html_part_id(account, id, function(part, twin)
      if not part then
        return raw(on_done)
      end

      run(account, {
        "show",
        "--format=raw",
        "--part=" .. tostring(part),
        "--entire-thread=false",
        id_query(id),
      }, function(ok2, html)
        if not ok2 or html == "" then
          return raw(on_done)
        end

        -- One message, said twice. Which half to keep.
        --
        -- The text half is what the sender's client wrote and usually reads
        -- better — except for a table, which it cannot express: Outlook writes
        -- a pasted spreadsheet as one cell per line, every column unfolded into
        -- a single column. That is the one thing the rendering carries and the
        -- text does not, so it decides.
        local choice = opts.alternative or (config.options.notmuch or {}).alternative or "auto"

        if twin and choice == "plain" then
          return on_done(true, strip_markers(without_part(out, part)), "plain")
        end

        pipe_through(renderer, mark_quotations(html), function(ok3, text)
          if not ok3 or vim.trim(text) == "" then
            return raw(on_done)
          end

          -- What the renderer made of it, made readable: the blank line it put
          -- between every line taken back out, and quoted text marked as such.
          text = with_quote_marks(single_spaced(text))

          -- "auto" asks the rendering itself rather than the markup. A table
          -- is what the text half cannot carry, and a table is what w3m lays
          -- out in columns — so a rendering with rows in it, where the text has
          -- none, is a rendering that says something the text does not.
          -- Measured over 112 messages here: the markup is no guide, since a
          -- newsletter is built out of tables too and carries the same Word
          -- markers as a colleague's spreadsheet.
          if twin and choice ~= "html" and not carries_a_table(text, out) then
            return on_done(true, strip_markers(without_part(out, part)), "plain")
          end

          if twin then
            out = without_part(out, twin)
          end

          -- Put the rendering where notmuch said there was nothing to read.
          on_done(
            true,
            strip_markers((out:gsub(vim.pesc(marker), (text:gsub("%%", "%%%%")), 1))),
            twin and "html" or nil
          )
        end)
      end)
    end)
  end)
end

-- Repairing an attachment's name -----------------------------------------
--
-- notmuch cuts a filename at an opening parenthesis:
--
--   raw:      filename="2026年8月報告(山田).pdf"
--   reported: 72期8月技術関連報告(
--
-- A parenthesis opens a comment in a structured header, but not inside a
-- quoted string, and this one is inside one. Japanese mail puts names and
-- notes in parentheses constantly, so this is not an edge case here — and what
-- is lost includes the extension, which is what decides how the file opens.
--
-- So a name that looks cut is looked up in the message itself. Only a
-- candidate that begins with what notmuch reported is accepted, which keeps a
-- guess from turning into a different attachment's name.

local function looks_cut(name)
  if name:match("%.[%w]+$") then
    return false -- it still has an extension; leave it alone
  end
  local opens = select(2, name:gsub("%(", ""))
  local closes = select(2, name:gsub("%)", ""))
  return opens > closes or name:sub(-1) == "("
end

-- The filenames written in a message file, as they appear in the headers.
--
-- Read rather than parsed: a MIME parser is not the thing to write here, and
-- an accepted candidate has to match what notmuch already reported anyway.
-- Capped, because a message can be tens of megabytes of base64 and the names
-- are all in the first part of it.
local function names_in(path)
  local f = io.open(path, "rb")
  if not f then
    return {}
  end

  local text = f:read(2 * 1024 * 1024) or ""
  f:close()

  local found = {}
  for _, pattern in ipairs({ '[Ff]ilename%s*=%s*"([^"]*)"', '%f[%w][Nn]ame%s*=%s*"([^"]*)"' }) do
    for value in text:gmatch(pattern) do
      -- A long value is folded across lines; the fold is not part of it.
      value = value:gsub("\r?\n[ \t]+", "")
      table.insert(found, decode_words(value))
    end
  end
  return found
end

-- Ask notmuch which files hold this message.
local function files_of(account, id, on_done)
  run(account, { "search", "--output=files", id_query(id) }, function(ok, out)
    if not ok then
      return on_done({})
    end

    local paths = {}
    for line in tostring(out):gmatch("[^\n]+") do
      if vim.trim(line) ~= "" then
        table.insert(paths, vim.trim(line))
      end
    end
    on_done(paths)
  end)
end

-- Put back what notmuch cut off, where it can be found.
local function repaired(account, id, attachments, on_done)
  local damaged = false
  for _, att in ipairs(attachments) do
    damaged = damaged or looks_cut(att.name)
  end

  if not damaged then
    return on_done(true, attachments)
  end

  files_of(account, id, function(paths)
    local candidates = {}
    for _, path in ipairs(paths) do
      vim.list_extend(candidates, names_in(path))
    end

    for _, att in ipairs(attachments) do
      if looks_cut(att.name) then
        for _, candidate in ipairs(candidates) do
          -- Anything still carrying an encoded word failed to decode; showing
          -- that to the user would be worse than the truncation.
          if not candidate:find("=?", 1, true)
            and #candidate > #att.name
            and candidate:sub(1, #att.name) == att.name
          then
            att.name = candidate
            break
          end
        end
      end
    end

    on_done(true, attachments)
  end)
end

-- List the attachments of a message.
--
-- Names come back already decoded, so the RFC 2047 handling the IMAP path
-- needed does not apply here.
function M.attachments(account, id, on_done)
  run_json(account, {
    "show",
    "--format=json",
    "--body=true",
    "--entire-thread=false",
    id_query(id),
  }, function(ok, tree)
    if not ok then
      return on_done(false, tree)
    end

    local found = {}
    local function walk(node)
      if type(node) ~= "table" then
        return
      end
      local name = node.filename
      local ctype = tostring(node["content-type"] or "")

      -- An image referenced from the HTML by `cid:` is often sent with no
      -- filename at all. It is still a part worth listing — it is what the
      -- message meant to show — so give it one.
      if (name == nil or name == "" or name == vim.NIL) and ctype:match("^image/") and node.id then
        name = "image-" .. tostring(node.id) .. "." .. (ctype:match("^image/([%w%-]+)") or "img")
      end

      -- A message carries `filename` as an array of paths on disk; a MIME part
      -- carries it as the attachment's own name. Only the latter is wanted.
      if type(name) == "string" and name ~= "" then
        table.insert(found, {
          -- Same shape ui/util.lua's collect_attachments produces, so the
          -- screen cannot tell which layer answered. Names arrive decoded
          -- here, so no RFC 2047 handling is needed.
          name = name,
          content_type = node["content-type"] or "",
          size = node["content-length"] or 0,
          -- Which part to hand to `notmuch show --part=` when saving it.
          part = node.id,
        })
      end
      for _, child in pairs(node) do
        walk(child)
      end
    end
    walk(tree)
    repaired(account, id, found, on_done)
  end)
end

-- Pick a path that does not overwrite anything, the way himalaya does it.
-- The extension a part of this type should be saved under.
--
-- A name can arrive damaged (see repaired below), and what opens the file
-- afterwards decides by extension — `vecview` refuses a PDF that is not called
-- one. The type does not arrive damaged, so it is the thing to trust.
local EXTENSIONS = {
  ["application/pdf"] = "pdf",
  ["application/zip"] = "zip",
  ["application/msword"] = "doc",
  ["application/vnd.ms-excel"] = "xls",
  ["application/vnd.ms-powerpoint"] = "ppt",
  ["application/vnd.openxmlformats-officedocument.wordprocessingml.document"] = "docx",
  ["application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"] = "xlsx",
  ["application/vnd.openxmlformats-officedocument.presentationml.presentation"] = "pptx",
  ["image/jpeg"] = "jpg",
  ["image/svg+xml"] = "svg",
  ["text/plain"] = "txt",
  ["text/html"] = "html",
  ["message/rfc822"] = "eml",
}

function M.extension_for(content_type)
  local ct = tostring(content_type or ""):lower():match("^[^;]*")
  ct = ct and vim.trim(ct) or ""

  if EXTENSIONS[ct] then
    return EXTENSIONS[ct]
  end

  -- Otherwise the subtype, when it looks like an extension rather than a
  -- vendor's full name for itself.
  local sub = ct:match("/x%-([%w]+)$") or ct:match("/([%w]+)$")
  if sub and #sub <= 5 then
    return sub
  end
  return nil
end

-- Make sure a saved file says what it is.
local function named_for(name, content_type)
  if tostring(name):match("%.[%w]+$") then
    return name
  end

  local ext = M.extension_for(content_type)
  return ext and (name .. "." .. ext) or name
end

local function free_path(dir, name)
  -- A name coming off the wire must not be able to escape the directory.
  name = name:gsub("/", "_"):gsub("^%.+", "_")
  local base = dir .. "/" .. name

  if vim.fn.filereadable(base) == 0 then
    return base
  end

  local stem, ext = name:match("^(.*)(%.[^%.]*)$")
  stem = stem or name
  ext = ext or ""
  for i = 1, 99 do
    local candidate = string.format("%s/%s(%d)%s", dir, stem, i, ext)
    if vim.fn.filereadable(candidate) == 0 then
      return candidate
    end
  end
  return base .. ".new"
end

-- Write every attachment out and hand back what was written.
--
-- `notmuch show --part=N --format=raw` gives the decoded content, so a 5.1 MB
-- base64 part lands as the 3.8 MB PDF it actually is. The bytes never go
-- through the network and never through a string conversion, hence text=false.
-- Write one part to a file, decoded.
--
-- Used to get an image out of a message and onto disk, because the terminal
-- draws images from files. The content is binary, so it is read with no text
-- conversion; anything else would corrupt it silently.
function M.save_part(account, id, part, path, on_done)
  vim.system({
    executable(),
    "show",
    "--format=raw",
    "--part=" .. tostring(part),
    "--entire-thread=false",
    id_query(id),
  }, { text = false, env = environment(account) }, function(res)
    vim.schedule(function()
      if res.code ~= 0 or not res.stdout or #res.stdout == 0 then
        return on_done(false, lang.t("err_notmuch"))
      end

      local f = io.open(path, "wb")
      if not f then
        return on_done(false, lang.t("err_notmuch"))
      end
      f:write(res.stdout)
      f:close()
      on_done(true, path)
    end)
  end)
end

function M.save_attachments(account, id, dir, on_done)
  dir = vim.fn.expand(dir or "~/Downloads")
  vim.fn.mkdir(dir, "p")

  M.attachments(account, id, function(ok, atts)
    if not ok then
      return on_done(false, atts)
    end
    if #atts == 0 then
      return on_done(true, { attachments = {} })
    end

    local saved, pending, failed = {}, #atts, nil

    for i, att in ipairs(atts) do
      local cmd = {
        executable(),
        "show",
        "--format=raw",
        "--part=" .. tostring(att.part),
        "--entire-thread=false",
        id_query(id),
      }

      -- Binary, so no text conversion.
      vim.system(cmd, { text = false, env = environment(account) }, function(res)
        vim.schedule(function()
          if res.code == 0 and res.stdout and #res.stdout > 0 then
            local path = free_path(dir, named_for(att.name, att.content_type))
            local f = io.open(path, "wb")
            if f then
              f:write(res.stdout)
              f:close()
              saved[i] = {
                path = path,
                filename = att.name,
                -- What was actually written, not what notmuch reported:
                -- content-length counts the base64 form, so a 3.8 MB PDF is
                -- listed as 5.1 MB.
                size = #res.stdout,
                mime = att.content_type,
              }
            else
              failed = failed or lang.t("err_notmuch")
            end
          else
            failed = failed or lang.t("err_notmuch")
          end

          pending = pending - 1
          if pending == 0 then
            -- Keep whatever was written even if one part failed; the caller
            -- reports "nothing saved" when the list comes back empty.
            local out = {}
            for _, s in ipairs(saved) do
              table.insert(out, s)
            end
            if #out == 0 and failed then
              return on_done(false, failed)
            end
            on_done(true, { attachments = out })
          end
        end)
      end)
    end
  end)
end

-- Any header of one message, decoded ----------------------------------------
--
-- What a reply needs: who it was to, what it answers, and the ids that keep it
-- in its thread. Read from the file for the same reason the subject is — what
-- notmuch hands back stops at the first encoded word.

-- Patterns are built once per name and kept.
local patterns = {}

local function pattern_for(name)
  if not patterns[name] then
    patterns[name] = header_pattern(name)
  end
  return patterns[name]
end

function M.headers_of(account, id, names, on_done)
  run(account, { "search", "--output=files", id_query(id) }, function(ok, out)
    if not ok then
      return on_done(false, out)
    end

    local path = vim.trim(tostring(out):match("[^\n]+") or "")
    if path == "" then
      return on_done(false, lang.t("err_notmuch"))
    end

    local f = io.open(path, "rb")
    if not f then
      return on_done(false, lang.t("err_notmuch"))
    end

    local text = f:read(HEADER_BYTES) or ""
    f:close()

    local head = "\n" .. (text:match("^(.-)\r?\n\r?\n") or text) .. "\n."

    local found = {}
    for _, name in ipairs(names) do
      local value = head:match(pattern_for(name))
      if value then
        value = vim.trim((value:gsub("\r?\n[ \t]+", " ")))
        -- Ids and references are read as written; only what is shown to
        -- someone needs decoding.
        if name == "message-id" or name == "references" or name == "in-reply-to" then
          found[name] = value
        else
          found[name] = decode_words(value)
        end
      end
    end

    on_done(true, found)
  end)
end

-- Everyone written to, and everyone written from ---------------------------
--
-- `notmuch address` walks every matching message, so it costs 18 seconds over
-- this mailbox and cannot be run when someone is waiting to type an address.
-- It is kept in a file instead and read from there, refreshed behind whoever
-- asked. A day-old list of correspondents is not meaningfully worse than a
-- fresh one.

-- One file per account: they are different people's correspondents.
local function address_file(account)
  local dir = vim.fn.stdpath("cache") .. "/leterejo"
  vim.fn.mkdir(dir, "p")

  local name = tostring(account or "default"):gsub("[^%w%-_]", "_")
  return dir .. "/addresses-" .. name .. ".txt"
end

local function read_addresses(account)
  local path = address_file(account)
  if vim.fn.filereadable(path) ~= 1 then
    return nil, nil
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or nil, vim.fn.getftime(path)
end

-- One collection at a time per account.
local refreshing = {}

-- Collect them again, in the background.
function M.refresh_addresses(account, on_done)
  if refreshing[account or ""] then
    return
  end
  refreshing[account or ""] = true

  local opts = config.options.notmuch or {}
  run(account, {
    "address",
    "--output=recipients",
    "--output=sender",
    "--deduplicate=address",
    "--sort=newest-first",
    opts.address_query or "date:2years..",
  }, function(ok, out)
    refreshing[account or ""] = nil
    if not ok then
      return on_done and on_done(nil)
    end

    local found = {}
    for line in tostring(out):gmatch("[^\n]+") do
      line = vim.trim(line)
      if line ~= "" then
        table.insert(found, line)
      end
    end

    -- Written beside itself and renamed into place, because more than one
    -- Neovim may be collecting at once and `writefile` truncates before it
    -- writes: a reader arriving in between gets half a file, and the halves of
    -- two writers get each other. A rename is atomic, so every reader sees one
    -- version or the other and never a mixture.
    local path = address_file(account)
    local temporary = path .. ".tmp-" .. tostring(vim.uv.os_getpid())

    if pcall(vim.fn.writefile, found, temporary) then
      if not pcall(vim.uv.fs_rename, temporary, path) then
        pcall(vim.fn.delete, temporary)
      end
    end

    if on_done then
      on_done(found)
    end
  end)
end

-- The addresses to offer, and whether they are worth collecting again.
--
--   on_done(list, refreshing)
--
-- Answers from the file at once, so a picker opens without waiting, and starts
-- a refresh when the file is old or missing. A refresh that finds more calls
-- back a second time.
function M.addresses(account, on_done)
  local cached, when = read_addresses(account)
  local max_age = (config.options.notmuch or {}).address_max_age or 86400
  local stale = not when or (os.time() - when) > max_age

  if cached and #cached > 0 then
    on_done(cached, stale)
    if stale then
      M.refresh_addresses(account, function() end)
    end
    return
  end

  on_done({}, true)
  M.refresh_addresses(account, function(found)
    if found and #found > 0 then
      on_done(found, false)
    end
  end)
end

-- Quote a name for use in a query. Gmail labels carry slashes, dots and spaces,
-- all of which the query parser would otherwise read as syntax.
local function quoted(prefix, name)
  return prefix .. '"' .. tostring(name):gsub('"', '\\"') .. '"'
end

-- Tags ------------------------------------------------------------------
--
-- Everything that changes a message changes a tag, and nothing else. Gmail has
-- no folders, only labels; lieer keeps those labels and notmuch's tags in step,
-- so marking a message read is `-unread` and archiving it is `-inbox`.
--
-- None of this reaches Gmail. It edits the index, in single-digit milliseconds,
-- and the sync that follows is what carries it up (see lieer.lua).

-- The `+tag -tag` arguments a change is made of.
local function tag_flags(change)
  local flags = {}
  for _, t in ipairs(change.add or {}) do
    table.insert(flags, "+" .. t)
  end
  for _, t in ipairs(change.remove or {}) do
    table.insert(flags, "-" .. t)
  end
  return flags
end

-- Add and remove tags on one message.
function M.tag(account, id, change, on_done)
  local args = { "tag" }
  vim.list_extend(args, tag_flags(change))

  if #args == 1 then
    return on_done(true, "")
  end

  -- Everything after "--" is the query, so a tag named like an option cannot
  -- be read as one.
  table.insert(args, "--")
  table.insert(args, id_query(id))

  run(account, args, on_done)
end

-- Several messages at once ------------------------------------------------
--
-- A selection is one change, not one change per message. Tagging fifty rows one
-- at a time would be fifty processes and — far worse — fifty syncs, and a sync
-- is the part that takes a minute and can be refused. So the ids are named in
-- one query and the whole selection goes up in a single push.

-- The ids as query fragments, in groups small enough to hand to a process.
--
-- The same limit as the listing: a few thousand ids in one argument exceeds
-- what the kernel accepts and the spawn fails with E2BIG.
local function id_groups(ids)
  local GROUP = 250
  local out = {}

  for start = 1, #ids, GROUP do
    local parts = {}
    for i = start, math.min(start + GROUP - 1, #ids) do
      table.insert(parts, id_query(ids[i]))
    end
    table.insert(out, table.concat(parts, " or "))
  end

  return out
end

-- Run one notmuch call per group, one after another.
--
-- Sequential rather than at once because a write takes Xapian's lock: two
-- `notmuch tag` processes on one index means the second fails outright rather
-- than waiting its turn. Reads would be safe in parallel, but a handful of
-- groups is milliseconds either way and one path is easier to trust than two.
local function per_group(account, ids, args_for, on_done)
  local groups = id_groups(ids)
  local results = {}

  local function step(i)
    if i > #groups then
      return on_done(true, results)
    end

    run(account, args_for(groups[i]), function(ok, out)
      if not ok then
        return on_done(false, out)
      end
      table.insert(results, out)
      step(i + 1)
    end)
  end

  step(1)
end

-- Add and remove tags on every message named.
function M.tag_many(account, ids, change, on_done)
  local flags = tag_flags(change)
  if #flags == 0 or #ids == 0 then
    return on_done(true, "")
  end

  per_group(account, ids, function(group)
    local args = { "tag" }
    vim.list_extend(args, flags)
    table.insert(args, "--")
    table.insert(args, group)
    return args
  end, function(ok, res)
    on_done(ok, ok and "" or res)
  end)
end

-- The messages of a set that a change did not reach.
--
-- Asked as one query rather than by reading each message's tags back: the only
-- thing needed is which of these are not as we asked, and the index says that
-- directly. Returns nil when there is nothing to test for.
local function missed_in(group, change)
  local terms = {}

  for _, t in ipairs(change.add or {}) do
    table.insert(terms, "not " .. quoted("tag:", t))
  end
  for _, t in ipairs(change.remove or {}) do
    table.insert(terms, quoted("tag:", t))
  end

  if #terms == 0 then
    return nil
  end
  return "(" .. group .. ") and (" .. table.concat(terms, " or ") .. ")"
end

-- How many of these messages the change did not reach.
function M.count_missed(account, ids, change, on_done)
  if #ids == 0 or missed_in("*", change) == nil then
    return on_done(true, 0)
  end

  per_group(account, ids, function(group)
    return { "count", "--output=messages", missed_in(group, change) }
  end, function(ok, results)
    if not ok then
      return on_done(false, results)
    end

    local total = 0
    for _, out in ipairs(results) do
      total = total + (tonumber(vim.trim(out)) or 0)
    end
    on_done(true, total)
  end)
end

-- Write tags onto exactly the messages a change did not reach.
--
-- Both of the things done about a refused push need this. Trying again means
-- setting `change` on the ones that do not have it; giving up means taking it
-- back out of them — and only out of them, since the rest of the selection did
-- go through and un-archiving forty messages because ten failed would be a
-- worse answer than the failure.
--
--   missed : the change that was asked for, and is being tested for
--   write  : what to put on the ones that did not take it
function M.tag_missed(account, ids, missed, write, on_done)
  local flags = tag_flags(write)
  if #flags == 0 or #ids == 0 or missed_in("*", missed) == nil then
    return on_done(true, "")
  end

  per_group(account, ids, function(group)
    local args = { "tag" }
    vim.list_extend(args, flags)
    table.insert(args, "--")
    table.insert(args, missed_in(group, missed))
    return args
  end, function(ok, res)
    on_done(ok, ok and "" or res)
  end)
end

-- The tags one message carries now.
--
-- Used to check that a write survived the sync: lieer reverts a change it could
-- not push, so the tag we set is the only honest evidence that it stuck.
function M.tags_of(account, id, on_done)
  run(account, { "search", "--format=json", "--output=tags", id_query(id) }, function(ok, out)
    if not ok then
      return on_done(false, out)
    end
    local decoded_ok, tags = pcall(vim.json.decode, vim.trim(out) ~= "" and out or "[]")
    if not decoded_ok or type(tags) ~= "table" then
      return on_done(false, lang.t("err_notmuch"))
    end
    on_done(true, tags)
  end)
end

-- The tags a set of messages carries, and which of them all of it carries.
--
-- Two answers rather than one, because with several messages in hand there are
-- three states and not two: every one of them has the tag, some do, none do.
-- One `show` reports every message's tags, so this costs a single call however
-- many are named.
--
--   on_done(ok, union, shared)   union = list, shared = set
function M.tags_of_many(account, ids, on_done)
  if #ids == 0 then
    return on_done(true, {}, {})
  end

  local counted, seen, union = {}, 0, {}

  per_group(account, ids, function(group)
    return { "show", "--format=json", "--body=false", "--entire-thread=false", group }
  end, function(ok, results)
    if not ok then
      return on_done(false, results)
    end

    for _, out in ipairs(results) do
      local decoded_ok, tree = pcall(vim.json.decode, vim.trim(out) ~= "" and out or "[]")
      if not decoded_ok then
        return on_done(false, lang.t("err_notmuch"))
      end

      for _, msg in ipairs(collect_messages(tree, {})) do
        seen = seen + 1
        for _, t in ipairs(msg.tags or {}) do
          if counted[t] == nil then
            counted[t] = 0
            table.insert(union, t)
          end
          counted[t] = counted[t] + 1
        end
      end
    end

    local shared = {}
    for t, n in pairs(counted) do
      if n == seen then
        shared[t] = true
      end
    end

    table.sort(union)
    on_done(true, union, shared)
  end)
end

-- Mailboxes -------------------------------------------------------------

-- Turn a mailbox name into a query.
--
-- A mailbox is a tag, because on Gmail a mailbox is a label. Kept deliberately
-- thin so the exceptions stay in one place: a store synced by mbsync has real
-- folders, and the Takeout archive is split by year and is not one directory at
-- all, so accounts can name a folder or spell out a query instead.
function M.query_for(account, mailbox)
  local a = (config.options.accounts or {})[account] or {}
  if a.query_for then
    return a.query_for(mailbox)
  end

  local name = mailbox or "inbox"

  local raw = (a.queries or {})[name]
  if raw then
    return raw
  end

  local folder = (a.folders or {})[name]
  if folder then
    return quoted("folder:", folder)
  end

  return quoted("tag:", name)
end

-- The tag a mailbox stands for, or nil when it stands for something else.
--
-- Leaving a mailbox means dropping its tag, so an action needs to know whether
-- there is one. A folder or a hand-written query has no tag to drop.
function M.tag_for(account, mailbox)
  local a = (config.options.accounts or {})[account] or {}
  if not mailbox or a.query_for then
    return nil
  end
  if (a.queries or {})[mailbox] or (a.folders or {})[mailbox] then
    return nil
  end
  return mailbox
end

-- Every tag in the index, in order.
local function all_tags(account, on_done)
  run(account, { "search", "--format=json", "--output=tags", "*" }, function(ok, out)
    if not ok then
      return on_done(false, out)
    end

    local decoded_ok, tags = pcall(vim.json.decode, vim.trim(out) ~= "" and out or "[]")
    if not decoded_ok or type(tags) ~= "table" then
      return on_done(false, lang.t("err_notmuch"))
    end

    table.sort(tags)
    on_done(true, tags)
  end)
end

-- The tags that can be put on a message.
--
-- Fewer than all of them, because some tags are facts about a message rather
-- than something to do to one. `unread` and `attachment` describe it; Gmail's
-- own tabs — `promotions` and the rest — are its classifier's output, so
-- putting one on by hand means offering Gmail a label it will disagree with.
-- Those are listed in `mailbox_hidden_tags`.
--
-- This is about *writing* only. Every one of them is still somewhere to look,
-- and M.mailboxes below offers the lot: not being able to file mail under
-- "promotions" is no reason not to be able to read what is filed there.
function M.tags(account, on_done)
  all_tags(account, function(ok, tags)
    if not ok then
      return on_done(false, tags)
    end

    local hidden = {}
    for _, t in ipairs(config.options.mailbox_hidden_tags or {}) do
      hidden[t] = true
    end

    local names = {}
    for _, t in ipairs(tags) do
      if not hidden[t] then
        table.insert(names, t)
      end
    end

    on_done(true, names)
  end)
end

-- Everything that can be looked at: every tag, and the views an account defined.
--
-- Every tag, deliberately — including the ones `M.tags` leaves out. Those are
-- kept off the list of places to *put* mail, which is a different question from
-- where to look: Gmail's tabs cannot be applied by hand, and reading them is the
-- whole reason for having taken them in.
--
-- Tags and views are handed back apart. A view is a query with a name — the
-- Takeout archive is a directory, not a label — so it can be switched to but
-- not put on a message. Offering one where a tag was meant created a tag called
-- "Archive" here, which is exactly the confusion this keeps out.
--
--   on_done(ok, names, is_view)
function M.mailboxes(account, on_done)
  all_tags(account, function(ok, tags)
    if not ok then
      return on_done(false, tags)
    end

    local a = (config.options.accounts or {})[account] or {}
    local is_view, names, seen = {}, {}, {}

    local function add(name, view)
      if not seen[name] then
        seen[name] = true
        is_view[name] = view or nil
        table.insert(names, name)
      end
    end

    -- An account's own views are named first: a view narrowing a tag it is
    -- named after ("inbox", scoped to what one sync tool holds) is the one
    -- that should answer to the name.
    for name in pairs(a.queries or {}) do
      add(name, true)
    end
    for name in pairs(a.folders or {}) do
      add(name, true)
    end
    for _, t in ipairs(tags) do
      add(t, false)
    end

    table.sort(names)
    on_done(true, names, is_view)
  end)
end

return M
