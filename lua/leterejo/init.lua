-- leterejo.nvim — a Neovim front-end for himalaya CLI v2.
--
-- himalaya handles everything about the mail server (IMAP/SMTP, MIME,
-- character encodings); this side only owns the screen and the keys.
local config = require("leterejo.config")
local state = require("leterejo.state")

local M = {}

function M.setup(opts)
  config.setup(opts)
  state.account = config.options.account

  local cache = require("leterejo.cache")

  -- Load the list captured in earlier sessions so a fresh Neovim shows it
  -- without waiting. The contents catch up in the background.
  if config.options.persist_cache then
    cache.load()

    -- Flush any pending write on exit.
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = vim.api.nvim_create_augroup("LeterejoCacheFlush", { clear = true }),
      callback = function()
        cache.flush()
      end,
    })
  end
end

-- Open the list, unlocking the passphrase first on the very first call.
--
-- himalaya invokes pass on every operation. Fetching the list with a cold
-- cache lets pinentry seize the terminal, leaving the screen garbled and
-- frozen. A cheap query up front gets the unlock out of the way first.
function M.open()
  if state.warmed_up then
    return require("leterejo.ui.envelopes").open()
  end

  local cli = require("leterejo.cli")

  vim.notify(require("leterejo.lang").t("preparing"), vim.log.levels.INFO)

  cli.warm_up(state.account, function(ok, res)
    if not ok then
      return vim.notify(require("leterejo.lang").t("prefix") .. res, vim.log.levels.ERROR)
    end

    state.warmed_up = true
    require("leterejo.ui.envelopes").open()
  end)
end

return M
