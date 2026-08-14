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

-- Run notmuch asynchronously.
local function run(args, on_done)
  local opts = require("leterejo.config").options.notmuch or {}

  local env = { XAPIAN_CJK_NGRAM = "1" }
  if opts.config then
    env.NOTMUCH_CONFIG = vim.fn.expand(opts.config)
  end

  local cmd = { opts.executable or "notmuch" }
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

local function run_json(args, on_done)
  run(args, function(ok, out)
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
local function decode_words(value)
  value = value:gsub("(%?=)%s+(=%?)", "%1%2")

  return (value:gsub("=%?([%w%-]+)%?([BbQq])%?(.-)%?=", function(charset, encoding, body)
    return decode_word(charset, encoding, body)
      or ("=?" .. charset .. "?" .. encoding .. "?" .. body .. "?=")
  end))
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

-- Fetch a run of envelopes for a query, newest first, starting at an offset.
--
-- Two calls: the first settles which messages and in what order, the second
-- fetches their headers. `show` groups by thread and would otherwise lose the
-- ordering, so the result is put back in the order the search returned.
--
-- Addressed by offset rather than by page: the list grows as it is scrolled and
-- knows how many rows it holds, not which page it is on.
function M.list_at(query, offset, size, on_done)
  offset = offset or 0
  size = size or 50

  run({
    "search",
    "--format=json",
    "--output=messages",
    "--sort=newest-first",
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
      run_json({
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
function M.count(query, threaded, on_done)
  run({
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

-- Fetch one batch of threads for a query, newest first.
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
function M.list_threads(query, offset, limit, on_done)
  run({
    "search",
    "--format=json",
    "--output=summary",
    "--sort=newest-first",
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

    run({ "search", "--output=files", table.concat(ids, " or ") }, function(ok2, out2)
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
function M.thread_messages(thread, on_done)
  run_json({
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
local function html_part_id(id, on_done)
  run_json({
    "show",
    "--format=json",
    "--body=true",
    "--entire-thread=false",
    id_query(id),
  }, function(ok, tree)
    if not ok then
      return on_done(nil)
    end

    local found
    local function walk(node)
      if found or type(node) ~= "table" then
        return
      end
      if node["content-type"] == "text/html" and node.id ~= nil then
        found = node.id
        return
      end
      for _, child in pairs(node) do
        walk(child)
      end
    end
    walk(tree)
    on_done(found)
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

function M.read(id, on_done)
  local function show(extra, cb)
    local args = { "show", "--format=text", "--entire-thread=false" }
    vim.list_extend(args, extra)
    table.insert(args, id_query(id))
    run(args, function(ok, out)
      cb(ok, ok and strip_markers(out) or out)
    end)
  end

  -- Fall back to the raw markup, which is what came before.
  local function raw(cb)
    show({ "--include-html" }, cb)
  end

  show({}, function(ok, out)
    if not ok then
      return on_done(false, out)
    end

    local marker = "Non-text part: text/html"
    if not out:find(marker, 1, true) then
      return on_done(true, out)
    end

    local renderer = (config.options.notmuch or {}).html_renderer
    if not renderer or vim.fn.executable(renderer[1]) ~= 1 then
      return raw(on_done)
    end
    renderer = M.render_width(renderer)

    html_part_id(id, function(part)
      if not part then
        return raw(on_done)
      end

      run({
        "show",
        "--format=raw",
        "--part=" .. tostring(part),
        "--entire-thread=false",
        id_query(id),
      }, function(ok2, html)
        if not ok2 or html == "" then
          return raw(on_done)
        end

        pipe_through(renderer, html, function(ok3, text)
          if not ok3 or vim.trim(text) == "" then
            return raw(on_done)
          end
          -- Put the rendering where notmuch said there was nothing to read.
          on_done(true, (out:gsub(vim.pesc(marker), (text:gsub("%%", "%%%%")), 1)))
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
local function files_of(id, on_done)
  run({ "search", "--output=files", id_query(id) }, function(ok, out)
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
local function repaired(id, attachments, on_done)
  local damaged = false
  for _, att in ipairs(attachments) do
    damaged = damaged or looks_cut(att.name)
  end

  if not damaged then
    return on_done(true, attachments)
  end

  files_of(id, function(paths)
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
function M.attachments(id, on_done)
  run_json({
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
    repaired(id, found, on_done)
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
function M.save_part(id, part, path, on_done)
  local opts = require("leterejo.config").options.notmuch or {}

  vim.system({
    opts.executable or "notmuch",
    "show",
    "--format=raw",
    "--part=" .. tostring(part),
    "--entire-thread=false",
    id_query(id),
  }, { text = false }, function(res)
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

function M.save_attachments(id, dir, on_done)
  dir = vim.fn.expand(dir or "~/Downloads")
  vim.fn.mkdir(dir, "p")

  M.attachments(id, function(ok, atts)
    if not ok then
      return on_done(false, atts)
    end
    if #atts == 0 then
      return on_done(true, { attachments = {} })
    end

    local opts = require("leterejo.config").options.notmuch or {}
    local saved, pending, failed = {}, #atts, nil

    for i, att in ipairs(atts) do
      local cmd = {
        opts.executable or "notmuch",
        "show",
        "--format=raw",
        "--part=" .. tostring(att.part),
        "--entire-thread=false",
        id_query(id),
      }

      -- Binary, so no text conversion.
      vim.system(cmd, { text = false }, function(res)
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

-- Everyone written to, and everyone written from ---------------------------
--
-- `notmuch address` walks every matching message, so it costs 18 seconds over
-- this mailbox and cannot be run when someone is waiting to type an address.
-- It is kept in a file instead and read from there, refreshed behind whoever
-- asked. A day-old list of correspondents is not meaningfully worse than a
-- fresh one.

local addresses_path = nil

local function address_file()
  if not addresses_path then
    local dir = vim.fn.stdpath("cache") .. "/leterejo"
    vim.fn.mkdir(dir, "p")
    addresses_path = dir .. "/addresses.txt"
  end
  return addresses_path
end

local function read_addresses()
  local path = address_file()
  if vim.fn.filereadable(path) ~= 1 then
    return nil, nil
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or nil, vim.fn.getftime(path)
end

local refreshing = false

-- Collect them again, in the background.
function M.refresh_addresses(on_done)
  if refreshing then
    return
  end
  refreshing = true

  local opts = config.options.notmuch or {}
  run({
    "address",
    "--output=recipients",
    "--output=sender",
    "--deduplicate=address",
    "--sort=newest-first",
    opts.address_query or "date:2years..",
  }, function(ok, out)
    refreshing = false
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

    pcall(vim.fn.writefile, found, address_file())
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
function M.addresses(on_done)
  local cached, when = read_addresses()
  local max_age = (config.options.notmuch or {}).address_max_age or 86400
  local stale = not when or (os.time() - when) > max_age

  if cached and #cached > 0 then
    on_done(cached, stale)
    if stale then
      M.refresh_addresses(function() end)
    end
    return
  end

  on_done({}, true)
  M.refresh_addresses(function(found)
    if found and #found > 0 then
      on_done(found, false)
    end
  end)
end

-- Tags ------------------------------------------------------------------
--
-- Everything that changes a message changes a tag, and nothing else. Gmail has
-- no folders, only labels; lieer keeps those labels and notmuch's tags in step,
-- so marking a message read is `-unread` and archiving it is `-inbox`.
--
-- None of this reaches Gmail. It edits the index, in single-digit milliseconds,
-- and the sync that follows is what carries it up (see lieer.lua).

-- Add and remove tags on one message.
function M.tag(id, change, on_done)
  local args = { "tag" }

  for _, t in ipairs(change.add or {}) do
    table.insert(args, "+" .. t)
  end
  for _, t in ipairs(change.remove or {}) do
    table.insert(args, "-" .. t)
  end

  if #args == 1 then
    return on_done(true, "")
  end

  -- Everything after "--" is the query, so a tag named like an option cannot
  -- be read as one.
  table.insert(args, "--")
  table.insert(args, id_query(id))

  run(args, on_done)
end

-- The tags one message carries now.
--
-- Used to check that a write survived the sync: lieer reverts a change it could
-- not push, so the tag we set is the only honest evidence that it stuck.
function M.tags_of(id, on_done)
  run({ "search", "--format=json", "--output=tags", id_query(id) }, function(ok, out)
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

-- Mailboxes -------------------------------------------------------------

-- Quote a name for use in a query. Gmail labels carry slashes, dots and spaces,
-- all of which the query parser would otherwise read as syntax.
local function quoted(prefix, name)
  return prefix .. '"' .. tostring(name):gsub('"', '\\"') .. '"'
end

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

-- The tags in use, which is what can be put on a message.
--
-- Not every tag is a place: unread and attachment describe a message rather
-- than say where it is, and offering them here would be offering to move mail
-- into "unread". Those are listed in `mailbox_hidden_tags`.
function M.tags(on_done)
  run({ "search", "--format=json", "--output=tags", "*" }, function(ok, out)
    if not ok then
      return on_done(false, out)
    end

    local decoded_ok, tags = pcall(vim.json.decode, vim.trim(out) ~= "" and out or "[]")
    if not decoded_ok or type(tags) ~= "table" then
      return on_done(false, lang.t("err_notmuch"))
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

    table.sort(names)
    on_done(true, names)
  end)
end

-- Everything that can be looked at: the tags, and the views an account defined.
--
-- The two are handed back apart. A view is a query with a name — the Takeout
-- archive is a directory, not a label — so it can be switched to but not put
-- on a message. Offering one where a tag was meant created a tag called
-- "Archive" here, which is exactly the confusion this keeps out.
--
--   on_done(ok, names, is_view)
function M.mailboxes(account, on_done)
  M.tags(function(ok, tags)
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
