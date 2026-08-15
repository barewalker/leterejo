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
-- Fill {name} and its neighbours in a line the sender wrote.
--
-- The same names the templates use, so there is one thing to learn rather than
-- two. Anything unrecognised is left alone: a brace in prose should survive.
local function substitute(text, values)
  return (tostring(text):gsub("{(%w+)}", function(key)
    return values[key] or ("{" .. key .. "}")
  end))
end

local function quote_headline(envelope)
  local first = (envelope.from or {})[1] or {}
  local name = first.name
  if name == nil or name == vim.NIL or name == "" then
    name = first.email or ""
  end

  local values = {
    date = util.format_date(envelope.date, true),
    name = util.strip_invisible(tostring(name)),
    email = tostring(first.email or ""),
    address = format_addrs(envelope.from),
    subject = util.strip_invisible(envelope.subject or ""),
  }

  local quote = config.options.quote or {}
  local written = values.address ~= "" and quote.headline or quote.headline_no_name

  if type(written) == "string" and written ~= "" then
    return substitute(written, values)
  end

  if values.address == "" then
    return lang.m("quote_headline_noname", values.date)
  end
  return lang.m("quote_headline", values.date, values.address)
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

-- The header area ------------------------------------------------------------
--
-- One line per field, holding the value and nothing else. The name is drawn
-- beside it as virtual text: it is not text in the buffer, so it cannot be
-- deleted by accident, cannot be mistyped, and cannot be mistaken for
-- something to fill in. A rule under the last field says where the body
-- starts, and it is drawn too, for the same reason.
--
-- Mail really is a plain header block above a blank line, and that is what
-- goes out. It is not what has to be edited.

local FIELDS = {
  { key = "from", label = "From" },
  { key = "to", label = "To" },
  { key = "cc", label = "Cc" },
  { key = "bcc", label = "Bcc" },
  { key = "subject", label = "Subject" },
  -- Files to send with it, separated by commas. Filled in by a forward, from
  -- what the original carried; anything else can be added by hand or by the
  -- suggestion key, which offers a file browser here rather than an address.
  { key = "attach", label = "Attach" },
}

local HEADER_LINES = #FIELDS
local FIELD_INDEX = {}
for i, f in ipairs(FIELDS) do
  FIELD_INDEX[f.key] = i
end

local ns = vim.api.nvim_create_namespace("leterejo-compose")

-- The label column, wide enough for the longest name and a gap after it.
local LABEL_WIDTH = (function()
  local w = 0
  for _, f in ipairs(FIELDS) do
    w = math.max(w, #f.label)
  end
  return w + 2
end)()

local function decorate(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  for i, f in ipairs(FIELDS) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, 0, {
      virt_text = { { string.format("%-" .. LABEL_WIDTH .. "s", f.label), "LeterejoComposeField" } },
      virt_text_pos = "inline",
      right_gravity = false,
    })
  end

  -- Where the headers stop. A drawn line rather than a typed one, so there is
  -- nothing to delete and nothing to wonder about.
  local width = math.max(40, math.min(vim.o.columns, 100)) - LABEL_WIDTH
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, HEADER_LINES - 1, 0, {
    virt_lines = { { { string.rep("─", width), "LeterejoComposeRule" } } },
  })
end

-- Keep the shape of the header area whatever is done to it.
--
-- A line can still be deleted — this is an editor — but the field it stood for
-- would then be someone else's, and the body would climb into the headers. So
-- the count is restored, empty, and what was typed keeps its meaning.
local function guard(buf)
  local repairing = false

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    desc = "leterejo: keep the compose header area intact",
    callback = function()
      if repairing or not vim.api.nvim_buf_is_valid(buf) then
        return
      end

      local count = vim.api.nvim_buf_line_count(buf)
      if count < HEADER_LINES then
        repairing = true
        local missing = {}
        for _ = 1, HEADER_LINES - count do
          table.insert(missing, "")
        end
        vim.api.nvim_buf_set_lines(buf, count, count, false, missing)
        repairing = false
      end

      decorate(buf)
    end,
  })

  -- Drawn again as the cursor moves as well. An extmark travels with the line
  -- it was put on, so anything that removes or joins a line takes a name with
  -- it; redrawing costs six marks and means a form that has been knocked out of
  -- shape shows it at once rather than quietly misfiling what is typed next.
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertLeave", "VimResized", "WinResized" }, {
    buffer = buf,
    desc = "leterejo: keep the field names on their fields",
    callback = function()
      decorate(buf)
    end,
  })
end

-- The header area behaves like a form, not like text.
--
-- The accidents worth preventing are the ordinary ones: Enter in the middle of
-- a field splitting it in two, dd taking a field away and pulling the body up
-- into its place, o opening a line where a field is expected. None of those
-- mean anything here, so each is given the meaning it should have — move to
-- the next field, clear this one, leave the shape alone.
local function form_keys(buf)
  local function in_header()
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(win) ~= buf then
      return false
    end
    return vim.api.nvim_win_get_cursor(win)[1] <= HEADER_LINES
  end

  -- These return keys rather than doing the work: an expression mapping is not
  -- allowed to change the buffer itself.
  local function keys(s)
    return vim.api.nvim_replace_termcodes(s, true, false, true)
  end

  local function map(mode, lhs, fn)
    vim.keymap.set(mode, lhs, fn, { buffer = buf, expr = true, silent = true })
  end

  -- Clear the field rather than take the line away, which would hand the
  -- field's place to the one below it and pull the body up.
  map("n", "dd", function()
    return in_header() and keys("0D") or "dd"
  end)

  -- A field is not somewhere to open a line. Move between them instead.
  map("n", "o", function()
    return in_header() and keys("j$a") or "o"
  end)
  map("n", "O", function()
    return in_header() and keys("k$a") or "O"
  end)

  map("n", "J", function()
    return in_header() and "" or "J"
  end)

  -- Enter moves to the next field, as it does in every other form. Splitting a
  -- header in two is never what was meant.
  map("i", "<cr>", function()
    return in_header() and keys("<esc>j$a") or keys("<cr>")
  end)

  -- Backspace at the start of a field, and Delete at the end of one, join it to
  -- its neighbour. That is how two fields become one line — the names then sit
  -- side by side, and every value below is a field out of step. There is
  -- nothing there to delete, so nothing happens.
  local function at_edge(which)
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(win) ~= buf then
      return false
    end

    local pos = vim.api.nvim_win_get_cursor(win)

    if which == "start" then
      -- The first body line counts too: joining it upwards puts the body into
      -- the subject, which is the same damage from the other side.
      return pos[2] == 0 and pos[1] <= HEADER_LINES + 1
    end

    if pos[1] > HEADER_LINES then
      return false
    end

    local line = vim.api.nvim_buf_get_lines(buf, pos[1] - 1, pos[1], false)[1] or ""
    return pos[2] >= #line
  end

  map("i", "<bs>", function()
    return at_edge("start") and "" or keys("<bs>")
  end)
  map("i", "<del>", function()
    return at_edge("end") and "" or keys("<del>")
  end)

  -- Tab in a field asks who. It has no other meaning in an address.
  vim.keymap.set("i", "<tab>", function()
    if in_header() then
      return vim.schedule(function()
        M.suggest()
      end)
    end
    vim.api.nvim_feedkeys(keys("<tab>"), "n", false)
  end, { buffer = buf, silent = true })
end

-- What is in the header area, and what is under it.
local function read_form(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local values = {}
  for i, f in ipairs(FIELDS) do
    values[f.key] = vim.trim(lines[i] or "")
  end

  local body = table.concat(vim.list_slice(lines, HEADER_LINES + 1, #lines), "\n")
  return values, body
end

-- The buffer's contents as a message: the header block mail actually uses.
-- Written to a draft file, and read back from one.
local function as_message(values, body, extra)
  local out = {}
  for _, f in ipairs(FIELDS) do
    table.insert(out, f.label .. ": " .. (values[f.key] or ""))
  end
  vim.list_extend(out, extra or {})
  table.insert(out, "")
  vim.list_extend(out, vim.split(body or "", "\n", { plain = true }))
  return out
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

  local values, body = read_form(buf)

  -- The account named in the draft, for an address no account owns; otherwise
  -- the one being read. From is what usually decides, just below.
  local named = pending.account
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
  local from = parse_addrs(values.from)[1]
    or ((config.options.accounts or {})[named] or {}).email

  if not from or from == "" then
    vim.notify(lang.e("no_email_configured", named), vim.log.levels.ERROR)
    return nil
  end

  local account = M.account_for(from) or named
  local to = parse_addrs(values.to)

  if strict and #to == 0 then
    vim.notify(lang.e("to_empty"), vim.log.levels.ERROR)
    return nil
  end
  if strict and vim.trim(body) == "" then
    vim.notify(lang.e("body_empty"), vim.log.levels.ERROR)
    return nil
  end

  local cc = parse_addrs(values.cc)
  local bcc = parse_addrs(values.bcc)

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

  -- Assemble. Subject and body encoding are himalaya's work.
  --
  -- Always `compose`, even for a reply. `message reply` wants the id the
  -- backend uses — an IMAP UID — and what this holds is a Message-ID, which is
  -- all notmuch can look a message up by. So the answer is written here: the
  -- recipients, the quote, and the headers that keep it in its thread.
  --
  -- Every value is joined to its option with "=" rather than passed as the next
  -- argument. himalaya's parser will not accept a value beginning with a hyphen
  -- in the separate form, so a message opening with a line of dashes — a
  -- signature, a rule above a quote — failed to send with
  -- `unexpected argument '---'`. The joined form has no such rule.
  local args = { "message", "compose" }

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

  -- The subject as written. himalaya used to prefix "Re:" itself on a reply;
  -- nothing does now, because the reply is assembled here and the prefix is
  -- already in the field where it can be seen and changed.
  table.insert(args, "--subject=" .. (values.subject or ""))

  table.insert(args, "--body=" .. body)

  -- What goes with it. himalaya reads the file, so a path that is gone by then
  -- is its error to report rather than something to hide here.
  for _, path in ipairs(vim.split(values.attach or "", ",", { plain = true })) do
    path = vim.trim(path)
    if path ~= "" then
      table.insert(args, "--attach=" .. vim.fn.expand(path))
    end
  end

  -- What keeps a reply in its thread. Not something himalaya can be told, so
  -- it is put into the message after it has built it.
  local extra = {}
  if pending.reply_to and pending.reply_to ~= "" then
    table.insert(extra, "In-Reply-To: " .. pending.reply_to)
    table.insert(extra, "References: " .. (pending.references or pending.reply_to))
  end

  return { buf = buf, args = args, account = account, from = from, bcc = bcc, extra = extra }
end

-- Give the Message-ID the domain the message is from.
--
-- himalaya builds one from this machine's hostname — `@my-desktop` — which
-- is not a domain anyone can look up and does not match the sender. It has no
-- bearing on SPF, DKIM or DMARC, none of which read it, but a receiving filter
-- that compares it with From has one more reason to doubt the message, and
-- every other client sends the two matching. Outlook, from the same address:
--
--     <000901dcb27f$8bbccff0$a3366fd0$@work.example>
--
-- The unique part is himalaya's; only the host after it is replaced.
local function with_sender_domain(message, from)
  if (config.options.message_id_domain or "from") ~= "from" then
    return message
  end

  local domain = tostring(from or ""):match("@([%w%.%-]+)%s*$")
  if not domain then
    return message
  end

  return (message:gsub("^(Message%-I[Dd]:%s*<[^@>]*)@[^>]*>", "%1@" .. domain .. ">", 1))
end

-- Put the threading headers into a message himalaya has already built.
--
-- After the first line, which keeps whatever himalaya chose to put first, and
-- before the blank line that ends the header block. The values are message
-- ids: ASCII, no encoding, nothing to get wrong.
local function with_headers(message, extra)
  if #extra == 0 then
    return message
  end

  local lines = vim.split(message, "\n", { plain = true })
  local out = { lines[1] }
  vim.list_extend(out, extra)
  vim.list_extend(out, vim.list_slice(lines, 2, #lines))
  return table.concat(out, "\n")
end

-- Send.
-- Send.
--
-- One step for a plain message: himalaya builds it and sends it. Two for a
-- reply, because the headers that keep it in its thread cannot be passed to
-- `compose` — so it builds the message to standard output, the headers go in,
-- and `send` takes it back on standard input. himalaya still does every part
-- of the encoding either way.
function M.send()
  local m = assemble(true)
  if not m then
    return
  end

  local a = (config.options.accounts or {})[m.account] or {}
  local sent = a.sent_mailbox or config.options.sent_mailbox
  local keep = type(sent) == "string" and sent ~= "" and sent or nil

  local label = #m.bcc > 0 and lang.t("bcc_note", table.concat(m.bcc, ", ")) or ""

  -- Say both when they differ. Sending as one address through another's server
  -- is the case most worth reading back before it goes.
  local own = a.email
  if own and own:lower() ~= m.from:lower() then
    vim.notify(lang.t("sending_via", m.from, m.account, label), vim.log.levels.INFO)
  else
    vim.notify(lang.t("sending", m.account, label), vim.log.levels.INFO)
  end

  local function failed(out, kind)
    -- A locked password store is not really a failure of the message; the
    -- draft is untouched and the same send will work once it is open. Offer
    -- to do that here rather than leave the user to work out that pinentry
    -- was what flashed past.
    if kind == "passphrase" then
      return M.unlock_then_send(m.account)
    end
    vim.notify(lang.e("send_failed") .. "\n" .. tostring(out), vim.log.levels.ERROR)
  end

  local function done()
    vim.notify(lang.t("sent"), vim.log.levels.INFO)

    -- The draft has been sent, so it is no longer a draft, and the copies
    -- taken out of the index to attach have done their work.
    if pending and pending.draft then
      os.remove(pending.draft)
    end
    if pending and pending.temporary then
      vim.fn.delete(pending.temporary, "rf")
    end
    pending = nil

    if vim.api.nvim_buf_is_valid(m.buf) then
      vim.bo[m.buf].modified = false
      vim.api.nvim_buf_delete(m.buf, { force = true })
    end
  end

  -- Straight through, when there is nothing to correct on the way.
  if #m.extra == 0 and (config.options.message_id_domain or "from") ~= "from" then
    local args = vim.deepcopy(m.args)
    table.insert(args, "--send")
    if keep then
      table.insert(args, "--save=" .. keep)
    end

    return cli.text(args, m.account, function(ok, out, kind)
      if not ok then
        return failed(out, kind)
      end
      done()
    end)
  end

  cli.text(m.args, m.account, function(ok, message, kind)
    if not ok then
      return failed(message, kind)
    end

    local args = { "message", "send" }
    if keep then
      table.insert(args, "--save=" .. keep)
    end

    cli.text(args, m.account, function(ok2, out2, kind2)
      if not ok2 then
        return failed(out2, kind2)
      end
      done()
    end, { stdin = with_sender_domain(with_headers(message, m.extra), m.from) })
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

  vim.notify(lang.t("draft_uploading", mailbox, m.account), vim.log.levels.INFO)

  local function done(ok, out)
    if not ok then
      return vim.notify(lang.e("draft_upload_failed") .. "\n" .. tostring(out), vim.log.levels.ERROR)
    end
    vim.notify(lang.t("draft_uploaded", mailbox), vim.log.levels.INFO)
  end

  -- Nothing to add: himalaya can build it and file it in one step.
  if #m.extra == 0 then
    local args = vim.deepcopy(m.args)
    table.insert(args, "--save=" .. mailbox)
    return cli.text(args, m.account, done)
  end

  -- A draft of a reply keeps what threads it, the same way the sent message
  -- does: built, added to, and then appended as a whole.
  cli.text(m.args, m.account, function(ok, message)
    if not ok then
      return done(false, message)
    end
    cli.text({ "message", "add", "--mailbox=" .. mailbox }, m.account, done, {
      stdin = with_sender_domain(with_headers(message, m.extra), m.from),
    })
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
      if pending and pending.temporary then
        vim.fn.delete(pending.temporary, "rf")
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

  if not pending.draft then
    vim.fn.mkdir(draft_dir(), "p")
    pending.draft = draft_dir() .. "/" .. draft_name()
  end

  local values, body = read_form(buf)
  local out = as_message(values, body, draft_headers())

  local written = pcall(vim.fn.writefile, out, pending.draft)
  if not written then
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
-- What the header area starts out holding.
--
-- From is filled in from the account being read; editing it is what chooses
-- the route, since an address belongs to the account that owns it.
local function form_values(account, to, cc, subject, attach)
  local from = ((config.options.accounts or {})[account] or {}).email or ""
  local auto = (config.options.auto_bcc or {})[from] or (config.options.auto_bcc or {})[account]

  return {
    from = from,
    to = to or "",
    cc = cc or "",
    bcc = auto or "",
    subject = subject or "",
    attach = attach or "",
  }
end

-- Open the buffer on a message being written.
--
--   values : what goes in the header area, by field
--   body   : the lines under it
--   at     : which body line to leave the cursor on, counted from the first
local function open_buffer(values, body, at)
  local buf = find_buf()
  if buf then
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(buf, BUFNAME)
  vim.bo[buf].buftype = "acwrite" -- lets :w mean something here
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "mail"

  local lines = {}
  for _, f in ipairs(FIELDS) do
    table.insert(lines, values[f.key] or "")
  end
  vim.list_extend(lines, body or { "" })

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false

  require("leterejo.ui.highlight").setup()
  decorate(buf)
  guard(buf)
  form_keys(buf)

  require("leterejo.keymaps").apply(buf, "compose", {
    send = { handler = M.send, desc = lang.t("desc_send") },
    save = { handler = M.save, desc = lang.t("desc_save_draft") },
    upload = { handler = M.upload, desc = lang.t("desc_upload_draft") },
    address = { handler = M.suggest, desc = lang.t("desc_suggest") },
    signature = { handler = M.pick_signature, desc = lang.t("desc_signature") },
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
  -- Which field is being edited decides where the next thing typed or chosen
  -- goes, so it should be visible rather than remembered.
  vim.wo.cursorline = true

  -- On the first empty field, or where the caller asked. Nothing is gained by
  -- starting on From, which is already right.
  local row = at and (HEADER_LINES + at) or nil
  if not row then
    row = FIELD_INDEX.to
    for _, f in ipairs(FIELDS) do
      if (values[f.key] or "") == "" then
        row = FIELD_INDEX[f.key]
        break
      end
    end
  end

  pcall(vim.api.nvim_win_set_cursor, 0, { math.min(row, vim.api.nvim_buf_line_count(buf)), 0 })

  return buf
end

local function as_lines(value)
  if type(value) == "table" then
    return vim.deepcopy(value)
  end
  if type(value) == "string" and value ~= "" then
    return vim.split(value, "\n", { plain = true })
  end
  return {}
end

-- Read a file, for a signature kept outside the configuration.
local function file_lines(path)
  local expanded = vim.fn.expand(path)
  if vim.fn.filereadable(expanded) ~= 1 then
    return {}
  end
  return vim.fn.readfile(expanded)
end

local function setting(account, name)
  local a = (config.options.accounts or {})[account] or {}
  if a[name] ~= nil then
    return a[name]
  end
  return config.options[name]
end

-- What is filled in for {name}, {email} and the rest.
--
-- The recipient's own name is the whole reason a reply template is worth
-- having in Japanese: "○○様" is how the message has to start, and typing it
-- out is exactly the work worth saving.
local function fill(lines, envelope)
  local first = envelope and (envelope.from or {})[1] or {}
  local name = first.name
  if name == nil or name == vim.NIL or name == "" then
    name = first.email or ""
  end

  local values = {
    name = util.strip_invisible(tostring(name)),
    email = tostring(first.email or ""),
    subject = util.strip_invisible(tostring(envelope and envelope.subject or "")),
    date = envelope and util.format_date(envelope.date) or "",
  }

  local out = {}
  for _, line in ipairs(lines) do
    table.insert(out, (line:gsub("{(%w+)}", function(key)
      return values[key] or ("{" .. key .. "}")
    end)))
  end
  return out
end

-- The body a buffer of this kind opens with, and where to leave the cursor in
-- it: after the template, on the blank line above the signature.
local function body_lines(account, kind, envelope)
  local templates = setting(account, "templates") or {}
  local body = fill(as_lines(templates[kind]), envelope)

  local signature = as_lines(setting(account, "signature"))
  if #signature == 0 then
    local path = setting(account, "signature_file")
    if type(path) == "string" and path ~= "" then
      signature = file_lines(path)
    end
  end

  local cursor = #body + 1
  table.insert(body, "")

  if #signature > 0 then
    -- The delimiter mail has used for this since RFC 3676: "-- ", the trailing
    -- space included. A reader that hides signatures looks for exactly that.
    table.insert(body, "-- ")
    vim.list_extend(body, signature)
  end

  return body, cursor
end

-- Suggesting an address ------------------------------------------------------

-- The window showing the message being written, whichever window is current.
--
-- Asking window zero would answer about wherever the cursor happens to be —
-- and the answer decides which field an address goes in, so it has to be the
-- right window rather than the current one.
local function compose_win(buf)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == buf then
      return w
    end
  end
  return nil
end

-- Which field the cursor is in, if it is in one.
local function current_field(buf)
  local win = compose_win(buf)
  if not win then
    return nil
  end

  local row = vim.api.nvim_win_get_cursor(win)[1]
  if row > HEADER_LINES then
    return nil
  end
  return FIELDS[row].key, row, FIELDS[row].label
end

-- Put an address in the field, after whatever is already there.
--
-- Except in From, which replaces: a message has one sender, and a second one
-- appended there would be a message nobody can send.
local function put_address(buf, row, address, replace)
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local value = vim.trim(line):gsub(",%s*$", "")
  local out = (replace or value == "") and address or (value .. ", " .. address)

  vim.api.nvim_buf_set_lines(buf, row - 1, row, false, { out })

  local win = compose_win(buf)
  if win then
    pcall(vim.api.nvim_win_set_cursor, win, { row, #out })
  end
end

-- Offer the addresses worth offering for the field under the cursor.
--
-- From is answered from the accounts, since those are the addresses this setup
-- can actually send as. The rest are answered from everyone written to or
-- heard from, which notmuch knows and this keeps in a file — collecting them
-- takes 18 seconds and nobody typing an address should wait for that.
function M.suggest()
  local buf = find_buf()
  if not buf then
    return
  end

  local key, row, label = current_field(buf)
  if not key then
    return vim.notify(lang.t("suggest_here_only"), vim.log.levels.INFO)
  end

  -- Name the field being filled. Which one it is decides everything about what
  -- happens next, so it should not have to be inferred from where the cursor
  -- was a moment ago.
  local prompt = lang.t("pick_address") .. " → " .. label
  local pick = require("leterejo.pickers").pick

  -- In the attachment field the question is which file, not which person.
  if key == "attach" then
    return vim.ui.input({
      prompt = lang.t("attach_prompt"),
      default = vim.fn.expand("~") .. "/",
      completion = "file",
    }, function(input)
      input = input and vim.trim(input) or ""
      if input == "" then
        return
      end
      if vim.fn.filereadable(vim.fn.expand(input)) ~= 1 then
        return vim.notify(lang.e("attach_missing", input), vim.log.levels.WARN)
      end
      put_address(buf, row, input)
    end)
  end

  if key == "from" then
    local items = {}
    for name, a in pairs(config.options.accounts or {}) do
      if a.email and a.email ~= "" then
        table.insert(items, a.email .. "   " .. name)
      end
    end
    table.sort(items)

    return pick(items, prompt, function(line)
      put_address(buf, row, (line:match("^(%S+)")), true)
    end)
  end

  -- The list may arrive twice: what was kept, and then what a refresh found.
  -- Only the first opens a picker; the second would land on top of it.
  local opened = false

  require("leterejo.notmuch").addresses(state.account, function(list)
    if opened then
      return
    end
    if #list == 0 then
      return vim.notify(lang.t("addresses_collecting"), vim.log.levels.INFO)
    end
    opened = true
    pick(list, prompt, function(line)
      put_address(buf, row, vim.trim(line))
    end)
  end)
end

-- Signatures -------------------------------------------------------------------

-- Replace whatever signature is there, or add one where there is none.
--
-- Found by the delimiter mail has used since RFC 3676: a line of exactly "-- ".
-- Anything below it belongs to the signature and goes with it.
local function replace_signature(buf, lines)
  local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local at = nil
  for i = #all, HEADER_LINES + 1, -1 do
    if all[i] == "-- " or all[i] == "--" then
      at = i
      break
    end
  end

  local block = {}
  if #lines > 0 then
    table.insert(block, "-- ")
    vim.list_extend(block, lines)
  end

  if at then
    return vim.api.nvim_buf_set_lines(buf, at - 1, -1, false, block)
  end
  if #block > 0 then
    vim.api.nvim_buf_set_lines(buf, #all, -1, false, vim.list_extend({ "" }, block))
  end
end

-- Choose which signature this message ends with.
function M.pick_signature()
  local buf = find_buf()
  if not buf then
    return
  end

  local named = config.options.signatures or {}
  local names = vim.tbl_keys(named)
  table.sort(names)

  if #names == 0 then
    return vim.notify(lang.t("no_signatures"), vim.log.levels.INFO)
  end

  local none = lang.t("signature_none")
  table.insert(names, none)

  require("leterejo.pickers").pick(names, lang.t("pick_signature"), function(name)
    replace_signature(buf, name == none and {} or as_lines(named[name]))
  end)
end

-- Open a draft that was written earlier.
--
-- The file is an ordinary message: a header block, a blank line, the body. The
-- headers that were only there to remember what the draft answers are taken
-- back out into `pending`, and the rest fill the form.
function M.open_draft(path)
  stash()

  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" or #lines == 0 then
    return vim.notify(lang.e("draft_unreadable", path), vim.log.levels.ERROR)
  end

  local p = { kind = "compose", draft = path }
  local values, body, in_headers = {}, {}, true

  for _, line in ipairs(lines) do
    if in_headers and line == "" then
      in_headers = false
    elseif in_headers then
      local name, value = line:match("^([%w%-]+):%s*(.*)$")
      name = name and name:lower() or nil

      if name == "x-leterejo-reply" then
        p.kind, p.id = "reply", value
      elseif name == "x-leterejo-forward" then
        p.kind, p.id = "forward", value
      elseif name == "x-leterejo-source" then
        p.mailbox = value
      elseif name == "x-leterejo-quote" then
        p.headline = value
      elseif name == "x-leterejo-account" then
        -- Written by an older draft; From decides the route now.
        p.account = value
      elseif name and FIELD_INDEX[name] then
        values[name] = value
      end
    else
      table.insert(body, line)
    end
  end

  -- himalaya prefixes "Re:" / "Fwd:" itself, so a subject that was not edited
  -- must not be passed on. What was written is what counts as unedited here.
  p.original_subject = values.subject

  pending = p
  open_buffer(values, #body > 0 and body or { "" })
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

  local account = state.account or lang.t("account_default")
  pending = { kind = "compose", original_subject = nil }

  open_buffer(form_values(account, "", "", ""), body_lines(account, "compose"))
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
-- The original, quoted.
--
-- Written into the buffer rather than left to himalaya, which cannot be asked
-- for it without the backend's own id. Being in the buffer is the better end
-- of that trade: what is quoted can be cut down to the part being answered,
-- which is what a reader of the reply wants and what a long thread needs.
local function quoted(headline, body)
  local out = { "", headline }

  -- The body notmuch renders opens with the headers; the quote starts at the
  -- message itself.
  local lines = vim.split(body or "", "\n", { plain = true })
  local at = 1
  for i, line in ipairs(lines) do
    if line == "" then
      at = i + 1
      break
    end
  end

  local mark = (config.options.quote or {}).prefix or "> "
  local blank = vim.trim(mark) ~= "" and vim.trim(mark) or mark

  for i = at, #lines do
    local line = lines[i]
    table.insert(out, line == "" and blank or (mark .. line))
  end

  -- A quote of nothing but blank lines is not worth carrying.
  while #out > 2 and out[#out] == blank do
    table.remove(out)
  end

  return out
end

local function open_reply(envelope, all, original, body)
  stash()

  local account = state.account or lang.t("account_default")
  local my = ((config.options.accounts or {})[account] or {}).email or ""

  local to_list = header_addrs(format_addrs(envelope.from))
  local cc_list = {}

  if all then
    -- Everyone the original was addressed to, minus yourself.
    vim.list_extend(to_list, header_addrs((original or {})["to"] or ""))
    cc_list = without(header_addrs((original or {})["cc"] or ""), { my })
  end

  -- Drop yourself, unless that would empty the list — replying to your own
  -- message is a legitimate case.
  local filtered = without(to_list, { my })
  to_list = #filtered > 0 and filtered or without(to_list, {})

  -- "Re:" once. A subject that already answers something is answered again
  -- without stacking another prefix on it.
  local subject = util.strip_invisible(envelope.subject or "")
  if not subject:lower():match("^re:") then
    subject = "Re: " .. subject
  end

  local message_id = (original or {})["message-id"]
  local references = (original or {})["references"]

  pending = {
    kind = "reply",
    id = envelope.id,
    mailbox = state.mailbox,
    original_subject = subject,
    -- What keeps the answer in the thread. References is the chain so far
    -- with this message on the end; a reader that threads by it wants both.
    reply_to = message_id,
    references = message_id and vim.trim((references or "") .. " " .. message_id) or nil,
  }

  local values = form_values(account, table.concat(to_list, ", "), table.concat(cc_list, ", "), subject)
  local lines, at = body_lines(account, "reply", envelope)

  if body then
    vim.list_extend(lines, quoted(quote_headline(envelope), body))
  end

  -- Straight into the body: a reply has its recipients and its subject
  -- already, and what is missing is what one came to write.
  open_buffer(values, lines, at)
end

-- Reply. Omitting `all` follows the reply_mode setting.
--
-- Two things are read first, and both come from the message itself: the
-- headers, for who else was written to and the ids that thread the answer, and
-- the body, to quote. Neither is in the envelope the list holds, and from the
-- index both cost milliseconds.
function M.reply(envelope, all)
  if all == nil then
    all = config.options.reply_mode == "all"
  end

  local original, body
  local headers_done, body_done = false, false

  local function ready()
    if headers_done and body_done then
      open_reply(envelope, all, original, body)
    end
  end

  notmuch.headers_of(state.account, envelope.id, { "message-id", "references", "to", "cc" }, function(ok, found)
    original = ok and found or {}
    headers_done = true
    ready()
  end)

  notmuch.read(state.account, envelope.id, function(ok, out)
    if not ok then
      vim.notify(lang.e("reply_no_quote"), vim.log.levels.WARN)
    end
    body = ok and out or nil
    body_done = true
    ready()
  end)
end

-- Reply the opposite way from the setting.
function M.reply_other(envelope)
  M.reply(envelope, config.options.reply_mode ~= "all")
end

-- Forward.
-- Forward.
--
-- The message is written out below what the sender adds, headed by the lines a
-- reader needs to know whose message it was. Attachments do not come with it:
-- himalaya's own forward would have carried them, but it needs the backend's
-- id for that, and what this holds is a Message-ID. Saying so is better than a
-- forward that quietly arrives without the file it was about.
-- Where a forwarded message's attachments are put on the way through.
--
-- They have to exist as files for himalaya to attach them, and they are not
-- the user's copies — saving them into the download directory would leave a
-- forwarded PDF sitting there for every message passed on. So: somewhere
-- temporary, named after the message, cleared when the message goes.
local function forward_dir(id)
  local digest = vim.fn.sha256(tostring(id)):sub(1, 16)
  return vim.fn.stdpath("cache") .. "/leterejo/forward/" .. digest
end

-- Forward.
--
-- The message is written out below what the sender adds, headed by the lines a
-- reader needs to know whose message it was, and what it carried is carried
-- with it: taken out of the index into a temporary directory and named in the
-- Attach field, where it can be seen and any of it removed before sending.
function M.forward(envelope)
  local account = state.account or lang.t("account_default")

  local subject = util.strip_invisible(envelope.subject or "")
  if not subject:lower():match("^fwd?:") then
    subject = "Fwd: " .. subject
  end

  local function open(original, body, attach)
    stash()

    pending = {
      kind = "forward",
      id = envelope.id,
      mailbox = state.mailbox,
      original_subject = subject,
      -- Cleared once it has gone or been discarded.
      temporary = #attach > 0 and forward_dir(envelope.id) or nil,
    }

    local lines = body_lines(account, "forward", envelope)

    if body then
      local quote = config.options.quote or {}

      table.insert(lines, "")
      table.insert(lines, quote.forwarded_head or lang.m("forwarded_head"))

      for _, name in ipairs(quote.forwarded_headers or { "from", "date", "subject", "to", "cc" }) do
        local value = (original or {})[name]
        if value and value ~= "" then
          local label = (quote.labels or {})[name] or lang.m("header_" .. name)
          table.insert(lines, label .. ": " .. value)
        end
      end
      vim.list_extend(lines, quoted("", body))
    end

    open_buffer(form_values(account, "", "", subject, table.concat(attach, ", ")), lines)

    if #attach > 0 then
      vim.notify(lang.t("forward_attachments", #attach), vim.log.levels.INFO)
    end
  end

  local original, body, attach
  local headers_done, body_done, files_done = false, false, false

  local function ready()
    if headers_done and body_done and files_done then
      open(original, body, attach or {})
    end
  end

  notmuch.headers_of(state.account, envelope.id, { "from", "date", "subject", "to", "cc" }, function(ok, found)
    original = ok and found or {}
    headers_done = true
    ready()
  end)

  notmuch.read(state.account, envelope.id, function(ok, out)
    if not ok then
      vim.notify(lang.e("reply_no_quote"), vim.log.levels.WARN)
    end
    body = ok and out or nil
    body_done = true
    ready()
  end)

  if not envelope["has-attachment"] then
    attach = {}
    files_done = true
    ready()
  else
    notmuch.save_attachments(state.account, envelope.id, forward_dir(envelope.id), function(ok, res)
      attach = {}
      for _, saved in ipairs(ok and (res.attachments or {}) or {}) do
        table.insert(attach, saved.path)
      end
      if not ok then
        vim.notify(lang.e("forward_attachments_failed"), vim.log.levels.WARN)
      end
      files_done = true
      ready()
    end)
  end
end

return M
