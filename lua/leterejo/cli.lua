-- The himalaya CLI call layer.
--
-- Sending, and the account list that goes with it. Reading is answered by the
-- notmuch index and changing a message is a change of tag, so this is no longer
-- on the path between a keystroke and the screen.
--
-- himalaya v2 opens a fresh TCP+TLS+SASL session per command, so a send costs
-- hundreds of milliseconds to several seconds. It runs asynchronously like
-- everything else.
local config = require("leterejo.config")
local lang = require("leterejo.lang")

local M = {}

-- Detect a cold passphrase cache.
--
-- Three shapes arrive here, because there are three ways the same thing goes
-- wrong. himalaya says "Secret command error" when the command it reads the
-- password from failed at all. gpg says "decryption failed" alongside "Timeout"
-- when pinentry drew a prompt nobody could answer — which is the state this
-- whole path exists to get out of. And gpg told it may not prompt at all
-- (`--pinentry-mode cancel`, which is how the prompt is kept off the terminal
-- Neovim is holding) fails at once with "Operation cancelled" or "No pinentry",
-- and then "No secret key".
--
-- That last one is also what a genuinely absent key says, so a real
-- misconfiguration is reported as a locked store. The unlock offered next then
-- fails and says so: a longer way round to the truth, but not a wrong one.
local PASSPHRASE_MARKERS = {
  "Secret command error",
  "Operation cancelled",
  "Operation canceled",
  "No pinentry",
  "No secret key",
}

local function is_passphrase_error(text)
  if not text then
    return false
  end

  for _, marker in ipairs(PASSPHRASE_MARKERS) do
    if text:find(marker, 1, true) then
      return true
    end
  end

  return text:find("decryption failed", 1, true) ~= nil and text:find("Timeout", 1, true) ~= nil
end

-- Reduce failure output to one line worth showing the user.
local function friendly_error(stderr, stdout)
  local text = (stderr or "") .. "\n" .. (stdout or "")

  if is_passphrase_error(text) then
    return lang.t("err_passphrase")
  end

  -- Name lookup failed. A dropped connection produces this too, so say so
  -- rather than let it read as a misconfiguration.
  if text:match("failed to lookup address information") then
    local host = text:match("connect%s+([%w%.%-]+:%d+)") or ""
    return lang.t("err_dns", host ~= "" and host or "the server")
  end

  -- With --json in play, failures can come back as JSON. Raw JSON is
  -- unreadable, so pull the message out.
  local decoded_ok, decoded = pcall(vim.json.decode, vim.trim(stdout or ""))
  if decoded_ok and type(decoded) == "table" and decoded.error then
    local msg = tostring(decoded.error)
    local sources = decoded.sources
    if type(sources) == "table" and #sources > 0 then
      msg = msg .. " — " .. table.concat(sources, " / ")
    end
    return msg
  end

  -- himalaya errors arrive as "Error: ..."; take the first line only.
  local first = text:match("Error:%s*([^\n]+)")
  if first then
    return first
  end

  first = text:match("([^\n]+)")
  return first or lang.t("err_generic")
end

-- Run himalaya asynchronously.
--   args    : arguments to pass (without the executable itself)
--   account : target account; nil uses himalaya's default
--   on_done : function(ok, result) — on failure, result is the message
local function run(args, account, on_done, opts)
  local cmd = { config.options.executable }

  -- Values are joined with "=", here and in every caller: himalaya's parser
  -- rejects a value beginning with a hyphen when it is a separate argument.
  if account then
    table.insert(cmd, "--account=" .. account)
  end

  -- Logs on stderr would confuse failure detection, so silence them.
  table.insert(cmd, "--log-level")
  table.insert(cmd, "off")

  -- --json must precede the subcommand. Commands taking variadic positional
  -- arguments would otherwise swallow it as part of their own arguments.
  if opts and opts.json then
    table.insert(cmd, "--json")
  end

  vim.list_extend(cmd, args)

  vim.system(cmd, {
    text = true,
    timeout = config.options.timeout,
    stdin = opts and opts.stdin or nil,
  }, function(res)
    -- vim.system completes in a fast-event context where touching the
    -- screen or most APIs crashes; hop back to the main loop first.
    vim.schedule(function()
      if res.code == 0 then
        return on_done(true, res.stdout or "")
      end

      -- A locked password store is worth telling apart from every other
      -- failure: it is the one the user can do something about, and there is
      -- something this plugin can do about it too (see M.unlock).
      local text = (res.stderr or "") .. "\n" .. (res.stdout or "")
      local kind = is_passphrase_error(text) and "passphrase" or nil
      on_done(false, friendly_error(res.stderr, res.stdout), kind)
    end)
  end)
end

-- Fetch JSON output and decode it.
function M.json(args, account, on_done)
  run(args, account, function(ok, out, kind)
    if not ok then
      return on_done(false, out, kind)
    end

    local decoded_ok, decoded = pcall(vim.json.decode, out)
    if not decoded_ok then
      return on_done(false, lang.t("err_json", tostring(decoded)))
    end

    on_done(true, decoded)
  end, { json = true })
end

-- Fetch pre-rendered text as is.
--
--   opts.stdin : text to feed the command, for `message send`, which takes a
--                whole RFC 5322 message that way
function M.text(args, account, on_done, opts)
  run(args, account, on_done, opts)
end

-- Fetch the configured accounts.
--
-- himalaya's own configuration is still where accounts are declared, since it
-- is what sends. The index knows nothing about them.
function M.list_accounts(on_done)
  M.json({ "account", "list" }, nil, function(ok, res)
    if not ok then
      return on_done(false, res)
    end

    local names = {}
    for _, a in ipairs(res.accounts or {}) do
      table.insert(names, a.name or a.id)
    end
    on_done(true, names)
  end)
end

-- Unlocking the password store ------------------------------------------------
--
-- himalaya reads the SMTP password from `pass`, which asks gpg-agent, which
-- runs pinentry when its cache is cold. pinentry-curses draws on GPG_TTY — the
-- terminal Neovim itself is holding — so the prompt lands on top of the editor
-- and the keys typed at it go to the editor instead. Nothing can be entered,
-- and the screen is left in a mess.
--
-- The way out is to give pinentry a terminal of its own. A terminal buffer has
-- one, and `GPG_TTY=$(tty)` inside it points pinentry at that rather than at
-- the outer screen. The prompt then behaves like any other program in a split.
--
-- The output goes to /dev/null on purpose: what the command prints is the
-- password.
function M.unlock(account, on_done)
  local a = (config.options.accounts or {})[account] or {}
  local cmd = a.unlock_command or config.options.unlock_command

  if type(cmd) ~= "table" or #cmd == 0 then
    return on_done(false, lang.t("err_no_unlock_command", tostring(account or "")))
  end

  local quoted = {}
  for _, part in ipairs(cmd) do
    table.insert(quoted, vim.fn.shellescape(part))
  end

  local script = "export GPG_TTY=$(tty); " .. table.concat(quoted, " ") .. " >/dev/null"

  local from = vim.api.nvim_get_current_win()
  vim.cmd("botright split")
  vim.cmd("enew")

  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_height(win, 12)

  vim.fn.jobstart({ "sh", "-c", script }, {
    term = true,
    on_exit = function(_, code)
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(win) and #vim.api.nvim_list_wins() > 1 then
          vim.api.nvim_win_close(win, true)
        end
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
        if vim.api.nvim_win_is_valid(from) then
          vim.api.nvim_set_current_win(from)
        end
        on_done(code == 0, code == 0 and lang.t("unlocked") or lang.t("unlock_failed"))
      end)
    end,
  })

  vim.cmd("startinsert")
end

return M
