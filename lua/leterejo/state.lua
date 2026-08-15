-- Where we currently are: account and mailbox.
--
-- Both the list and the message buffer read this, so it lives apart from the
-- screen. Closing a buffer keeps the state, and reopening returns to the same
-- place.
local config = require("leterejo.config")

local M = {
  account = nil,
  mailbox = "inbox",

  -- Envelopes currently listed, kept so a row number maps back to one.
  --
  -- nil means "not fetched yet"; an empty table means "fetched, none found".
  -- Conflating the two shows "no messages" while a fetch is still running.
  --
  -- This is the flat list of drawn rows. While listing threads it is rebuilt
  -- from `threads` and `expanded` whenever either changes, and edited in place
  -- by the operations in between — a message that was just trashed leaves the
  -- screen without another fetch.
  envelopes = nil,

  -- Thread rows as fetched, before expansion is folded in.
  -- nil while listing messages rather than threads.
  threads = nil,

  -- Thread id -> its messages, for the threads the user opened.
  expanded = {},

  -- How far the continuous list has read, and how far it could go. `total` is
  -- nil until counted; `loading` guards against asking for the same batch
  -- twice while one request is still out.
  loaded = 0,
  total = nil,
  loading = false,

  -- The message on display. Attachment actions target it.
  -- { account, mailbox, id, attachments }
  current_message = nil,

  -- Which preview request is the current one.
  --
  -- Bodies arrive out of order when the cursor is moving, and a slow one for a
  -- row already left behind must not land on top of the row now under the
  -- cursor. Every request carries the token it was issued under and is dropped
  -- if this has moved on.
  preview_token = 0,

  -- The row the preview is showing, so an unchanged cursor fetches nothing.
  preview_id = nil,

  -- Whether the preview follows the cursor at the moment.
  --
  -- nil means "as configured". Closing the body window says no, and it stays
  -- no until asked for again: a window that reappears every time the cursor
  -- moves cannot be closed, only fought with.
  preview_enabled = nil,

  -- Active filter, or nil when not filtering.
  -- { text = "...", server = true|false, scanned = N }
  query = nil,

  -- The order the list is in, or nil for the configured one.
  --
  -- Kept here rather than in the configuration because it is a thing done to
  -- the list on screen, like a filter: chosen for one look at one mailbox and
  -- changed again a moment later.
  sort = nil,

  -- Message id -> true, for the rows picked out to be acted on together.
  --
  -- Ids rather than row numbers, so a reload that brings new mail in above them
  -- does not silently move the selection onto other messages.
  selected = {},
}

-- The order in force: what was chosen for this list, else what was configured.
function M.sorting()
  return M.sort or config.options.sort or "newest"
end

-- Selection -----------------------------------------------------------------

function M.is_selected(id)
  return M.selected[tostring(id)] == true
end

function M.toggle_selected(id)
  local key = tostring(id)
  M.selected[key] = not M.selected[key] or nil
end

function M.clear_selection()
  M.selected = {}
end

-- The selected rows, in the order they are drawn.
--
-- Read from the list rather than kept as a second list of its own: a message
-- that has been archived out of the view is no longer something an action can
-- be aimed at, and deriving this means there is nowhere for the two to disagree.
function M.selection()
  local out = {}
  for _, e in ipairs(M.envelopes or {}) do
    if M.is_selected(e.id) then
      table.insert(out, e)
    end
  end
  return out
end

-- Forget everything about the list currently held.
--
-- Called whenever what is being listed changes — another mailbox, another
-- account, a new filter. Keeping the old threads would show the previous
-- mailbox's conversations under the new mailbox's heading.
function M.reset_list()
  M.envelopes = nil
  M.threads = nil
  M.expanded = {}
  M.loaded = 0
  M.total = nil
  M.loading = false
  M.preview_id = nil
end

-- Whether the current account is read-only.
function M.is_readonly()
  return config.is_readonly(M.account)
end

-- Account name for display. Shows that himalaya's default is in use when
-- none was chosen.
function M.account_label()
  return M.account or require("leterejo.lang").t("account_default")
end

return M
