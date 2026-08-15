-- Preparing an account, as far as a program can.
--
-- Setting one up by hand is a sequence where every step reads configuration
-- another step was supposed to write, and where two of the mistakes are silent
-- for weeks (see `new.tags` and XAPIAN_CJK_NGRAM below). What is mechanical is
-- done here; what needs a browser and a password is printed for the person to
-- run.
--
-- Nothing is overwritten. A file that is already there is left alone and said
-- so, because the alternative is a tool that eats a working configuration on a
-- mistyped account name.
local config = require("leterejo.config")
local lang = require("leterejo.lang")

local M = {}

local function expand(path)
  return vim.fn.expand(path)
end

-- Where an account's things go when it has not said otherwise.
local function places(account)
  local a = (config.options.accounts or {})[account] or {}

  return {
    mail = expand(a.lieer_dir or ("~/Mail/" .. account .. "-lieer")),
    notmuch = expand(a.notmuch_config or ("~/.config/notmuch/" .. account)),
  }
end

-- The notmuch configuration for one account.
--
-- Written rather than documented because two of its lines are the difference
-- between a working setup and one that looks like it works:
--
--   database.path  the account's own mail. One index per account: tags are
--                  that account's Gmail labels, and two accounts sharing an
--                  index would merge a message addressed to both and offer
--                  each of them the other's labels on the next push
--   new.tags       empty. lieer applies it to every file it registers, on top
--                  of the labels Gmail gave, so the default of unread;inbox
--                  tags everything inbox and unread — and a local tag Gmail
--                  does not have goes up at the next push
local function notmuch_config(account, mail, address)
  return {
    "# notmuch — the index for the `" .. account .. "` account",
    "#",
    "# Written by :LeterejoSetup. One index per account: tags here are that",
    "# account's Gmail labels, and two accounts sharing an index would merge a",
    "# message addressed to both into one entry carrying the union of their",
    "# labels — which the next push would offer to each of them.",
    "#",
    "# Run notmuch and gmi for this account through the wrapper, which sets",
    "# both of the things that fail silently when forgotten:",
    "#",
    "#   leterejo-env " .. account .. " notmuch search ...",
    "#   leterejo-env " .. account .. " gmi sync",
    "",
    "[database]",
    "path=" .. mail,
    "",
    "[user]",
    "primary_email=" .. (address or ""),
    "",
    "[new]",
    "ignore=.notmuch;.lock;.gmailieer.json;.state.gmailieer.json;.credentials.gmailieer.json",
    "# Empty on purpose. lieer applies this to every file it registers, on top",
    "# of the labels Gmail gave: the default of unread;inbox would tag every",
    "# message inbox and unread, and a local tag Gmail does not have is offered",
    "# to Gmail on the next push — so archiving one old message would put it",
    "# back in the inbox.",
    "tags=",
    "",
    "[search]",
    "exclude_tags=deleted;spam;",
    "",
    "[maildir]",
    "synchronize_flags=true",
  }
end

-- A wrapper for running notmuch and gmi by hand against one account.
local function wrapper_script()
  return {
    "#!/bin/sh",
    "# Run something against one account's mail, with the environment it needs.",
    "#",
    "#   leterejo-env work notmuch search ...",
    "#   leterejo-env work gmi sync",
    "#",
    "# Two things are easy to forget by hand and silent when forgotten:",
    "#",
    "#   NOTMUCH_CONFIG      each account has its own index. Without this,",
    "#                       notmuch answers about whichever account the",
    "#                       default names, and gmi registers what it fetched",
    "#                       in that one.",
    "#   XAPIAN_CJK_NGRAM=1  without it a run of CJK is indexed as one term, so",
    "#                       a word inside a longer one cannot be found — and",
    "#                       two-character words still work, which hides it.",
    "#",
    "# Runs in the account's mail directory, which is where gmi expects to be.",
    "set -e",
    "",
    "if [ $# -lt 2 ]; then",
    '    echo "usage: leterejo-env <account> <command> [args...]" >&2',
    "    exit 2",
    "fi",
    "",
    "account=$1",
    "shift",
    "",
    'NOTMUCH_CONFIG="$HOME/.config/notmuch/$account"',
    'if [ ! -f "$NOTMUCH_CONFIG" ]; then',
    '    echo "leterejo-env: no notmuch config for \'$account\' ($NOTMUCH_CONFIG)" >&2',
    "    exit 1",
    "fi",
    "",
    "export NOTMUCH_CONFIG",
    "export XAPIAN_CJK_NGRAM=1",
    "",
    'path=$(notmuch config get database.path)',
    "",
    "# The directory has to exist before anything runs in it: gmi init reads the",
    "# notmuch configuration to find out where the repository belongs, and",
    "# without this it would answer about whichever account the default names.",
    'if [ ! -d "$path" ]; then',
    '    echo "leterejo-env: $account: no mail directory at $path" >&2',
    '    echo "  mkdir -p $path   # then: leterejo-env $account gmi init <address>" >&2',
    "    exit 1",
    "fi",
    "",
    'cd "$path"',
    'exec "$@"',
  }
end

local function write(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  return pcall(vim.fn.writefile, lines, path)
end

-- Build the empty index, which lieer needs before it will look at anything.
--
-- `gmi auth` opens the database to work out where the repository sits, so
-- without this it stops with "Cannot open database" — which says nothing about
-- what is actually missing.
local function build_index(account, notmuch_path, on_done)
  local exe = (config.options.notmuch or {}).executable or "notmuch"

  vim.system({ exe, "new" }, {
    text = true,
    env = { NOTMUCH_CONFIG = notmuch_path, XAPIAN_CJK_NGRAM = "1" },
  }, function(res)
    vim.schedule(function()
      on_done(res.code == 0, (res.stderr or "") .. (res.stdout or ""))
    end)
  end)
end

-- Prepare what can be prepared, and say what is left.
function M.account(account)
  account = vim.trim(tostring(account or ""))
  if account == "" then
    return vim.notify(lang.e("setup_needs_name"), vim.log.levels.ERROR)
  end

  local where = places(account)
  local a = (config.options.accounts or {})[account] or {}
  local report = {}

  -- The mail directory.
  if vim.fn.isdirectory(where.mail) == 1 then
    table.insert(report, lang.t("setup_kept", where.mail))
  else
    vim.fn.mkdir(where.mail, "p")
    table.insert(report, lang.t("setup_made", where.mail))
  end

  -- The index configuration.
  if vim.fn.filereadable(where.notmuch) == 1 then
    table.insert(report, lang.t("setup_kept", where.notmuch))
  elseif write(where.notmuch, notmuch_config(account, where.mail, a.email)) then
    table.insert(report, lang.t("setup_made", where.notmuch))
  else
    return vim.notify(lang.e("setup_failed", where.notmuch), vim.log.levels.ERROR)
  end

  -- The wrapper, once, for whoever runs notmuch or gmi by hand.
  local wrapper = expand("~/.local/bin/leterejo-env")
  if vim.fn.filereadable(wrapper) == 1 then
    table.insert(report, lang.t("setup_kept", wrapper))
  elseif write(wrapper, wrapper_script()) then
    vim.loop.fs_chmod(wrapper, 493) -- 0755
    table.insert(report, lang.t("setup_made", wrapper))
  end

  build_index(account, where.notmuch, function(ok, out)
    if ok then
      table.insert(report, lang.t("setup_indexed", where.mail))
    else
      table.insert(report, lang.t("setup_index_failed", vim.trim(tostring(out))))
    end

    -- What is left needs a browser and a password, so it is printed rather
    -- than run. The order matters: each of these reads what the one before it
    -- wrote, and run bare they read another account's configuration instead.
    local address = a.email or "you@example.com"
    vim.list_extend(report, {
      "",
      lang.t("setup_now_run"),
      "",
      "  leterejo-env " .. account .. " gmi init " .. address,
      "  leterejo-env " .. account .. " gmi auth",
      "  leterejo-env " .. account .. " gmi set --timeout 60",
      "  leterejo-env " .. account .. " gmi set --no-remove-local-messages",
      "  leterejo-env " .. account .. " gmi pull",
      "",
      lang.t("setup_then_configure"),
      "",
      '  accounts = {',
      '    ' .. account .. ' = {',
      '      email = "' .. address .. '",',
      '      lieer_dir = "' .. where.mail .. '",',
      '      notmuch_config = "' .. where.notmuch .. '",',
      "    },",
      "  },",
      "",
      lang.t("setup_then_check"),
    })

    vim.notify(table.concat(report, "\n"), vim.log.levels.INFO)
  end)
end

return M
