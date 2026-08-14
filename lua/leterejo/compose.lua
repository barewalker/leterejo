-- The compose buffer and sending.
--
-- Encoding (RFC 2047 subjects, base64 bodies, charsets) and quote assembly are
-- left entirely to himalaya. Those are the parts most likely to break on
-- non-ASCII mail, so nothing is assembled here: the text written is handed to
-- `--body` as is.
--
-- Consequently this buffer holds only the author's own words; himalaya appends
-- the quoted original on reply.
local cache = require("leterejo.cache")
local cli = require("leterejo.cli")
local config = require("leterejo.config")
local lang = require("leterejo.lang")
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

-- Split the buffer into headers and body.
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
    end
  end

  local body = table.concat(vim.list_slice(lines, body_start, #lines), "\n")
  return headers, body
end

-- Send.
function M.send()
  local buf = find_buf()
  if not buf or not pending then
    return vim.notify(lang.e("no_draft"), vim.log.levels.WARN)
  end

  local headers, body = parse_buffer(buf)

  local account = headers["x-leterejo-account"]
  if not account or account == "" then
    account = state.account
  end

  local to = parse_addrs(headers["to"])
  if #to == 0 then
    return vim.notify(lang.e("to_empty"), vim.log.levels.ERROR)
  end

  if vim.trim(body) == "" then
    return vim.notify(lang.e("body_empty"), vim.log.levels.ERROR)
  end

  local cc = parse_addrs(headers["cc"])
  local bcc = parse_addrs(headers["bcc"])

  -- Bcc yourself on this route to keep a copy. Some servers run tight on
  -- quota and skip the sent folder entirely.
  local auto = (config.options.auto_bcc or {})[account]
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
  local args
  if pending.kind == "reply" then
    args = { "message", "reply", tostring(pending.id) }
    if pending.mailbox then
      vim.list_extend(args, { "-m", pending.mailbox })
    end
    if pending.headline then
      vim.list_extend(args, { "-Q", pending.headline })
    end
  elseif pending.kind == "forward" then
    args = { "message", "forward", tostring(pending.id) }
    if pending.mailbox then
      vim.list_extend(args, { "-m", pending.mailbox })
    end
  else
    args = { "message", "compose" }
  end

  -- Always pass the sender. himalaya v2 does not fill From from its own
  -- configuration (v1's display-name and friends were removed), and without
  -- it sending stops at `No 'From:' header found in raw message`.
  local my = ((config.options.accounts or {})[account] or {}).email
  if not my or my == "" then
    return vim.notify(
      lang.e("no_email_configured", account),
      vim.log.levels.ERROR
    )
  end
  vim.list_extend(args, { "--from", my })

  for _, a in ipairs(to) do
    vim.list_extend(args, { "-t", a })
  end
  for _, a in ipairs(cc) do
    vim.list_extend(args, { "--cc", a })
  end
  for _, a in ipairs(bcc) do
    vim.list_extend(args, { "--bcc", a })
  end

  -- On reply and forward himalaya prefixes "Re:" / "Fwd:" itself, so only
  -- pass a subject when the user actually edited it.
  local subject = headers["subject"]
  if subject and subject ~= "" and subject ~= pending.original_subject then
    vim.list_extend(args, { "-s", subject })
  elseif pending.kind == "compose" then
    vim.list_extend(args, { "-s", subject or "" })
  end

  vim.list_extend(args, { "--body", body })
  table.insert(args, "--send")

  local label = #bcc > 0 and lang.t("bcc_note", table.concat(bcc, ", ")) or ""
  vim.notify(lang.t("sending", account, label), vim.log.levels.INFO)

  cli.text(args, account, function(ok, out)
    if not ok then
      return vim.notify(lang.e("send_failed") .. "\n" .. out, vim.log.levels.ERROR)
    end

    vim.notify(lang.t("sent"), vim.log.levels.INFO)
    pending = nil

    -- Clean up the buffer once sent.
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modified = false
      vim.api.nvim_buf_delete(buf, { force = true })
    end
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
      pending = nil
      vim.bo[buf].modified = false
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)
end

-- Prepare and open the buffer.
local function open_buffer(lines, cursor_line)
  local buf = find_buf()
  if buf then
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, BUFNAME)
  vim.bo[buf].buftype = "acwrite" -- lets :w send
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "mail"

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false

  require("leterejo.keymaps").apply(buf, "compose", {
    send = { handler = M.send, desc = lang.t("desc_send") },
    discard = { handler = discard, desc = lang.t("desc_discard") },
  })

  -- Allow :w to send, for anyone whose habit is write-then-save.
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      M.send()
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

-- Build the header block, keeping the outgoing account visible.
local function header_lines(account, to, cc, subject)
  local auto = (config.options.auto_bcc or {})[account]
  local lines = {
    "X-Sherpa-Account: " .. account,
    "To: " .. (to or ""),
    "Cc: " .. (cc or ""),
    "Bcc: " .. (auto or ""),
    "Subject: " .. (subject or ""),
    "",
  }
  return lines
end

-- Start a new message.
function M.compose()
  local account = state.account or "(既定)"
  pending = { kind = "compose", original_subject = nil }

  local lines = header_lines(account, "", "", "")
  table.insert(lines, "")
  open_buffer(lines, 2)
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
  -- read the body's headers; a remembered body means no wait in most cases.
  local account, mailbox, id = state.account, state.mailbox, envelope.id
  local hit = cache.get_message(account, mailbox, id)

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

  if hit and hit.body then
    return with_body(hit.body)
  end

  vim.notify(lang.t("looking_up"), vim.log.levels.INFO)
  cli.read_message(account, mailbox, id, function(ok, out)
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
  open_buffer(lines, 2)
end

return M
