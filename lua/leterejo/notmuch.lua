-- The notmuch call layer, used for everything that reads.
--
-- notmuch answers from a local index, so a page costs tens of milliseconds
-- instead of the two seconds an IMAP round trip takes. Nothing here talks to
-- the network.
--
-- Envelopes are handed back in the same shape himalaya produces, so the screen
-- code does not need to know which layer served it.
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

-- Split "Name <addr>, Name <addr>" the way himalaya reports addresses.
-- Only the sender is shown in the list, but replies read the whole line.
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

  local has_attachment = false
  for _, t in ipairs(tags) do
    if t == "attachment" then
      has_attachment = true
      break
    end
  end

  return {
    -- The message id, not the IMAP UID. notmuch can look a message up by this
    -- and nothing else; the UID is only recoverable from the file name, which
    -- is what uid_of is for.
    id = msg.id,
    subject = h.Subject or "",
    from = parse_addrs(h.From),
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

-- Fetch one page of envelopes for a query, newest first.
--
-- Two calls: the first settles which messages and in what order, the second
-- fetches their headers. `show` groups by thread and would otherwise lose the
-- ordering, so the result is put back in the order the search returned.
function M.list(query, page, page_size, on_done)
  local size = page_size or 50
  return M.list_at(query, ((page or 1) - 1) * size, size, on_done)
end

-- The same, addressed by offset rather than page number. A continuous list
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

    on_done(true, rows)
  end)
end

-- The messages of one thread, oldest first.
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
    table.sort(envelopes, function(a, b)
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
    on_done(true, found)
  end)
end

-- Pick a path that does not overwrite anything, the way himalaya does it.
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
            local path = free_path(dir, att.name)
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

-- Recover the IMAP UID, which mbsync stores in the file name as ",U=<n>".
-- The write path still goes through himalaya over IMAP and needs it.
--
-- Mail imported from a Takeout archive never has one: it came over HTTPS, not
-- IMAP, so the server has no handle to hand back. Those messages can be read
-- and searched but not changed, and saying so is more use than reporting a
-- failure that sounds like something is broken.
function M.uid_of(id, on_done)
  run_json({
    "show",
    "--format=json",
    "--body=false",
    "--entire-thread=false",
    id_query(id),
  }, function(ok, tree)
    if not ok then
      return on_done(false, tree)
    end

    local seen = false
    for _, msg in ipairs(collect_messages(tree, {})) do
      for _, path in ipairs(msg.filename or {}) do
        seen = true
        local uid = tostring(path):match(",U=(%d+)")
        if uid then
          return on_done(true, uid)
        end
      end
    end

    -- Found the message but no UID in any of its file names: it is archive-only.
    on_done(false, lang.t(seen and "err_archive_only" or "err_notmuch"))
  end)
end

-- Whether an account reads from the local index rather than over IMAP.
function M.is_local(account)
  local a = (config.options.accounts or {})[account] or {}
  return a.local_mail == true
end

-- Names this plugin uses for mailboxes, mapped to the directories a sync tool
-- actually created.
--
-- The short names come from himalaya's [mailbox.alias], which expands them
-- server-side; notmuch has no such thing and matches the path literally, case
-- included. Without this "inbox" quietly finds nothing at all.
local DEFAULT_FOLDERS = {
  inbox = "INBOX",
}

-- Turn a mailbox name into a query. Kept deliberately thin: a store synced by
-- mbsync has folders, one synced by lieer has none and uses tags instead, and
-- only this function should have to know the difference.
function M.query_for(account, mailbox)
  local a = (config.options.accounts or {})[account] or {}
  if a.query_for then
    return a.query_for(mailbox)
  end

  local name = mailbox or "inbox"

  -- Some views are not one directory. The Takeout archive is split by year, so
  -- reaching all of it means "path:archive/**" rather than any single folder.
  -- Accounts spell those out themselves.
  local raw = (a.queries or {})[name]
  if raw then
    return raw
  end

  -- The mailbox may arrive either as the short name used in keymaps ("inbox")
  -- or as the name the server reported ("INBOX"), so try both.
  local folders = a.folders or {}
  name = folders[name] or folders[name:lower()] or DEFAULT_FOLDERS[name:lower()] or name

  -- Gmail's own folders carry brackets and spaces ("[Gmail]/Sent Mail"), which
  -- the query parser would otherwise read as syntax.
  return 'folder:"' .. name:gsub('"', '\\"') .. '"'
end

-- The folders that actually hold mail here.
--
-- Asking himalaya would list what the server has, which is not the same thing:
-- only INBOX is synced down, so every other name would come back empty. What is
-- on disk is the honest answer, plus whatever views the account defined by
-- query.
--
-- notmuch itself cannot list folders — `search --output=` takes only summary,
-- threads, messages, files and tags — so walk the tree instead. A Maildir is a
-- directory holding cur/new/tmp, and there is no reason to descend into those:
-- reading a `cur` with twenty thousand messages in it would cost more than
-- everything else here put together.
function M.folders(account, on_done)
  run({ "config", "get", "database.mail_root" }, function(ok, out)
    if not ok then
      return on_done(false, out)
    end

    local root = vim.trim(out)
    local names = {}

    if root ~= "" and vim.fn.isdirectory(root) == 1 then
      local leaves = { cur = true, new = true, tmp = true }
      for path, kind in vim.fs.dir(root, {
        depth = 8,
        skip = function(name)
          return not leaves[name]
        end,
      }) do
        if kind == "directory" and path:sub(-4) == "/cur" then
          table.insert(names, path:sub(1, -5))
        end
      end
    end

    local a = (config.options.accounts or {})[account] or {}
    for name in pairs(a.queries or {}) do
      table.insert(names, name)
    end

    table.sort(names)
    on_done(true, names)
  end)
end

return M
