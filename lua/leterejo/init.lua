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

return M
