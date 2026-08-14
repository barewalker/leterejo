-- Mailbox and account pickers.
--
-- Either list can run to dozens of entries, so fzf-lua is used when present
-- and vim.ui.select otherwise.
local cli = require("leterejo.cli")
local lang = require("leterejo.lang")
local state = require("leterejo.state")

local M = {}

-- Pick with fzf-lua when available, else vim.ui.select.
local function select(items, prompt, on_choice)
  if #items == 0 then
    return vim.notify(lang.e("no_candidates"), vim.log.levels.WARN)
  end

  local ok, fzf = pcall(require, "fzf-lua")
  if ok then
    fzf.fzf_exec(items, {
      prompt = prompt .. "> ",
      actions = {
        ["default"] = function(selected)
          if selected and selected[1] then
            on_choice(selected[1])
          end
        end,
      },
    })
    return
  end

  vim.ui.select(items, { prompt = prompt }, function(choice)
    if choice then
      on_choice(choice)
    end
  end)
end

-- Ask for a mailbox of the current account and hand back the name.
--
-- Switching to one and moving a message into one need the same list, so the
-- fetch and the picker live here and the caller decides what it is for.
-- The list is what is actually on disk, plus whatever views the account
-- defined by query. Asking the server would offer names with nothing behind
-- them, since only part of it was ever synced down.
function M.pick_mailbox_name(prompt, on_choice)
  require("leterejo.notmuch").mailboxes(state.account, function(ok, res)
    if not ok then
      return vim.notify(lang.t("prefix") .. res, vim.log.levels.ERROR)
    end

    select(res, prompt, on_choice)
  end)
end

function M.pick_mailbox()
  M.pick_mailbox_name(lang.t("pick_mailbox"), function(name)
    state.mailbox = name
    state.reset_list()
    require("leterejo.ui.envelopes").refresh()
  end)
end

function M.pick_account()
  cli.list_accounts(function(ok, res)
    if not ok then
      return vim.notify(lang.t("prefix") .. res, vim.log.levels.ERROR)
    end

    select(res, lang.t("pick_account"), function(name)
      state.account = name
      -- Mailbox names differ per account (Gmail renames its special
      -- folders with the display language), so fall back to the inbox.
      state.mailbox = "inbox"
      state.reset_list()
      require("leterejo.ui.envelopes").refresh()
    end)
  end)
end

return M
