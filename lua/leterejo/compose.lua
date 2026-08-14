-- The compose buffer and sending.
--
-- Encoding (RFC 2047 subjects, base64 bodies, charsets) and quote assembly are
-- left entirely to himalaya. Those are the parts most likely to break on
-- non-ASCII mail, so nothing is assembled here: the text written is handed to
-- `--body` as is.
--
-- Consequently this buffer holds only the author's own words; himalaya appends
-- the quoted original on reply.
local cli = require("leterejo.cli")
local config = require("leterejo.config")
local lang = require("leterejo.lang")
local notmuch = require("leterejo.notmuch")
local state = require("leterejo.state")
local util = require("leterejo.ui.util")

local M = {}

local BUFNAME = "leterejo://compose"

-- What is needed to send, paired with the buffer.
--   kind    : "compose" | "reply" | "forward"
--   id      : id of the message being replied to or forwarded
--   mailbox : where that message lives
local pending = nil

local function find_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == BUFNAME then
      return b
    end
  end
  return nil
end

-- Render an address list as "Name <addr>, ...".
local function format_addrs(addrs)
  local out = {}
  for _, a in ipairs(addrs or {}) do
    local name = a.name
    if name ~= nil and name ~= vim.NIL and name ~= "" then
      table.insert(out, string.format("%s <%s>", util.strip_invisible(tostring(name)), a.email))
    else
      table.insert(out, a.email or "")
    end
  end
  return table.concat(out, ", ")
end

-- Parse "Name <addr>, ..." back into bare addresses.
-- himalaya receives addresses only; display names are its configuration's job.
local function parse_addrs(line)
  local out = {}
  for _, part in ipairs(vim.split(line or "", ",", { plain = true })) do
    part = vim.trim(part)
    if part ~= "" then
      local email = part:match("<([^>]+)>") or part
      table.insert(out, vim.trim(email))
    end
  end
  return out
end

-- Build the line introducing the quoted text.
-- himalaya performs no substitution, so it is assembled here and passed in.
local function quote_headline(envelope)
  local from = format_addrs(envelope.from)
  local date = util.format_date(envelope.date)
  if from == "" then
    return lang.t("quote_headline_noname", date)
  end
  return lang.t("quote_headline", date, from)
end

-- The account that owns an address, if any owns it.
--
-- What decides which server a message goes through. Comparing addresses rather
-- than names, because that is what the user typed in From.
function M.account_for(address)
  address = tostring(address or ""):lower()
  if address == "" then
    return nil
  end

  local names = vim.tbl_keys(config.options.accounts or {})
  table.sort(names) -- a stable answer if two accounts share an address
  for _, name in ipairs(names) do
    local email = (config.options.accounts[name] or {}).email
    if email and tostring(email):lower() == address then
      return name
    end
  end
  return nil
end

-- Split the buffer into headers and body.
--
-- A blank line ends the headers, as in the message itself. But a line that is
-- simply not a header ends them too: writing the first sentence straight after
-- Subject, without the blank line, is an easy thing to do and used to lose that
-- sentence — it was skipped as an unrecognised header, and the body began at
-- whatever blank line came next. A dropped opening sentence is not something
-- the sender would notice before it left.
local function parse_buffer(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local headers, body_start = {}, #lines + 1

  for i, line in ipairs(lines) do
    if line == "" then
      body_start = i + 1
      break
    end

    local name, value = line:match("^([%w%-]+):%s*(.*)$")
    if name then
      headers[name:lower()] = vim.trim(value)
    elseif not line:match("^[ \t]") then
      -- Anything that is neither a header nor a folded continuation of the one
      -- above (RFC 5322 §2.2.3) is where the body starts.
      body_start = i
      break
    end
  end

  local body = table.concat(vim.list_slice(lines, body_start, #lines), "\n")
  return headers, body
end

-- Everything needed to hand the message to himalaya, worked out from the
-- buffer. Sending and filing a copy differ only in the flag at the end.
--
--   strict : refuse a message with no recipient or no body. A draft is allowed
--            to be neither yet; something about to leave is not.
local function assemble(strict)
  local buf = find_buf()
  if not buf or not pending then
    vim.notify(lang.e("no_draft"), vim.log.levels.WARN)
    return nil
  end

  local headers, body = parse_buffer(buf)

  local named = headers["x-leterejo-account"]
  if not named or named == "" then
    named = state.account
  end

  -- Which address this is sent as, and therefore which account sends it.
  --
  -- An address belongs to the account that owns it: sending as the work
  -- address goes through the work server, because that is the server allowed
  -- to send for it and the one the recipient's checks will look at. Editing
  -- From is how the route is chosen, rather than something that quietly
  -- disagrees with it.
  --
  -- An address no account owns keeps the account named in the header. That is
  -- the alias case — a provider told to expect another address, as Gmail's
  -- "send mail as" does — and there the route cannot be worked out from the
  -- address alone.
  local from = parse_addrs(headers["from"])[1]
    or ((config.options.accounts or {})[named] or {}).email

  if not from or from == "" then
    vim.notify(lang.e("no_email_configured", named), vim.log.levels.ERROR)
    return nil
  end

  local account = M.account_for(from) or named
  local to = parse_addrs(headers["to"])

  if strict and #to == 0 then
    vim.notify(lang.e("to_empty"), vim.log.levels.ERROR)
    return nil
  end
  if strict and vim.trim(body) == "" then
    vim.notify(lang.e("body_empty"), vim.log.levels.ERROR)
    return nil
  end

  local cc = parse_addrs(headers["cc"])
  local bcc = parse_addrs(headers["bcc"])

  -- Bcc yourself on this route to keep a copy. Some servers run tight on
  -- quota and skip the sent folder entirely. Looked up by the address it is
  -- sent as, then by the account, so a copy follows the address whichever
  -- route it takes.
  local auto = (config.options.auto_bcc or {})[from] or (config.options.auto_bcc or {})[account]
  if auto then
    local already = false
    for _, a in ipairs(bcc) do
      if a:lower() == auto:lower() then
        already = true
        break
      end
    end
    if not already then
      table.insert(bcc, auto)
    end
  end

  -- Assemble. Subject/body encoding and quoting are himalaya's work.
  --
  -- Every value is joined to its option with "=" rather than passed as the next
  -- argument. himalaya's parser will not accept a value beginning with a hyphen
  -- in the separate form, so a message opening with a line of dashes — a
  -- signature, a rule above a quote — failed to send with
  -- `unexpected argument '---'`. The joined form has no such rule.
  local args
  if pending.kind == "reply" then
    args = { "message", "reply", tostring(pending.id) }
    if pending.mailbox then
      table.insert(args, "--mailbox=" .. pending.mailbox)
    end
    if pending.headline then
      table.insert(args, "--quote-headline=" .. pending.headline)
    end
  elseif pending.kind == "forward" then
    args = { "message", "forward", tostring(pending.id) }
    if pending.mailbox then
      table.insert(args, "--mailbox=" .. pending.mailbox)
    end
  else
    args = { "message", "compose" }
  end

  -- Always pass the sender. himalaya v2 does not fill From from its own
  -- configuration (v1's display-name and friends were removed), and without
  -- it sending stops at `No 'From:' header found in raw message`.
  table.insert(args, "--from=" .. from)

  for _, a in ipairs(to) do
    table.insert(args, "--to=" .. a)
  end
  for _, a in ipairs(cc) do
    table.insert(args, "--cc=" .. a)
  end
  for _, a in ipairs(bcc) do
    table.insert(args, "--bcc=" .. a)
  end

  -- On reply and forward himalaya prefixes "Re:" / "Fwd:" itself, so only
  -- pass a subject when the user actually edited it.
  local subject = headers["subject"]
  if subject and subject ~= "" and subject ~= pending.original_subject then
    table.insert(args, "--subject=" .. subject)
  elseif pending.kind == "compose" then
    table.insert(args, "--subject=" .. (subject or ""))
  end

  table.insert(args, "--body=" .. body)

  return { buf = buf, args = args, account = account, from = from, bcc = bcc }
end

-- Send.
function M.send()
  local m = assemble(true)
  if not m then
    return
  end

  local args = vim.deepcopy(m.args)
  table.insert(args, "--send")

  local label = #m.bcc > 0 and lang.t("bcc_note", table.concat(m.bcc, ", ")) or ""

  -- Say both when they differ. Sending as one address through another's server
  -- is the case most worth reading back before it goes.
  local own = ((config.options.accounts or {})[m.account] or {}).email
  if own and own:lower() ~= m.from:lower() then
    vim.notify(lang.t("sending_via", m.from, m.account, label), vim.log.levels.INFO)
  else
    vim.notify(lang.t("sending", m.account, label), vim.log.levels.INFO)
  end

  cli.text(args, m.account, function(ok, out, kind)
    if not ok then
      -- A locked password store is not really a failure of the message; the
      -- draft is untouched and the same send will work once it is open. Offer
      -- to do that here rather than leave the user to work out that pinentry
      -- was what flashed past.
      if kind == "passphrase" then
        return M.unlock_then_send(m.account)
      end
      return vim.notify(lang.e("send_failed") .. "\n" .. out, vim.log.levels.ERROR)
    end

    vim.notify(lang.t("sent"), vim.log.levels.INFO)

    -- The draft has been sent, so it is no longer a draft.
    if pending.draft then
      os.remove(pending.draft)
    end
    pending = nil

    -- Clean up the buffer once sent.
    if vim.api.nvim_buf_is_valid(m.buf) then
      vim.bo[m.buf].modified = false
      vim.api.nvim_buf_delete(m.buf, { force = true })
    end
  end)
end

-- Open the password store, then send what is still in the buffer.
--
-- Asked rather than done: the unlock takes over the screen for a moment, and a
-- message the user has decided not to send yet should not drag it up.
function M.unlock_then_send(account)
  local yes = lang.t("unlock_yes")

  vim.ui.select({ yes, lang.t("unlock_no") }, { prompt = lang.t("unlock_prompt") }, function(choice)
    if choice ~= yes then
      return vim.notify(lang.t("draft_kept"), vim.log.levels.INFO)
    end

    cli.unlock(account, function(ok, message)
      vim.notify(lang.t("prefix") .. message, ok and vim.log.levels.INFO or vim.log.levels.WARN)
      if ok then
        M.send()
      end
    end)
  end)
end

-- Put a copy of the draft in a mailbox on the server.
--
-- For when a draft has to be reachable from somewhere other than this machine
-- — a phone, or the webmail. IMAP can only append, never replace, so each time
-- this is done another copy appears beside the last; the local draft is the one
-- that gets overwritten in place, and this is the deliberate act.
function M.upload()
  local m = assemble(false)
  if not m then
    return
  end

  local a = (config.options.accounts or {})[m.account] or {}
  local mailbox = a.draft_mailbox or config.options.draft_mailbox
  if type(mailbox) ~= "string" or mailbox == "" then
    return vim.notify(lang.e("no_draft_mailbox", m.account), vim.log.levels.WARN)
  end

  local args = vim.deepcopy(m.args)
  table.insert(args, "--save=" .. mailbox)

  vim.notify(lang.t("draft_uploading", mailbox, m.account), vim.log.levels.INFO)

  cli.text(args, m.account, function(ok, out)
    if not ok then
      return vim.notify(lang.e("draft_upload_failed") .. "\n" .. out, vim.log.levels.ERROR)
    end
    vim.notify(lang.t("draft_uploaded", mailbox), vim.log.levels.INFO)
  end)
end

local function discard()
  local buf = find_buf()
  if not buf then
    return
  end

  local yes = lang.t("discard_yes")
  vim.ui.select({ yes, lang.t("discard_no") }, { prompt = lang.t("discard_prompt") }, function(choice)
    if choice == yes then
      if pending and pending.draft then
        os.remove(pending.draft)
      end
      pending = nil
      vim.bo[buf].modified = false
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)
end

-- Drafts --------------------------------------------------------------------
--
-- Kept as files here rather than in a Drafts mailbox. lieer syncs labels and
-- messages downwards and has no way to put a half-written one up, and the
-- alternative — reaching for IMAP again for this one thing — would put the
-- slowest path back into the one place where a stall is most annoying.
--
-- The consequence is that a draft stays on this machine. That is worth saying
-- plainly rather than hiding: it is not on the phone.

local function draft_dir()
  return vim.fn.stdpath("state") .. "/leterejo/drafts"
end

-- The name a draft is filed under: when it was written, and nothing else.
--
-- No subject in it. Lua's %w is ASCII, so a Japanese subject would come out as
-- a row of dashes, and a name that only helps in English is worse than one
-- that is plainly a timestamp. The picker reads each draft's own Subject line
-- instead, which is also what a subject typed after the first save needs.
local function draft_name()
  local stamp = os.date("%Y%m%d-%H%M%S")
  local path = draft_dir() .. "/" .. stamp .. ".eml"

  -- Two in the same second would otherwise be one.
  local n = 1
  while vim.fn.filereadable(path) == 1 do
    path = string.format("%s/%s-%d.eml", draft_dir(), stamp, n)
    n = n + 1
  end

  return vim.fn.fnamemodify(path, ":t")
end

-- What a resumed draft needs beyond its own text: which message it answers,
-- and where that message was. Written into the file and taken back out on
-- resume, so the buffer itself stays the plain thing the user typed.
local function draft_headers()
  local out = {}
  if pending.kind == "reply" then
    table.insert(out, "X-Leterejo-Reply: " .. tostring(pending.id))
  elseif pending.kind == "forward" then
    table.insert(out, "X-Leterejo-Forward: " .. tostring(pending.id))
  end
  if pending.mailbox then
    table.insert(out, "X-Leterejo-Source: " .. pending.mailbox)
  end
  if pending.headline then
    table.insert(out, "X-Leterejo-Quote: " .. pending.headline)
  end
  return out
end

-- Write the draft out. This is what :w does.
--
-- Writing used to send, on the reasoning that anyone whose habit is
-- write-then-save would want it. That is one keystroke away from sending a
-- half-written message to its recipient, and there is no taking it back.
function M.save()
  local buf = find_buf()
  if not buf or not pending then
    return vim.notify(lang.e("no_draft"), vim.log.levels.WARN)
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  if not pending.draft then
    vim.fn.mkdir(draft_dir(), "p")
    pending.draft = draft_dir() .. "/" .. draft_name()
  end

  -- The extra headers go in after the first line, which is the account.
  local out = { lines[1] }
  vim.list_extend(out, draft_headers())
  vim.list_extend(out, vim.list_slice(lines, 2, #lines))

  local ok = pcall(vim.fn.writefile, out, pending.draft)
  if not ok then
    return vim.notify(lang.e("draft_failed", pending.draft), vim.log.levels.ERROR)
  end

  vim.bo[buf].modified = false
  vim.notify(lang.t("draft_saved", vim.fn.fnamemodify(pending.draft, ":t")), vim.log.levels.INFO)
end

-- Put an unsaved draft somewhere safe before its buffer is taken.
--
-- There is one compose buffer, so starting another message replaces whatever
-- was in it. Losing half-written words to a keystroke meant for something else
-- is the kind of thing an editor should never do.
local function stash()
  local buf = find_buf()
  if buf and pending and vim.bo[buf].modified then
    M.save()
  end
end

-- Prepare and open the buffer.
local function open_buffer(lines, cursor_line)
  local buf = find_buf()
  if buf then
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, BUFNAME)
  vim.bo[buf].buftype = "acwrite" -- lets :w mean something here
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "mail"

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false

  require("leterejo.keymaps").apply(buf, "compose", {
    send = { handler = M.send, desc = lang.t("desc_send") },
    save = { handler = M.save, desc = lang.t("desc_save_draft") },
    upload = { handler = M.upload, desc = lang.t("desc_upload_draft") },
    discard = { handler = discard, desc = lang.t("desc_discard") },
  })

  -- :w saves the draft. Sending is a key of its own and nothing else, because
  -- the two are not the same decision and only one of them can be undone.
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      M.save()
    end,
  })

  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.wo.wrap = true
  vim.wo.linebreak = true
  vim.api.nvim_win_set_cursor(0, { cursor_line, 0 })
  vim.cmd("startinsert")

  return buf
end

-- Build the header block, keeping the outgoing account and address visible.
--
-- Both are editable. The account picks the route the message takes; From is
-- what the message says, and the two need not name the same address — a
-- provider told to expect another one will carry mail for it.
local function header_lines(account, to, cc, subject)
  local from = ((config.options.accounts or {})[account] or {}).email or ""
  local auto = (config.options.auto_bcc or {})[from] or (config.options.auto_bcc or {})[account]

  return {
    "X-Leterejo-Account: " .. account,
    "From: " .. from,
    "To: " .. (to or ""),
    "Cc: " .. (cc or ""),
    "Bcc: " .. (auto or ""),
    "Subject: " .. (subject or ""),
    "",
  }
end

-- Which line to leave the cursor on: the first empty header worth filling in.
local function first_gap(lines, name)
  for i, line in ipairs(lines) do
    if line:lower():sub(1, #name + 1) == name:lower() .. ":" then
      return i
    end
  end
  return 1
end

-- Open a draft that was written earlier.
--
-- The headers that were only there to remember what the draft answers are
-- taken back out and put into `pending`, so the buffer looks the way it did
-- when it was written.
function M.open_draft(path)
  stash()

  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" or #lines == 0 then
    return vim.notify(lang.e("draft_unreadable", path), vim.log.levels.ERROR)
  end

  local p = { kind = "compose", draft = path }
  local kept, in_headers = {}, true

  for _, line in ipairs(lines) do
    if in_headers and line == "" then
      in_headers = false
    end

    local name, value = nil, nil
    if in_headers then
      name, value = line:match("^(X%-Leterejo%-[%w%-]+):%s*(.*)$")
    end

    if name == "X-Leterejo-Reply" then
      p.kind, p.id = "reply", value
    elseif name == "X-Leterejo-Forward" then
      p.kind, p.id = "forward", value
    elseif name == "X-Leterejo-Source" then
      p.mailbox = value
    elseif name == "X-Leterejo-Quote" then
      p.headline = value
    else
      table.insert(kept, line)
    end
  end

  -- himalaya prefixes "Re:" / "Fwd:" itself, so a subject that was not edited
  -- must not be passed on. What was written is what counts as unedited here.
  for _, line in ipairs(kept) do
    local subject = line:match("^[Ss]ubject:%s*(.*)$")
    if subject then
      p.original_subject = subject
      break
    end
  end

  pending = p
  open_buffer(kept, first_gap(kept, "To"))
end

-- The drafts there are, newest first.
--
-- Named by when they were written, so sorting the names sorts by time.
local function draft_files()
  local dir = draft_dir()
  if vim.fn.isdirectory(dir) ~= 1 then
    return {}
  end

  local found = {}
  for name, kind in vim.fs.dir(dir) do
    if kind == "file" and name:sub(-4) == ".eml" then
      table.insert(found, name)
    end
  end

  table.sort(found, function(a, b)
    return a > b
  end)
  return found
end

-- Pick one of the saved drafts and open it.
function M.drafts()
  local files = draft_files()
  if #files == 0 then
    return vim.notify(lang.t("draft_none"), vim.log.levels.INFO)
  end

  local labels = {}
  for _, name in ipairs(files) do
    -- Say what it is by its own headers rather than its file name: a subject
    -- typed after the first save would otherwise never show.
    local ok, head = pcall(vim.fn.readfile, draft_dir() .. "/" .. name, "", 12)
    local to, subject = "", ""
    for _, line in ipairs(ok and head or {}) do
      to = line:match("^[Tt]o:%s*(.*)$") or to
      subject = line:match("^[Ss]ubject:%s*(.*)$") or subject
    end

    local when = name:match("^(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)")
    when = when and name:sub(5, 6) .. "-" .. name:sub(7, 8) .. " " .. name:sub(10, 11) .. ":" .. name:sub(12, 13)
      or name

    table.insert(labels, string.format(
      "%s  %s  → %s",
      when,
      subject ~= "" and subject or lang.t("no_subject"),
      to ~= "" and to or "—"
    ))
  end

  vim.ui.select(labels, { prompt = lang.t("pick_draft") }, function(_, idx)
    if idx then
      M.open_draft(draft_dir() .. "/" .. files[idx])
    end
  end)
end

-- Start a new message.
function M.compose()
  stash()

  local account = state.account or "(既定)"
  pending = { kind = "compose", original_subject = nil }

  local lines = header_lines(account, "", "", "")
  table.insert(lines, "")
  open_buffer(lines, first_gap(lines, "To"))
end

-- Pull addresses out of one header line, keeping the "Name <addr>" form.
local function header_addrs(text)
  local out = {}
  for _, part in ipairs(vim.split(text or "", ",", { plain = true })) do
    part = vim.trim(part)
    if part ~= "" then
      table.insert(out, part)
    end
  end
  return out
end

-- Remove yourself and any duplicates from an address list.
local function without(addrs, exclude)
  local seen, out = {}, {}

  for _, a in ipairs(addrs) do
    local email = (a:match("<([^>]+)>") or a):lower()
    email = vim.trim(email)

    local skip = email == "" or seen[email]
    for _, ex in ipairs(exclude) do
      if ex ~= "" and email == ex:lower() then
        skip = true
      end
    end

    if not skip then
      seen[email] = true
      table.insert(out, a)
    end
  end

  return out
end

-- Open a reply buffer.
--
--   all = true replies to everyone. himalaya v2 dropped
--   `message reply --all`, so the recipients are assembled here. The original
--   Cc is absent from the envelope, so it is read from the body's headers.
local function open_reply(envelope, all, extra_to, extra_cc)
  stash()

  local account = state.account or "(既定)"
  local my = ((config.options.accounts or {})[account] or {}).email or ""

  local to_list = header_addrs(format_addrs(envelope.from))
  local cc_list = {}

  if all then
    -- Fold the original recipients in, minus yourself.
    vim.list_extend(to_list, extra_to or {})
    cc_list = without(extra_cc or {}, { my })
  end

  -- Drop yourself, unless that would empty the list — replying to your own
  -- message is a legitimate case.
  local filtered = without(to_list, { my })
  to_list = #filtered > 0 and filtered or without(to_list, {})

  local subject = "Re: " .. util.strip_invisible(envelope.subject or "")

  pending = {
    kind = "reply",
    id = envelope.id,
    mailbox = state.mailbox,
    headline = quote_headline(envelope),
    original_subject = subject,
  }

  -- No quote here: himalaya appends it after the body on send. Including
  -- one would duplicate it.
  local lines =
    header_lines(account, table.concat(to_list, ", "), table.concat(cc_list, ", "), subject)
  table.insert(lines, "")

  open_buffer(lines, #lines - 1)
end

-- Reply. Omitting `all` follows the reply_mode setting.
function M.reply(envelope, all)
  if all == nil then
    all = config.options.reply_mode == "all"
  end

  if not all then
    return open_reply(envelope, false)
  end

  -- Replying to all needs the original To and Cc. Envelopes carry no Cc, so
  -- the body's headers are read; from the index that costs milliseconds, so it
  -- happens without announcing itself.
  local function with_body(body)
    local to_list, cc_list = {}, {}

    for _, line in ipairs(vim.split(body or "", "\n", { plain = true })) do
      if line == "" then
        break -- end of headers
      end
      local name, value = line:match("^([%w%-]+):%s*(.*)$")
      if name then
        local lower = name:lower()
        if lower == "to" then
          vim.list_extend(to_list, header_addrs(value))
        elseif lower == "cc" then
          vim.list_extend(cc_list, header_addrs(value))
        end
      end
    end

    open_reply(envelope, true, to_list, cc_list)
  end

  notmuch.read(envelope.id, function(ok, out)
    if not ok then
      vim.notify(lang.e("reply_fallback"), vim.log.levels.WARN)
      return open_reply(envelope, false)
    end
    with_body(out)
  end)
end

-- Reply the opposite way from the setting.
function M.reply_other(envelope)
  M.reply(envelope, config.options.reply_mode ~= "all")
end

-- Forward.
function M.forward(envelope)
  stash()

  local account = state.account or "(既定)"
  local subject = "Fwd: " .. util.strip_invisible(envelope.subject or "")

  pending = {
    kind = "forward",
    id = envelope.id,
    mailbox = state.mailbox,
    original_subject = subject,
  }

  local lines = header_lines(account, "", "", subject)
  table.insert(lines, "")
  open_buffer(lines, first_gap(lines, "To"))
end

return M
