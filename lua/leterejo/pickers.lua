-- Tag and account pickers.
--
-- Either list can run to dozens of entries, so fzf-lua is used when present
-- and vim.ui.select otherwise.
local cli = require("leterejo.cli")
local config = require("leterejo.config")
local lang = require("leterejo.lang")
local state = require("leterejo.state")

local M = {}

-- Pick with fzf-lua when available, else vim.ui.select.
local select

-- Pick from a list, by whichever picker is installed.
--
-- Exposed because everything that offers a list of things should offer it the
-- same way: tags, accounts, saved filters.
--
--   opts.multi : allow more than one, where the picker can. fzf-lua can (Tab
--                marks); vim.ui.select cannot, and takes one as before. The
--                callback is handed a list either way, so the caller does not
--                have to care which is installed.
function M.pick(items, prompt, on_choice, opts)
  return select(items, prompt, on_choice, opts)
end

select = function(items, prompt, on_choice, opts)
  opts = opts or {}

  if #items == 0 then
    return vim.notify(lang.e("no_candidates"), vim.log.levels.WARN)
  end

  local function answer(chosen)
    if not chosen or #chosen == 0 then
      return
    end
    on_choice(opts.multi and chosen or chosen[1])
  end

  local ok, fzf = pcall(require, "fzf-lua")
  if ok then
    fzf.fzf_exec(items, {
      prompt = prompt .. "> ",
      fzf_opts = opts.multi and { ["--multi"] = "" } or nil,
      actions = {
        ["default"] = function(selected)
          answer(selected)
        end,
      },
    })
    return
  end

  vim.ui.select(items, { prompt = prompt }, function(choice)
    answer(choice and { choice } or nil)
  end)
end

-- Ask for something to look at, and hand back the name.
--
-- Switching to one and moving a message into one are not the same question, so
-- they do not get the same list. Moving means putting a tag on, and a view —
-- a query with a name, such as a directory of archived mail — is not a tag and
-- must not be offered as one.
--
--   opts.tags_only : leave the views out
function M.pick_mailbox_name(prompt, on_choice, opts)
  opts = opts or {}

  local notmuch = require("leterejo.notmuch")

  -- `tags_only` asks for the places mail can be put, as against the places it
  -- can be looked at. On an account that files in directories those are its
  -- folders, and the tags are the wrong list to offer: `new.tags` there can be
  -- empty, so what the index holds describes a message (`attachment`,
  -- `spf-fail`, `zero-width`) and never names a place. Every one of them was
  -- refused by `file_into`, which left `inbox` unreachable — and `M` is the
  -- only way a message comes back out of Junk. (2026-09-06)
  if opts.tags_only then
    local a = (config.options.accounts or {})[state.account] or {}
    if a.folders and next(a.folders) ~= nil then
      local names = {}
      for name in pairs(a.folders) do
        table.insert(names, name)
      end
      table.sort(names)
      return select(names, prompt, on_choice)
    end

    return notmuch.tags(state.account, function(ok, tags)
      if not ok then
        return vim.notify(lang.t("prefix") .. tags, vim.log.levels.ERROR)
      end
      select(tags, prompt, on_choice)
    end)
  end

  notmuch.mailboxes(state.account, function(ok, names, kind)
    if not ok then
      return vim.notify(lang.t("prefix") .. names, vim.log.levels.ERROR)
    end

    -- Say which are not tags. The three behave differently — nothing can be
    -- moved into a view, while a folder is the one thing that can — and a list
    -- that looks uniform invites treating them alike.
    local said = { query = lang.t("is_a_view"), folder = lang.t("is_a_folder") }
    local items, name_of = {}, {}
    for _, name in ipairs(names) do
      local note = said[kind[name]]
      local line = note and (name .. "  " .. note) or name
      table.insert(items, line)
      name_of[line] = name
    end

    select(items, prompt, function(line)
      local name = name_of[line]
      if name then
        on_choice(name)
      end
    end)
  end)
end

function M.pick_mailbox()
  M.pick_mailbox_name(lang.t("pick_mailbox"), function(name)
    state.mailbox = name
    -- Rows picked out here are not on the screen we are going to, and a
    -- selection nobody can see is one the next key would act on unannounced.
    state.clear_selection()
    state.reset_list()
    require("leterejo.ui.envelopes").refresh()
  end)
end

function M.pick_account()
  cli.list_accounts(function(ok, res)
    if not ok then
      return vim.notify(lang.t("prefix") .. res, vim.log.levels.ERROR)
    end

    -- Leave out the accounts that exist only to send from.
    --
    -- Everything readable comes from one index, so an account whose mail was
    -- never synced here has nothing of its own to show: switching to it would
    -- draw the same messages under a different name, with a read-only marker
    -- that appears to be about them.
    local readable = {}
    for _, name in ipairs(res) do
      local a = (config.options.accounts or {})[name] or {}
      if not a.send_only then
        table.insert(readable, name)
      end
    end

    select(readable, lang.t("pick_account"), function(name)
      state.account = name
      -- Tag names differ per account, so fall back to the inbox.
      state.mailbox = "inbox"
      state.clear_selection()
      state.reset_list()
      require("leterejo.ui.envelopes").refresh()

      -- An account with nothing of its own draws the index anyway, which is
      -- another account's mail under this one's name. Say so: it looks like
      -- the switch worked, and every count and every write would be about
      -- someone else's mailbox.
      if not config.has_own_mail(name) then
        vim.notify(lang.e("account_not_synced", name), vim.log.levels.WARN)
      end
    end)
  end)
end

return M
