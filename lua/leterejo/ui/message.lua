-- The message body buffer.
--
-- The body and the list of attachments are two separate questions for notmuch,
-- so both are asked at once and the slower one sets the wait. Neither costs
-- more than tens of milliseconds.
local config = require("leterejo.config")
local lang = require("leterejo.lang")
local notmuch = require("leterejo.notmuch")
local state = require("leterejo.state")
local util = require("leterejo.ui.util")

local M = {}

-- A fixed buffer name. Varying it per message would spawn a new buffer and
-- window on every open.
local BUFNAME = "leterejo://message"

local function find_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == BUFNAME then
      return b
    end
  end
  return nil
end

-- Find the window showing the body; reuse it, or split a new one.
local function find_win(buf)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == buf then
      return w
    end
  end
  return nil
end

-- Split the headers into individual entries.
--
-- Headers run to the first blank line in "Name: value" form. Long values wrap
-- onto continuation lines beginning with a space or tab (RFC 5322 folding);
-- each entry keeps its continuations.
local function split_headers(lines)
  local headers = {}
  local i = 1

  while i <= #lines do
    local line = lines[i]
    if line == "" then
      i = i + 1
      break -- the body starts here
    end

    local name = line:match("^([%w%-_]+):")
    if name then
      local entry = { name = name:lower(), lines = { line } }
      i = i + 1
      -- Absorb the folded continuation lines
      while i <= #lines and lines[i] ~= "" and lines[i]:match("^[ \t]") do
        table.insert(entry.lines, lines[i])
        i = i + 1
      end
      table.insert(headers, entry)
    else
      -- Not shaped like a header; skip it defensively.
      i = i + 1
    end
  end

  return headers, i
end

-- Keys still listed at the top for anyone who turns show_hints back on. It is
-- off by default: the list is shown on a key instead (see ui/help.lua).
local HINTS = {
  { "reply", "hint_reply" },
  { "forward", "hint_forward" },
  { "attachments", "hint_attachments" },
  { "toggle_headers", "hint_headers" },
  { "toggle_seen", "hint_seen" },
  { "trash", "hint_trash" },
  { "archive", "hint_archive" },
  { "close", "hint_back" },
  { "move", "hint_move" },
  { "toggle_flagged", "hint_flagged" },
  { "spam", "hint_spam" },
}

-- Assemble the displayed lines from attachments, headers and body.
-- Returns the lines, and which line each attachment entry landed on. The
-- second is what tells the image layer where to draw.
local function compose(body, attachments, folded, tags)
  local lines = {}
  local rows = {}

  -- Which tags this message carries.
  --
  -- A message has as many as it likes — a tag is a Gmail label, and a label is
  -- not a place a message sits in but a thing said about it. The list can only
  -- show the one being looked through, so this is where the rest are visible.
  if tags and #tags > 0 then
    table.insert(lines, lang.t("tags_head", table.concat(tags, "  ")))
    table.insert(lines, "")
  end

  if config.options.show_hints then
    vim.list_extend(
      lines,
      require("leterejo.keymaps").hint_lines("message", HINTS, vim.api.nvim_win_get_width(0) - 2)
    )
    table.insert(lines, "")
  end

  if #attachments > 0 then
    table.insert(lines, lang.t("attachments_head", #attachments))
    for i, a in ipairs(attachments) do
      table.insert(
        lines,
        string.format("  %d. %s  (%s, %s)", i, a.name, a.content_type, util.format_size(a.size))
      )
      rows[i] = #lines
    end
    table.insert(lines, "")
  end

  local body_lines = vim.split(util.strip_deceptive(body), "\n", { plain = true })

  if not folded then
    vim.list_extend(lines, body_lines)
    return lines, rows
  end

  local headers, body_start = split_headers(body_lines)

  -- Keep only the headers worth showing; dozens of Received: lines push
  -- the body far down.
  local wanted = {}
  for _, n in ipairs(config.options.visible_headers or {}) do
    wanted[n] = true
  end

  local shown, hidden = 0, 0
  for _, h in ipairs(headers) do
    if wanted[h.name] then
      vim.list_extend(lines, h.lines)
      shown = shown + 1
    else
      hidden = hidden + 1
    end
  end

  if hidden > 0 then
    table.insert(
      lines,
      lang.t("headers_folded", hidden, require("leterejo.keymaps").label("message", "toggle_headers"))
    )
  end
  table.insert(lines, "")

  -- Body
  for i = body_start, #body_lines do
    table.insert(lines, body_lines[i])
  end

  return lines, rows
end

-- Whether the body is laid out in columns rather than flowing text.
--
-- w3m honours the width it is given for prose but not for a table: it will not
-- shrink one below the sum of its columns, so a wide table comes back at two or
-- three times the window. Wrapping then folds every row and the table is gone.
-- Turning wrap off fixes that, but it would also push the text of a message
-- whose long lines are just tracking URLs off the side — and measured over 80
-- messages here, 46% have long lines, most of them exactly that.
--
-- The two are easy to tell apart. A table row is padded into columns, so it
-- carries a dozen or more runs of two spaces; a URL carries none.
local function laid_out(lines, width)
  local found = 0
  for _, line in ipairs(lines) do
    if vim.fn.strdisplaywidth(line) > width then
      local _, runs = line:gsub("  +", "")
      if runs >= 3 then
        found = found + 1
        if found >= 2 then
          return true
        end
      end
    end
  end
  return false
end

-- Whether to wrap the body of the message in hand.
local function wrapping(m, lines, width)
  if m.wrap ~= nil then
    return m.wrap -- the reader said so
  end

  local mode = config.options.message_wrap
  if mode == true or mode == false then
    return mode
  end
  return not laid_out(lines, width)
end

-- Toggle header folding on the current message and redraw.
local function toggle_headers()
  local m = state.current_message
  if not m or not m.body then
    return
  end

  m.folded = not m.folded
  M.render(m)
  vim.notify(m.folded and lang.t("headers_now_folded") or lang.t("headers_now_shown"), vim.log.levels.INFO)
end

-- Save the attachments of the displayed message, opening what we can.
local function download()
  local m = state.current_message
  if not m then
    return vim.notify(lang.e("no_message_shown"), vim.log.levels.WARN)
  end

  require("leterejo.attachments").download_and_open(m.id, m.attachments or {})
end

local function setup_keymaps(buf)
  local function close()
    -- Closing the body while it was following the cursor means "stop
    -- following": otherwise the next movement opens it again, and the window
    -- cannot be closed at all, only argued with.
    if state.preview_id ~= nil then
      state.preview_enabled = false
      state.preview_id = nil
    end

    local win = find_win(buf)
    if win and #vim.api.nvim_list_wins() > 1 then
      vim.api.nvim_win_close(win, true)
    end
  end

  -- Recover the envelope behind the displayed message, for reply/forward.
  local function current_envelope()
    local m = state.current_message
    if not m then
      return nil
    end
    for _, e in ipairs(state.envelopes or {}) do
      if tostring(e.id) == tostring(m.id) then
        return e
      end
    end
    return nil
  end

  -- Run an operation on the message on display.
  --
  -- The envelope is what the operations work on, so a message whose list has
  -- moved on cannot be acted upon — the same limit reply and forward have.
  local function act(name, close_after)
    return function()
      local e = current_envelope()
      if not e then
        return vim.notify(lang.e("source_not_found"), vim.log.levels.WARN)
      end

      -- A message moved out of this mailbox is no longer readable at this
      -- id, so stop showing it.
      local after = close_after
        and function()
          state.current_message = nil
          close()
        end

      require("leterejo.actions")[name](e, after or nil)
    end
  end

  require("leterejo.keymaps").apply(buf, "message", {
    close = { handler = close, desc = lang.t("desc_back") },
    toggle_seen = { handler = act("toggle_seen"), desc = lang.t("desc_toggle_seen") },
    toggle_flagged = { handler = act("toggle_flagged"), desc = lang.t("desc_toggle_flagged") },
    trash = { handler = act("trash", true), desc = lang.t("desc_trash") },
    archive = { handler = act("archive", true), desc = lang.t("desc_archive") },
    spam = { handler = act("spam", true), desc = lang.t("desc_spam") },
    move = { handler = act("move", true), desc = lang.t("desc_move") },
    close_alt = { handler = close, desc = lang.t("desc_back") },
    attachments = { handler = download, desc = lang.t("desc_attachments") },
    toggle_headers = { handler = toggle_headers, desc = lang.t("desc_toggle_headers") },
    toggle_wrap = {
      desc = lang.t("desc_toggle_wrap"),
      handler = function()
        local m = state.current_message
        if not m then
          return
        end
        local win = find_win(find_buf())
        m.wrap = not (win and vim.wo[win].wrap)
        M.render(m, { focus = false })
        vim.notify(m.wrap and lang.t("wrap_on") or lang.t("wrap_off"), vim.log.levels.INFO)
      end,
    },
    help = {
      desc = lang.t("desc_help"),
      handler = function()
        require("leterejo.ui.help").open("message")
      end,
    },
    reply = {
      desc = lang.t("desc_reply"),
      handler = function()
        local e = current_envelope()
        if e then
          require("leterejo.compose").reply(e)
        else
          vim.notify(lang.e("source_not_found"), vim.log.levels.WARN)
        end
      end,
    },
    reply_other = {
      desc = lang.t("desc_reply_other"),
      handler = function()
        local e = current_envelope()
        if e then
          require("leterejo.compose").reply_other(e)
        else
          vim.notify(lang.e("source_not_found"), vim.log.levels.WARN)
        end
      end,
    },
    forward = {
      desc = lang.t("desc_forward"),
      handler = function()
        local e = current_envelope()
        if e then
          require("leterejo.compose").forward(e)
        else
          vim.notify(lang.e("source_not_found"), vim.log.levels.WARN)
        end
      end,
    },
  })
end

-- The window showing the body, creating it if there is none.
--
--   opts.where : "below" (default) or "right"
--   opts.ratio : how much of the pane the split takes when it is made
local function ensure_win(buf, opts)
  local win = find_win(buf)
  if win then
    return win
  end

  opts = opts or {}
  local side = opts.where == "right"

  local from = vim.api.nvim_get_current_win()
  vim.cmd(side and "botright vsplit" or "botright split")
  win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)

  if opts.ratio then
    if side then
      vim.api.nvim_win_set_width(win, math.max(30, math.floor(vim.o.columns * opts.ratio)))
    else
      vim.api.nvim_win_set_height(win, math.max(5, math.floor(vim.o.lines * opts.ratio)))
    end
  end

  -- Splitting moves the cursor into the new window. Put it back and let the
  -- caller decide, or the list loses the cursor every time a preview appears.
  if vim.api.nvim_win_is_valid(from) then
    vim.api.nvim_set_current_win(from)
  end

  -- Making this window took space from the list, and a side-by-side split takes
  -- half its width. The list laid its columns out against the width it had a
  -- moment ago, so it has to be told.
  vim.schedule(function()
    require("leterejo.ui.envelopes").redraw()
  end)

  return win
end

M.find_win = function()
  local buf = find_buf()
  return buf and find_win(buf) or nil
end

-- Redraw the displayed message.
--
--   opts.focus : move the cursor into the body window (true by default)
--   opts.ratio : height of the split, as a fraction of the screen
function M.render(m, opts)
  opts = opts or {}
  local lines, rows = compose(m.body, m.attachments or {}, m.folded, m.tags)

  local buf = find_buf()
  if not buf then
    buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(buf, BUFNAME)
    vim.bo[buf].buftype = "nofile"
    -- Keep the buffer when the window closes so reopening is cheap.
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "mail"
    setup_keymaps(buf)
  end

  -- Display only; no editing.
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  -- Reuse the existing body window; without this every message adds one.
  local win = ensure_win(buf, opts)

  local width = vim.api.nvim_win_get_width(win)
  vim.wo[win].wrap = wrapping(m, lines, width)
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })

  if opts.focus ~= false then
    vim.api.nvim_set_current_win(win)
  end

  -- After the lines, so the rows the images hang off already exist.
  require("leterejo.ui.images").show(buf, m.id, m.attachments or {}, rows)
end

-- Open the body of an envelope.
--
--   opts.focus  : move into the body window afterwards (true by default)
--   opts.ratio  : height of the split when it has to be made
--   opts.quiet  : do not announce the fetch (for a preview that follows the
--                 cursor, where a notification per row would be a nuisance)
--   opts.token  : discarded if state.preview_token has moved on since. A
--                 preview issued for a row the cursor has already left must not
--                 overwrite the one for the row it is on now.
function M.open(envelope, opts)
  opts = opts or {}

  -- Asking for a body outright is asking for the pane back.
  if not opts.quiet then
    state.preview_enabled = nil
  end

  local account, mailbox, id = state.account, state.mailbox, envelope.id

  local function stale()
    return opts.token ~= nil and opts.token ~= state.preview_token
  end

  if not opts.quiet then
    local subject = util.strip_invisible(envelope.subject or "")
    vim.notify(lang.t("reading", subject), vim.log.levels.INFO)
  end

  -- Ask for the body, the attachment list and the tags together; the body
  -- sets the wait.
  local body, attachments, tags
  local body_done, struct_done, tags_done = false, false, false

  local function finish()
    if not (body_done and struct_done and tags_done) then
      return
    end
    if not body then
      return -- nothing to show without a body (already reported)
    end

    attachments = attachments or {}

    if stale() then
      return
    end

    state.current_message = {
      account = account,
      mailbox = mailbox,
      id = id,
      body = body,
      attachments = attachments,
      tags = tags,
      folded = config.options.fold_headers,
    }
    M.render(state.current_message, opts)
  end

  notmuch.read(id, function(ok, out)
    if ok then
      body = out
    elseif not opts.quiet then
      vim.notify(lang.t("prefix") .. out, vim.log.levels.ERROR)
    end
    body_done = true
    finish()
  end)

  notmuch.tags_of(id, function(ok, found)
    tags = ok and found or nil
    tags_done = true
    finish()
  end)

  notmuch.attachments(id, function(ok, atts)
    -- Show the body even without the list; only the attachments are missing,
    -- which is a small loss.
    attachments = ok and atts or {}
    struct_done = true
    finish()
  end)
end

return M
