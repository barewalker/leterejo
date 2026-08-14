-- Operations that change mail on the server.
--
-- Kept apart from the buffers because the list and the body act on the same
-- message and would otherwise hold two copies of this. Every operation here
-- refuses to run on a read-only account.
--
-- himalaya v2 spends seconds on each command, so the outcome is written into
-- the envelope we already hold and drawn straight away rather than waiting for
-- another list fetch. The next refetch confirms it.
local cli = require("leterejo.cli")
local config = require("leterejo.config")
local lang = require("leterejo.lang")
local state = require("leterejo.state")
local util = require("leterejo.ui.util")

local M = {}

local function err(msg)
  vim.notify(lang.t("prefix") .. tostring(msg), vim.log.levels.ERROR)
end

-- Refuse anything that would modify mail on a read-only account.
local function writable()
  if state.is_readonly() then
    vim.notify(lang.e("readonly_refused", state.account_label()), vim.log.levels.WARN)
    return false
  end
  return true
end

local function redraw()
  require("leterejo.ui.envelopes").redraw()
end

-- Whether we are still looking at what the operation was issued against.
-- Moving elsewhere mid-flight must not rewrite the list now on screen.
local function still_here(account, mailbox)
  return state.account == account and state.mailbox == mailbox
end

-- Record a flag change on the envelope in hand.
local function set_flag_locally(envelope, name, on)
  envelope.flags = envelope.flags or {}

  for i, f in ipairs(envelope.flags) do
    if f.iana == name then
      if not on then
        table.remove(envelope.flags, i)
      end
      return
    end
  end

  if on then
    table.insert(envelope.flags, { iana = name })
  end
end

-- Drop an envelope from the list on screen. Returns whether it was there.
--
-- A list grouped into conversations keeps the rows it was built from as well,
-- so the row has to go from both. Leaving it in the second would bring the
-- message back the next time a conversation is opened or closed.
local function forget_locally(envelope)
  local removed = false

  for i, e in ipairs(state.envelopes or {}) do
    if tostring(e.id) == tostring(envelope.id) then
      table.remove(state.envelopes, i)
      removed = true
      break
    end
  end

  for i, t in ipairs(state.threads or {}) do
    if tostring(t.id) == tostring(envelope.id) then
      table.remove(state.threads, i)
      break
    end
  end

  return removed
end

-- Flags --------------------------------------------------------------------

-- Add or remove one flag, whichever the message is not already.
local function toggle_flag(envelope, flag, on_key, off_key)
  if not envelope or not writable() then
    return
  end

  local account, mailbox = state.account, state.mailbox
  local set = util.has_flag(envelope, flag)
  local call = set and cli.remove_flags or cli.add_flags

  call(account, mailbox, { envelope.id }, { flag }, function(ok, res)
    if not ok then
      return err(res)
    end

    -- The envelope is the same object either way, so the flag is worth
    -- recording even if we have moved on; only the screen belongs to where
    -- we were.
    set_flag_locally(envelope, flag, not set)

    if still_here(account, mailbox) then
      redraw()
    end

    vim.notify(lang.t(set and off_key or on_key), vim.log.levels.INFO)
  end)
end

-- Mark read or unread.
--
-- Bodies are fetched with BODY.PEEK, so reading one never sets this by
-- itself; it is only ever set from here.
function M.toggle_seen(envelope)
  toggle_flag(envelope, "seen", "marked_read", "marked_unread")
end

-- Add or remove the flagged mark (a star, in most other clients).
function M.toggle_flagged(envelope)
  toggle_flag(envelope, "flagged", "marked_flagged", "marked_unflagged")
end

-- Moving -------------------------------------------------------------------

-- Move a message to another mailbox of the same account.
--
--   dest  : destination mailbox, as himalaya should receive it
--   after : called once the move has gone through
function M.move_to(envelope, dest, after)
  if not envelope or not writable() then
    return
  end

  if dest == state.mailbox then
    return vim.notify(lang.e("already_there", dest), vim.log.levels.WARN)
  end

  local account, mailbox = state.account, state.mailbox

  vim.notify(lang.t("moving", dest), vim.log.levels.INFO)

  cli.move_messages(account, mailbox, dest, { envelope.id }, function(ok, res)
    if not ok then
      return err(res)
    end

    -- Take the row off the screen rather than refetch the list for one
    -- message; the next refetch confirms it.
    if still_here(account, mailbox) and forget_locally(envelope) then
      redraw()
    end

    vim.notify(lang.t("moved", dest), vim.log.levels.INFO)

    if after then
      after()
    end
  end)
end

-- The mailbox this account uses for one of the moving actions.
local function target(name)
  local dest = config.account_option(state.account, name .. "_mailbox")
  if type(dest) ~= "string" or dest == "" then
    local kind = lang.t("kind_" .. name)
    vim.notify(lang.e("no_mailbox_configured", kind, state.account_label()), vim.log.levels.WARN)
    return nil
  end
  return dest
end

-- Delete, which here means moving to the trash.
--
-- v2 offers nothing else: there is no delete command, and its flag command
-- does not accept \Deleted. Moving is the better shape anyway — it is undone
-- by moving back.
function M.trash(envelope, after)
  if not envelope or not writable() then
    return
  end

  local dest = target("trash")
  if not dest then
    return
  end

  if not config.options.confirm_delete then
    return M.move_to(envelope, dest, after)
  end

  local subject = util.truncate(util.strip_invisible(envelope.subject or lang.t("no_subject")), 50)
  local yes = lang.t("trash_yes")

  vim.ui.select({ yes, lang.t("trash_no") }, { prompt = lang.t("trash_prompt", subject) }, function(choice)
    if choice == yes then
      M.move_to(envelope, dest, after)
    end
  end)
end

-- Archive: on Gmail this is a move to all-mail, which only takes the inbox
-- label off. Elsewhere it is whatever mailbox holds kept mail.
function M.archive(envelope, after)
  if not envelope or not writable() then
    return
  end

  local dest = target("archive")
  if dest then
    M.move_to(envelope, dest, after)
  end
end

-- Report as spam. On Gmail the move is what trains the filter.
function M.spam(envelope, after)
  if not envelope or not writable() then
    return
  end

  local dest = target("spam")
  if dest then
    M.move_to(envelope, dest, after)
  end
end

-- Move to a mailbox chosen from the list.
function M.move(envelope, after)
  if not envelope or not writable() then
    return
  end

  require("leterejo.pickers").pick_mailbox_name(lang.t("pick_move_target"), function(name)
    M.move_to(envelope, name, after)
  end)
end

return M
