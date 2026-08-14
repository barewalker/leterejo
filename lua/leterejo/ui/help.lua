-- The key list, on demand.
--
-- It used to sit at the top of the list buffer permanently. That costs two or
-- three rows of every screen forever to teach something the user learns once,
-- and it pushed the mail itself down. It opens on a key instead.
local config = require("leterejo.config")
local lang = require("leterejo.lang")

local M = {}

-- Actions in the order worth reading, paired with the message describing them.
-- Anything bound but not listed here is appended afterwards, so a new action
-- cannot go missing from the help by being forgotten.
local ORDER = {
  envelopes = {
    { "read", "desc_read" },
    { "expand", "desc_expand" },
    { "collapse", "desc_collapse" },
    { "toggle_thread", "desc_toggle_thread" },
    { "reply", "desc_reply" },
    { "reply_other", "desc_reply_other" },
    { "forward", "desc_forward" },
    { "compose", "desc_compose" },
    { "toggle_seen", "desc_toggle_seen" },
    { "toggle_flagged", "desc_toggle_flagged" },
    { "archive", "desc_archive" },
    { "trash", "desc_trash" },
    { "spam", "desc_spam" },
    { "move", "desc_move" },
    { "attachments", "desc_attachments" },
    { "search", "desc_search" },
    { "clear_search", "desc_clear_search" },
    { "mailbox", "desc_mailbox" },
    { "account", "desc_account" },
    { "refresh", "desc_refresh" },
    { "next_page", "desc_next_page" },
    { "prev_page", "desc_prev_page" },
    { "help", "desc_help" },
    { "close", "desc_close" },
  },
  message = {
    { "reply", "desc_reply" },
    { "reply_other", "desc_reply_other" },
    { "forward", "desc_forward" },
    { "attachments", "desc_attachments" },
    { "toggle_headers", "desc_toggle_headers" },
    { "toggle_wrap", "desc_toggle_wrap" },
    { "toggle_seen", "desc_toggle_seen" },
    { "toggle_flagged", "desc_toggle_flagged" },
    { "archive", "desc_archive" },
    { "trash", "desc_trash" },
    { "spam", "desc_spam" },
    { "move", "desc_move" },
    { "help", "desc_help" },
    { "close", "desc_close" },
  },
}

-- Tidy a key for display: <cr> reads better as CR.
local function shown(key)
  return (key:gsub("^<(.-)>$", "%1"))
end

local function rows_for(scope)
  local spec = (config.options.keymaps or {})[scope] or {}
  local listed, rows = {}, {}

  for _, item in ipairs(ORDER[scope] or {}) do
    local key = spec[item[1]]
    listed[item[1]] = true
    if type(key) == "string" and key ~= "" then
      table.insert(rows, { shown(key), lang.t(item[2]) })
    end
  end

  -- Bound but not in ORDER: show it rather than let it stay hidden.
  local extra = {}
  for name, key in pairs(spec) do
    if not listed[name] and type(key) == "string" and key ~= "" then
      table.insert(extra, { shown(key), name })
    end
  end
  table.sort(extra, function(a, b)
    return a[2] < b[2]
  end)
  vim.list_extend(rows, extra)

  return rows
end

-- Show the keys bound in `scope` in a floating window.
function M.open(scope)
  local rows = rows_for(scope)
  if #rows == 0 then
    return vim.notify(lang.t("help_none"), vim.log.levels.INFO)
  end

  local key_width = 0
  for _, r in ipairs(rows) do
    key_width = math.max(key_width, vim.fn.strdisplaywidth(r[1]))
  end

  local lines, width = {}, 0
  for _, r in ipairs(rows) do
    local pad = string.rep(" ", key_width - vim.fn.strdisplaywidth(r[1]))
    local line = "  " .. pad .. r[1] .. "   " .. r[2]
    width = math.max(width, vim.fn.strdisplaywidth(line))
    table.insert(lines, line)
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  -- Colour the key itself so the eye can run down the column.
  local hl = require("leterejo.ui.highlight")
  for i, r in ipairs(rows) do
    local start = 2 + #string.rep(" ", key_width - vim.fn.strdisplaywidth(r[1]))
    pcall(vim.api.nvim_buf_set_extmark, buf, hl.ns, i - 1, start, {
      end_col = start + #r[1],
      hl_group = "LeterejoHeaderCount",
    })
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = math.min(width + 2, vim.o.columns - 4),
    height = math.min(#lines, vim.o.lines - 6),
    row = math.max(0, math.floor((vim.o.lines - #lines) / 2) - 2),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " " .. lang.t("help_title") .. " ",
    title_pos = "center",
  })
  vim.wo[win].cursorline = true

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  for _, key in ipairs({ "q", "<esc>", "<cr>" }) do
    vim.keymap.set("n", key, close, { buffer = buf, nowait = true, silent = true })
  end
end

return M
