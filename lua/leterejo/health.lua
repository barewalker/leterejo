-- `:checkhealth leterejo`
--
-- This plugin is a front end to programs it does not ship. notmuch is what it
-- reads from and cannot work without; the rest depends on how things are set up
-- here — w3m only matters once mail arrives as HTML. Rather than list
-- requirements in a README and hope, the check reports what this configuration
-- actually needs and what is actually there.
--
-- Nothing here touches an account. Asking himalaya to list mailboxes would make
-- it read a password out of pass, and a cold gpg-agent would seize the terminal
-- with a pinentry prompt in the middle of a health check.
local M = {}

local function run(cmd)
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true }):wait()
  end)
  if not ok or not res then
    return nil
  end
  return res
end

local function first_line(s)
  return vim.trim((tostring(s or ""):match("([^\n]*)")))
end

-- Neovim itself ---------------------------------------------------------------

local function check_neovim()
  vim.health.start("leterejo: Neovim")

  if vim.fn.has("nvim-0.10") == 1 then
    local v = vim.version()
    vim.health.ok(("Neovim %d.%d.%d"):format(v.major, v.minor, v.patch))
  else
    vim.health.error("Neovim 0.10 or newer is required", {
      "vim.system() and vim.fs.dir()'s skip option are both 0.10.",
    })
  end
end

-- himalaya --------------------------------------------------------------------

local function check_himalaya(config)
  vim.health.start("leterejo: himalaya (sending)")

  local exe = config.options.executable or "himalaya"
  if vim.fn.executable(exe) ~= 1 then
    return vim.health.error("`" .. exe .. "` not found on PATH", {
      "himalaya sends mail. Reading does not go through it.",
      "https://github.com/pimalaya/himalaya",
      "Set `executable` if it is installed under another name or path.",
    })
  end

  local res = run({ exe, "--version" })
  local version = res and first_line(res.stdout) or ""

  if version:match("%f[%d]2%.") then
    vim.health.ok(version)
  elseif version ~= "" then
    vim.health.warn(version .. " — this plugin targets v2", {
      "v1 spells its commands differently; listing and reading will fail.",
    })
  else
    vim.health.warn("`" .. exe .. "` runs but did not report a version")
  end
end

-- notmuch ---------------------------------------------------------------------

local function check_notmuch(config)
  vim.health.start("leterejo: notmuch (required)")

  local opts = config.options.notmuch or {}
  local exe = opts.executable or "notmuch"

  if vim.fn.executable(exe) ~= 1 then
    return vim.health.error("`" .. exe .. "` not found on PATH", {
      "Everything this plugin shows is read from the notmuch index.",
      "Nothing will be listed until it is installed and `notmuch new` has run.",
      "Set `notmuch.executable` if it is installed under another name or path.",
    })
  end

  local res = run({ exe, "--version" })
  vim.health.ok(res and first_line(res.stdout) or exe)

  if opts.config then
    local path = vim.fn.expand(opts.config)
    if vim.fn.filereadable(path) == 1 then
      vim.health.ok("config: " .. path)
    else
      vim.health.error("notmuch.config points at a file that is not readable: " .. path)
    end
  end

  -- Where the mail is, and whether there is any. A database that answers zero
  -- looks exactly like a broken query from inside the plugin.
  local env = { XAPIAN_CJK_NGRAM = "1" }
  if opts.config then
    env.NOTMUCH_CONFIG = vim.fn.expand(opts.config)
  end

  local ok, root = pcall(function()
    return vim.system({ exe, "config", "get", "database.mail_root" }, { text = true, env = env })
      :wait()
  end)
  if ok and root and root.code == 0 and vim.trim(root.stdout) ~= "" then
    vim.health.ok("mail_root: " .. vim.trim(root.stdout))
  else
    vim.health.warn("Could not read database.mail_root", {
      "notmuch may not be configured yet. Run `notmuch new` once.",
    })
  end

  local counted = pcall(function()
    local c = vim.system({ exe, "count", "*" }, { text = true, env = env }):wait()
    local n = tonumber(vim.trim(c.stdout or ""))
    if n and n > 0 then
      vim.health.ok(("%d messages indexed"):format(n))
    else
      vim.health.warn("The index holds no messages", {
        "Nothing will be listed. Sync some mail and run `notmuch new`.",
      })
    end
  end)
  if not counted then
    vim.health.warn("Could not count the indexed messages")
  end

  -- The one failure that gives no sign of itself.
  vim.health.info("XAPIAN_CJK_NGRAM=1 is passed on every call this plugin makes.")
  vim.health.info(
    "It is also needed when the index is BUILT. Without it a run of CJK is one "
      .. "term, so a word inside a longer one cannot be found — and two-character "
      .. "words still work, which hides it. Put `notmuch new` behind a wrapper "
      .. "that sets the variable."
  )
end

-- lieer -----------------------------------------------------------------------
--
-- What carries a change of tag up to Gmail. Nothing is guessed about where its
-- repository is, so a plugin that reads perfectly can still silently fail to
-- write, and this is the section that says why.

local function lieer_dirs(config)
  local found = {}

  local dir = (config.options.lieer or {}).dir
  if dir then
    table.insert(found, { name = "lieer.dir", path = vim.fn.expand(dir) })
  end

  local names = vim.tbl_keys(config.options.accounts or {})
  table.sort(names)
  for _, name in ipairs(names) do
    local a = config.options.accounts[name]
    if a.lieer_dir then
      table.insert(found, { name = name, path = vim.fn.expand(a.lieer_dir) })
    end
  end

  return found
end

-- What lieer was told to do, from the repository's own configuration.
--
-- Two of its settings are worth reporting. The default timeout is ten minutes,
-- and a request that stalls simply sits there for all of it, saying nothing.
-- And removing local messages is on by default, which is the setting that
-- decides whether a sync can delete mail from this machine.
local function check_repository(entry)
  local file = entry.path .. "/.gmailieer.json"
  if vim.fn.filereadable(file) ~= 1 then
    return vim.health.error(entry.name .. ": no .gmailieer.json in " .. entry.path, {
      "This is not a lieer repository, so nothing can be pushed from it.",
      "Point it at the directory holding .gmailieer.json.",
    })
  end

  local ok, decoded = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
  end)
  if not ok or type(decoded) ~= "table" then
    return vim.health.warn(entry.name .. ": could not read " .. file)
  end

  vim.health.ok(entry.name .. ": " .. entry.path .. "  [" .. tostring(decoded.account) .. "]")

  local timeout = tonumber(decoded.timeout) or 0
  if timeout <= 0 or timeout >= 600 then
    vim.health.warn(("%s: lieer's own timeout is %s seconds"):format(entry.name, tostring(decoded.timeout)), {
      "A stalled request hangs for that long without saying anything.",
      "`gmi set --timeout 60` in the repository.",
    })
  end

  if decoded.remove_local_messages == true then
    vim.health.info(entry.name .. ": a sync may delete mail from this machine "
      .. "(remove_local_messages is on)")
  end
end

local function check_lieer(config)
  vim.health.start("leterejo: lieer (pushing changes back)")

  local opts = config.options.lieer or {}
  local exe = opts.executable or "gmi"

  if opts.sync_on_write == false then
    vim.health.info("sync_on_write is off: changes stay in the index until something else syncs")
  end

  if vim.fn.executable(exe) ~= 1 then
    return vim.health.error("`" .. exe .. "` not found on PATH", {
      "Marking read, archiving and the rest change a notmuch tag, and this",
      "is what carries that change to Gmail. Without it they stay here.",
      "https://github.com/gauteh/lieer",
    })
  end
  vim.health.ok(exe .. " found")

  local dirs = lieer_dirs(config)
  if #dirs == 0 then
    return vim.health.warn("No lieer repository configured", {
      "Changes will be made in the index and go no further.",
      'Set lieer = { dir = "~/Mail/<repo>" }, or `lieer_dir` per account.',
      "Nothing is guessed: the index can span several repositories, and",
      "the wrong one would push one account's changes at another.",
    })
  end

  for _, entry in ipairs(dirs) do
    check_repository(entry)
  end
end

-- Optional programs -------------------------------------------------------------

local function check_renderer(config)
  vim.health.start("leterejo: HTML rendering")

  local renderer = (config.options.notmuch or {}).html_renderer
  if not renderer or not renderer[1] then
    return vim.health.warn("No html_renderer set", {
      "Mail with no plain-text part will be shown as raw markup.",
      'The default is { "w3m", "-dump", "-T", "text/html", "-cols", "100" }.',
    })
  end

  if vim.fn.executable(renderer[1]) == 1 then
    vim.health.ok(renderer[1] .. " — mail with only HTML will be rendered")
  else
    vim.health.warn("`" .. renderer[1] .. "` not found", {
      "Mail with no plain-text part will be shown as raw markup.",
      "Over half of the mail measured here was of that kind.",
    })
  end
end

-- Does the terminal say how big a cell is, in pixels?
--
-- This is the one that costs an evening. Everything reports success — the
-- terminal is recognised, the image converts, the escape sequence is written,
-- the placement exists — and nothing appears, because the size the image should
-- be drawn at came out zero.
--
-- The pixel dimensions come from ioctl(TIOCGWINSZ), and a multiplexer usually
-- leaves them at zero: it deals in cells and has no reason to divide its own
-- pixels between panes. The caller only checks rows and columns, so zero passes
-- straight through into a division and the image is drawn at nothing by nothing.
local function check_pixel_size()
  local ok, ffi = pcall(require, "ffi")
  if not ok then
    return
  end

  local sized = pcall(function()
    ffi.cdef([[
      typedef struct { unsigned short row, col, xpixel, ypixel; } leterejo_winsize;
      int ioctl(int, int, ...);
    ]])
  end)
  if not sized and not pcall(ffi.typeof, "leterejo_winsize") then
    return -- another plugin already declared it under its own name; leave it
  end

  local TIOCGWINSZ = vim.fn.has("mac") == 1 or vim.fn.has("bsd") == 1 and 0x40087468 or 0x5413

  local sz = ffi.new("leterejo_winsize")
  if ffi.C.ioctl(1, TIOCGWINSZ, sz) ~= 0 then
    return vim.health.info("Could not ask the terminal for its size")
  end

  if sz.xpixel > 0 and sz.ypixel > 0 then
    return vim.health.ok(
      ("One cell is %.0f x %.0f pixels"):format(sz.xpixel / sz.col, sz.ypixel / sz.row)
    )
  end

  vim.health.error("The terminal reports no pixel size, so images will not appear", {
    ("rows=%d cols=%d xpixel=%d ypixel=%d"):format(sz.row, sz.col, sz.xpixel, sz.ypixel),
    "The size an image is drawn at is worked out from these, so a zero here",
    "means a zero there — silently. Everything else will look fine.",
    "A multiplexer between Neovim and the terminal is the usual cause: it",
    "measures in cells and passes no pixels down to the pane.",
    "Fix it in the multiplexer, by apportioning the outer terminal's pixel",
    "size across the panes when it sets each pty's window size.",
  })
end

-- Images the message carries, drawn by the terminal.
--
-- Worth its own section because there are four ways for it to be off and none
-- of them says anything: the setting, snacks missing, the terminal not
-- detected, and the terminal genuinely unable. Only the third is usually the
-- real one, and it is the one nothing else would tell you about.
local function check_images(config)
  vim.health.start("leterejo: inline images")

  if not config.options.inline_images then
    return vim.health.ok("Turned off (inline_images = false)")
  end

  local ok = pcall(require, "snacks")
  if not ok or not Snacks or not Snacks.image then
    return vim.health.warn("snacks.nvim not found; images will not be drawn", {
      "Attachments are still listed and can still be saved.",
    })
  end

  local env = ""
  local detected = pcall(function()
    env = tostring((Snacks.image.terminal.env() or {}).name or "")
  end)

  if Snacks.image.supports_terminal() then
    vim.health.ok("Will draw here" .. (env ~= "" and (" (" .. env .. ")") or ""))
    return check_pixel_size()
  end

  vim.health.warn("The terminal was not recognised as able to draw images", {
    detected and ("snacks detected: " .. (env ~= "" and env or "nothing")) or nil,
    "TERM=" .. tostring(vim.env.TERM),
    "A multiplexer between Neovim and the terminal often rewrites TERM, which",
    "is what detection reads. If yours does carry the kitty graphics protocol",
    "through, tell snacks so with SNACKS_KITTY=1 in the environment, or",
    "`opts.image.force = true` in its setup.",
  })
end

local function check_handlers(config)
  vim.health.start("leterejo: attachment handlers")

  local seen, missing = {}, {}
  local modes = {}

  for _, handlers in pairs(config.options.attachment_handlers or {}) do
    for _, h in ipairs(handlers) do
      if h.mode then
        modes[h.mode] = true
      end
      local cmd = h.cmd and h.cmd[1]
      if cmd and not seen[cmd] then
        seen[cmd] = true
        if vim.fn.executable(cmd) ~= 1 then
          table.insert(missing, cmd)
        end
      end
    end
  end

  for _, mode in ipairs({ "herdr", "tmux" }) do
    if modes[mode] and vim.fn.executable(mode) ~= 1 then
      table.insert(missing, mode .. " (a handler asks for a " .. mode .. " pane)")
    end
  end

  if #missing == 0 then
    vim.health.ok("Every configured handler can be run")
  else
    vim.health.warn("Not found: " .. table.concat(missing, ", "), {
      "Those attachments will be saved instead of opened.",
    })
  end
end

-- The configuration itself --------------------------------------------------------

local function check_config(config)
  vim.health.start("leterejo: configuration")

  local accounts = config.options.accounts or {}
  if vim.tbl_isempty(accounts) then
    vim.health.warn("No accounts configured", {
      "Reading works without this, but sending needs an address:",
      "himalaya v2 does not fill From by itself.",
      'accounts = { work = { email = "you@work.example" } }',
    })
  else
    local names = vim.tbl_keys(accounts)
    table.sort(names)
    for _, name in ipairs(names) do
      local a = accounts[name]
      local notes = {}
      if a.readonly then
        table.insert(notes, "read-only")
      end
      local suffix = #notes > 0 and ("  [" .. table.concat(notes, ", ") .. "]") or ""

      if a.email and a.email ~= "" then
        vim.health.ok(name .. ": " .. a.email .. suffix)
      elseif a.readonly then
        vim.health.ok(name .. ": no address, but read-only" .. suffix)
      else
        vim.health.warn(name .. ": no `email` set" .. suffix, {
          "Sending from this account will stop: himalaya v2 needs --from.",
        })
      end
    end
  end

  local dir = config.options.download_dir
  if dir then
    local path = vim.fn.expand(dir)
    if vim.fn.isdirectory(path) == 1 and vim.fn.filewritable(path) == 2 then
      vim.health.ok("download_dir: " .. path)
    else
      vim.health.error("download_dir is not a writable directory: " .. path)
    end
  end
end

function M.check()
  local config = require("leterejo.config")

  check_neovim()
  check_himalaya(config)
  check_notmuch(config)
  check_lieer(config)
  check_renderer(config)
  check_images(config)
  check_handlers(config)
  check_config(config)
end

return M
