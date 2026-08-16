-- The message as it arrived.
--
-- Everything else on the screen is a rendering: the list decodes and truncates,
-- the body is w3m's idea of some HTML, and the headers shown are the four
-- `notmuch show --format=text` hands over — out of the twenty-eight a message
-- here actually carries. None of that can answer "what did the server say about
-- this", which is the question behind every look at a Received chain, an
-- Authentication-Results, or a DKIM signature.
--
-- So this shows the file. Two views of it, because the two questions differ:
-- the header block alone is what is wanted when the body is not in doubt, and
-- the whole message is what is wanted when the MIME structure is.
local config = require("leterejo.config")
local lang = require("leterejo.lang")
local notmuch = require("leterejo.notmuch")

local M = {}

-- Split a header block into fields, keeping each field's lines as they are.
--
-- A field may be folded over several lines — a continuation begins with space
-- or tab — and the raw lines are what is being shown, so they are kept rather
-- than rebuilt. The joined form is only for decoding.
local function fields_in(lines)
  local fields = {}

  for _, line in ipairs(lines) do
    if line:match("^[ \t]") and #fields > 0 then
      local last = fields[#fields]
      table.insert(last.lines, line)
      last.value = last.value .. " " .. vim.trim(line)
    elseif line:match("^[^%s:]+:") then
      local name, value = line:match("^([^%s:]+):%s?(.*)$")
      table.insert(fields, { name = name, value = value or "", lines = { line } })
    elseif #fields == 0 then
      -- The "From " line an mbox-style store puts first, or anything else that
      -- is not a field. Shown, but not a field to decode.
      table.insert(fields, { name = nil, value = "", lines = { line } })
    end
  end

  return fields
end

-- What marks a line this view added rather than read.
--
-- It needs one. A header folded over several lines continues with whitespace,
-- so an indented decoding sitting under an indented continuation is
-- indistinguishable from it — and a view whose whole purpose is to show what
-- actually arrived must not quietly mix in lines that did not. ASCII, because
-- an arrow drawn with U+2192 is one cell or two depending on the terminal.
local ADDED = "        -> "

-- The header lines, with a decoding under each field that needs one.
--
-- Added rather than substituted: the encoded word is what was sent, and
-- replacing it would make this another rendering rather than the thing itself.
-- Only fields that actually change are given a second line.
local function with_decodings(fields)
  local out = {}

  for _, f in ipairs(fields) do
    vim.list_extend(out, f.lines)

    if f.name and f.value:find("=?", 1, true) then
      local decoded = notmuch.decode_header(f.value)
      if decoded ~= f.value and vim.trim(decoded) ~= "" then
        table.insert(out, ADDED .. decoded)
      end
    end
  end

  return out
end

-- Cut the file at the blank line that ends the headers.
local function header_lines(text)
  local lines = vim.split(text:gsub("\r\n", "\n"), "\n", { plain = true })

  for i, line in ipairs(lines) do
    if line == "" then
      return vim.list_slice(lines, 1, i - 1)
    end
  end

  return lines
end

local function find_win(name)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == name then
      return w, b
    end
  end
  return nil
end

local function draw(name, lines)
  local win, buf = find_win(name)

  if not win then
    local from = vim.api.nvim_get_current_win()
    vim.cmd("botright split")
    win = vim.api.nvim_get_current_win()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_buf_set_name(buf, name)

    -- Neovim's own mail syntax colours header names and quoted text, which is
    -- exactly the shape of what is in here.
    vim.bo[buf].filetype = "mail"
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.wo[win].wrap = false
    vim.wo[win].number = false

    local function close()
      if vim.api.nvim_win_is_valid(win) and #vim.api.nvim_list_wins() > 1 then
        vim.api.nvim_win_close(win, true)
      end
      if vim.api.nvim_win_is_valid(from) then
        vim.api.nvim_set_current_win(from)
      end
    end

    for _, key in ipairs({ "q", "<esc>" }) do
      vim.keymap.set("n", key, close, { buffer = buf, nowait = true, silent = true })
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  vim.api.nvim_set_current_win(win)
  pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
end

-- Show one message's source.
--
--   opts.headers_only : stop at the blank line that ends the headers
function M.open(account, id, opts)
  opts = opts or {}

  if not id then
    return vim.notify(lang.e("no_message_shown"), vim.log.levels.WARN)
  end

  notmuch.raw(account, id, function(ok, text)
    if not ok then
      return vim.notify(lang.t("prefix") .. tostring(text), vim.log.levels.ERROR)
    end

    local lines, name

    if opts.headers_only then
      local raw = header_lines(text)
      lines = config.options.headers_decoded ~= false and with_decodings(fields_in(raw)) or raw
      name = "leterejo://headers/" .. tostring(id)
    else
      lines = vim.split(text:gsub("\r\n", "\n"), "\n", { plain = true })
      name = "leterejo://source/" .. tostring(id)
    end

    -- A buffer line cannot hold a newline, and a line arriving from a message
    -- can hold anything at all.
    for i, line in ipairs(lines) do
      if line:find("[\r\n]") then
        lines[i] = line:gsub("[\r\n]", " ")
      end
    end

    draw(name, lines)
  end)
end

return M
