-- Command registration. Keep loading cheap; real work starts on :Leterejo.
if vim.g.loaded_leterejo then
  return
end
vim.g.loaded_leterejo = true

vim.api.nvim_create_user_command("Leterejo", function()
  require("leterejo").open()
end, { desc = "Open the message list" })

-- Preparing an account: the directory, the index and its configuration, and
-- the wrapper for running notmuch and gmi by hand. What needs a browser and a
-- password is printed rather than run.
vim.api.nvim_create_user_command("LeterejoSetup", function(opts)
  require("leterejo.setup").account(opts.args)
end, { nargs = 1, desc = "Prepare an account's mail directory and index" })

-- Fetching mail without opening the list first.
vim.api.nvim_create_user_command("LeterejoSync", function()
  require("leterejo.ui.envelopes").sync()
end, { desc = "Fetch mail and reload the list" })

-- Opening the password store before it is needed, rather than in the middle of
-- sending. Takes an account name; without one, the account being read.
vim.api.nvim_create_user_command("LeterejoUnlock", function(opts)
  require("leterejo").unlock(opts.args ~= "" and opts.args or nil)
end, { nargs = "?", desc = "Unlock the password store" })
