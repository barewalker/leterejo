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
}

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
