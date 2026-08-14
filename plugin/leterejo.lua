-- Command registration. Keep loading cheap; real work starts on :Leterejo.
if vim.g.loaded_leterejo then
  return
end
vim.g.loaded_leterejo = true

vim.api.nvim_create_user_command("Leterejo", function()
  require("leterejo").open()
end, { desc = "Open the message list" })
