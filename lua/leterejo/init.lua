-- leterejo.nvim — a Neovim mail client over a local notmuch index.
--
-- Reading is answered by notmuch, from mail a sync tool put on disk. Sending is
-- himalaya's job, and so is MIME and character encoding — the parts most likely
-- to break on non-ASCII mail are not reimplemented here. This side owns the
-- screen and the keys.
local config = require("leterejo.config")
local state = require("leterejo.state")

local M = {}

function M.setup(opts)
  config.setup(opts)
  state.account = config.options.account

  -- Fetching on a timer, when one is asked for. Started here rather than when
  -- the list is opened: mail should arrive whether or not it is being looked
  -- at, which is the whole point of it running on its own.
  local lieer = require("leterejo.lieer")
  lieer.start()

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("LeterejoSync", { clear = true }),
    callback = function()
      lieer.stop()
    end,
  })
end

-- Open the list.
--
-- Nothing is prepared first. The list used to wait on a himalaya call to get
-- the passphrase unlocked before pinentry could seize the terminal mid-fetch;
-- now that reading never leaves the machine, the only thing that reaches for a
-- password is sending, which the user asked for and can answer a prompt during.
function M.open()
  require("leterejo.ui.envelopes").open()
end

-- Open the password store, so that sending later does not stop to ask.
--
-- Worth having as its own command: the ask arrives at the worst moment
-- otherwise, in the middle of sending, from a program that cannot draw where
-- it wants to.
function M.unlock(account)
  local lang = require("leterejo.lang")

  require("leterejo.cli").unlock(account or state.account, function(ok, message)
    vim.notify(lang.t("prefix") .. message, ok and vim.log.levels.INFO or vim.log.levels.WARN)
  end)
end

return M
