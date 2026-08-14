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
-- himalaya reports "Secret command error" when the pass call fails, followed by
-- "Timeout" once pinentry waits without an answer. Nothing resolves this until
-- the user types the passphrase in a terminal, so it needs its own message.
local function is_passphrase_error(text)
  if not text then
    return false
  end
  return text:match("Secret command error") ~= nil
    or (text:match("decryption failed") ~= nil and text:match("Timeout") ~= nil)
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

  if account then
    table.insert(cmd, "-a")
    table.insert(cmd, account)
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

  vim.system(cmd, { text = true, timeout = config.options.timeout }, function(res)
    -- vim.system completes in a fast-event context where touching the
    -- screen or most APIs crashes; hop back to the main loop first.
    vim.schedule(function()
      if res.code == 0 then
        on_done(true, res.stdout or "")
      else
        on_done(false, friendly_error(res.stderr, res.stdout))
      end
    end)
  end)
end

-- Fetch JSON output and decode it.
function M.json(args, account, on_done)
  run(args, account, function(ok, out)
    if not ok then
      return on_done(false, out)
    end

    local decoded_ok, decoded = pcall(vim.json.decode, out)
    if not decoded_ok then
      return on_done(false, lang.t("err_json", tostring(decoded)))
    end

    on_done(true, decoded)
  end, { json = true })
end

-- Fetch pre-rendered text as is.
function M.text(args, account, on_done)
  run(args, account, on_done)
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

return M
