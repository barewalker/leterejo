-- Operations that change mail.
--
-- Kept apart from the buffers because the list and the body act on the same
-- message and would otherwise hold two copies of this. Every operation here
-- refuses to run on a read-only account.
--
-- Each one is a change of tags, and it happens in three steps. The index is
-- told, which costs milliseconds. The screen is corrected from what is already
-- held, so the row answers at once rather than waiting for a refetch. Then the
-- change is pushed to Gmail, and the tags are read back to see that it survived
-- — because a push lieer could not make is followed by a pull that undoes it.
local config = require("leterejo.config")
local lang = require("leterejo.lang")
local lieer = require("leterejo.lieer")
local notmuch = require("leterejo.notmuch")
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

-- The tag standing for one of the states this plugin knows by name.
--
-- lieer decides these: they are its translation of Gmail's own labels
-- (UNREAD, STARRED, INBOX, TRASH, SPAM). Configurable because a translation
-- overlay can change them, not because they are a matter of taste.
local function tag(kind)
  return (config.options.tags or {})[kind] or kind
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

-- Pushing it up ------------------------------------------------------------

-- Whether the tags a message now carries are the ones we asked for.
local function stuck(tags, change)
  local has = {}
  for _, t in ipairs(tags) do
    has[t] = true
  end

  for _, t in ipairs(change.add or {}) do
    if not has[t] then
      return false
    end
  end
  for _, t in ipairs(change.remove or {}) do
    if has[t] then
      return false
    end
  end
  return true
end

-- The list on screen is now wrong; say so and read it again.
--
-- Rare enough to be worth the whole refetch: it happens only when Gmail moved
-- on between our tagging and our push, and leaving a row showing a state that
-- was undone is worse than a moment's redraw.
--
-- `refusal` is what lieer said while exiting successfully, when it said
-- anything: the change was not sent, and its own words are more use than a
-- sentence of ours guessing at why.
local function reverted(id, change, refusal)
  local wanted = {}
  for _, t in ipairs(change.add or {}) do
    table.insert(wanted, "+" .. t)
  end
  for _, t in ipairs(change.remove or {}) do
    table.insert(wanted, "-" .. t)
  end

  vim.notify(lang.e("change_reverted", table.concat(wanted, " ")), vim.log.levels.WARN)
  if refusal then
    vim.notify(lang.t("prefix") .. refusal, vim.log.levels.WARN)
  end

  -- Take the change back out of the index as well.
  --
  -- Otherwise it is stranded: lieer's pull moves `lastmod` past a change it
  -- refused to push, so push never looks at it again, and the index keeps
  -- saying something Gmail does not — a message tagged both spam and inbox,
  -- which cannot be true there. Better to agree with the server about a change
  -- that did not happen than to remember one that never will.
  notmuch.tag(id, { add = change.remove, remove = change.add }, function()
    require("leterejo.ui.envelopes").refresh()
  end)
end

-- Check the change survived the sync, and reapply it once if it did not.
--
-- lieer will not push onto a remote that has moved on. It says it will re-try
-- at the next push, but the pull in the same run has already put the old tags
-- back by then, so there is nothing left to re-try. Setting them again against
-- the state that has just arrived is what actually gets it through.
local function confirm(account, id, change, tries, refusal)
  notmuch.tags_of(id, function(ok, tags)
    if not ok then
      return -- cannot tell; leave the screen alone rather than guess
    end
    if stuck(tags, change) then
      return
    end
    if tries <= 0 then
      return reverted(id, change, refusal)
    end

    notmuch.tag(id, change, function(tagged)
      if not tagged then
        return reverted(id, change, refusal)
      end
      lieer.sync(account, function(synced, _, refused)
        if not synced then
          return reverted(id, change, refusal)
        end
        confirm(account, id, change, tries - 1, refused or refusal)
      end)
    end)
  end)
end

-- Hand the change to Gmail, if there is anywhere to hand it to.
local function push(account, id, change)
  local opts = config.options.lieer or {}
  if opts.sync_on_write == false then
    return -- the user asked for writes to stay here until something syncs
  end

  if not lieer.configured(account) then
    return vim.notify(lang.e("no_lieer_dir_note"), vim.log.levels.WARN)
  end

  lieer.sync(account, function(ok, res, refused)
    if not ok then
      return vim.notify(lang.e("sync_failed", tostring(res)), vim.log.levels.WARN)
    end
    confirm(account, id, change, 1, refused)
  end)
end

-- Carrying one out ----------------------------------------------------------

-- Apply a change of tags to one message.
--
--   change  : { add = { "..." }, remove = { "..." } }
--   opts.locally : correct the envelope we hold, returning whether the row
--                  should leave the list
--   opts.said    : what to report once it has gone through
--   opts.after   : called once it has gone through
local function apply(envelope, change, opts)
  if not envelope or not writable() then
    return
  end

  local account, mailbox, id = state.account, state.mailbox, envelope.id

  notmuch.tag(id, change, function(ok, res)
    if not ok then
      return err(res)
    end

    local gone = opts.locally and opts.locally(envelope) or false
    if still_here(account, mailbox) and (not gone or forget_locally(envelope)) then
      redraw()
    end

    if opts.said then
      vim.notify(opts.said, vim.log.levels.INFO)
    end
    if opts.after then
      opts.after()
    end

    push(account, id, change)
  end)
end

-- Flags --------------------------------------------------------------------

-- Mark read or unread.
--
-- Reading a message never sets this by itself — nothing here writes to the
-- index while drawing — so it is only ever set from this key.
function M.toggle_seen(envelope)
  if not envelope then
    return
  end

  local seen = util.has_flag(envelope, "seen")
  local change = seen and { add = { tag("unread") } } or { remove = { tag("unread") } }

  apply(envelope, change, {
    said = lang.t(seen and "marked_unread" or "marked_read"),
    locally = function(e)
      set_flag_locally(e, "seen", not seen)
      return false
    end,
  })
end

-- Add or remove the flagged mark (a star, in most other clients).
function M.toggle_flagged(envelope)
  if not envelope then
    return
  end

  local flagged = util.has_flag(envelope, "flagged")
  local change = flagged and { remove = { tag("flagged") } } or { add = { tag("flagged") } }

  apply(envelope, change, {
    said = lang.t(flagged and "marked_unflagged" or "marked_flagged"),
    locally = function(e)
      set_flag_locally(e, "flagged", not flagged)
      return false
    end,
  })
end

-- Moving -------------------------------------------------------------------

-- Whether dropping these tags takes the message out of the list on screen.
local function leaves_view(change)
  local here = notmuch.tag_for(state.account, state.mailbox)
  return here ~= nil and vim.tbl_contains(change.remove or {}, here)
end

local function drops_row()
  return function()
    return true
  end
end

-- Archive: take the inbox label off and leave everything else alone. That is
-- what archiving is on Gmail, and there is no separate place the message goes.
function M.archive(envelope, after)
  local change = { remove = { tag("inbox") } }
  apply(envelope, change, {
    said = lang.t("archived"),
    after = after,
    locally = leaves_view(change) and drops_row() or nil,
  })
end

-- Delete, which here means the trash label. Undone by taking it off again.
function M.trash(envelope, after)
  if not envelope or not writable() then
    return
  end

  local change = { add = { tag("trash") }, remove = { tag("inbox") } }
  local function go()
    apply(envelope, change, { said = lang.t("trashed"), after = after, locally = drops_row() })
  end

  if not config.options.confirm_delete then
    return go()
  end

  local subject = util.truncate(util.strip_invisible(envelope.subject or lang.t("no_subject")), 50)
  local yes = lang.t("trash_yes")

  vim.ui.select({ yes, lang.t("trash_no") }, { prompt = lang.t("trash_prompt", subject) }, function(choice)
    if choice == yes then
      go()
    end
  end)
end

-- Report as spam. On Gmail the label is what trains the filter.
function M.spam(envelope, after)
  apply(envelope, { add = { tag("spam") }, remove = { tag("inbox") } }, {
    said = lang.t("spammed"),
    after = after,
    locally = drops_row(),
  })
end

-- Put tags on this message, and take others off, in one go.
--
-- A message carries as many tags as it likes — that is what a label is — so
-- this takes a set rather than one. Doing them together is not only tidier: it
-- is one push, and a push is the part that can be refused.
--
-- A tag Gmail has never heard of is made there by the sync: lieer sends the
-- label with the change and Gmail creates it. That is the whole of "making a
-- new label"; there is nowhere else to do it.
function M.change_tags(envelope, add, remove)
  if not envelope or not writable() then
    return
  end

  local change = { add = {}, remove = {} }
  for _, name in ipairs(add or {}) do
    name = vim.trim(tostring(name))
    if name ~= "" then
      table.insert(change.add, name)
    end
  end
  for _, name in ipairs(remove or {}) do
    name = vim.trim(tostring(name))
    if name ~= "" then
      table.insert(change.remove, name)
    end
  end

  if #change.add == 0 and #change.remove == 0 then
    return
  end

  local said = {}
  if #change.add > 0 then
    table.insert(said, lang.t("tag_added", table.concat(change.add, ", ")))
  end
  if #change.remove > 0 then
    table.insert(said, lang.t("tag_removed", table.concat(change.remove, ", ")))
  end

  apply(envelope, change, {
    said = table.concat(said, "  "),
    locally = leaves_view(change) and drops_row() or nil,
  })
end

-- Move to a mailbox chosen from the list, which on Gmail means relabelling:
-- the chosen label goes on, and the one being looked at comes off.
function M.move_to(envelope, dest, after)
  if not envelope or not writable() then
    return
  end

  if dest == state.mailbox then
    return vim.notify(lang.e("already_there", dest), vim.log.levels.WARN)
  end

  local change = { add = { dest } }
  local here = notmuch.tag_for(state.account, state.mailbox)
  if here then
    change.remove = { here }
  end

  vim.notify(lang.t("moving", dest), vim.log.levels.INFO)

  apply(envelope, change, {
    said = lang.t("moved", dest),
    after = after,
    locally = leaves_view(change) and drops_row() or nil,
  })
end

function M.move(envelope, after)
  if not envelope or not writable() then
    return
  end

  require("leterejo.pickers").pick_mailbox_name(lang.t("pick_move_target"), function(name)
    M.move_to(envelope, name, after)
  end)
end

return M
