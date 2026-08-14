-- Saving attachments and opening what was saved.
--
-- How to open is the user's choice: handlers are listed per MIME type, and
-- more than one prompts for a pick. A single handler runs directly.
local cli = require("leterejo.cli")
local config = require("leterejo.config")
local lang = require("leterejo.lang")
local util = require("leterejo.ui.util")

local M = {}

-- Turn an argument list into one shell-safe line.
local function shell_line(cmd)
  local escaped = {}
  for _, c in ipairs(cmd) do
    table.insert(escaped, vim.fn.shellescape(c))
  end
  return table.concat(escaped, " ")
end

-- Launch strategies. Each takes (cmd, handler, path) and returns whether it
-- succeeded, plus a reason when it did not.
local runners = {}

-- Launch nothing; the save is the whole job.
runners.save = function()
  return true
end

-- Run in a new herdr pane.
--
-- herdr separates creating a pane from running something in it. The new pane's
-- id comes from the split reply (JSON) and is handed to run.
runners.herdr = function(cmd, handler)
  if vim.fn.executable("herdr") == 0 then
    return false, lang.t("herdr_missing")
  end

  local split = {
    "herdr",
    "pane",
    "split",
    "--direction",
    handler.direction or "right",
    "--ratio",
    tostring(handler.ratio or 0.5),
  }
  table.insert(split, handler.focus and "--focus" or "--no-focus")

  local out = vim.fn.system(split)
  if vim.v.shell_error ~= 0 then
    return false, lang.t("herdr_no_pane", vim.trim(out))
  end

  local ok, res = pcall(vim.json.decode, out)
  if not ok then
    return false, lang.t("herdr_no_reply")
  end

  local pane = res and res.result and res.result.pane
  local pane_id = pane and pane.pane_id
  if not pane_id then
    return false, lang.t("herdr_no_id")
  end

  -- The shell is not up yet right after the split. Sending immediately
  -- leaves the text sitting at the prompt, never executed. Wait a moment.
  vim.defer_fn(function()
    local run_out = vim.fn.system({ "herdr", "pane", "run", pane_id, shell_line(cmd) })
    if vim.v.shell_error ~= 0 then
      vim.notify(
        lang.e("herdr_run_failed", vim.trim(run_out)),
        vim.log.levels.ERROR
      )
    end
  end, handler.startup_delay or 400)

  return true
end

-- Run in a new tmux pane.
runners.tmux = function(cmd, handler)
  if vim.env.TMUX == nil then
    return false, lang.t("tmux_outside")
  end

  local split = { "tmux", "split-window" }
  table.insert(split, (handler.direction or "right") == "down" and "-v" or "-h")
  if handler.ratio then
    vim.list_extend(split, { "-p", tostring(math.floor(handler.ratio * 100)) })
  end
  if not handler.focus then
    table.insert(split, "-d") -- do not follow focus
  end
  table.insert(split, shell_line(cmd))

  local out = vim.fn.system(split)
  if vim.v.shell_error ~= 0 then
    return false, lang.t("herdr_no_pane", vim.trim(out))
  end
  return true
end

-- Run in a terminal window inside Neovim.
-- Tools that paint the terminal directly (some image viewers among them) will not
-- display correctly here.
runners.terminal = function(cmd, handler)
  vim.cmd(handler.split == "vertical" and "vsplit" or "split")
  vim.cmd("enew")
  vim.fn.jobstart(cmd, { term = true })
  vim.cmd("startinsert")
  return true
end

-- Hand the screen to the program and wait for it to exit.
--
-- Note: tools using kitty's graphics protocol will not display here either.
-- Neovim owns the alternate screen and redraws over whatever they emit.
runners.fullscreen = function(cmd)
  vim.notify(lang.t("opening"), vim.log.levels.INFO)
  local ok, err = pcall(vim.cmd, "!" .. shell_line(cmd))
  vim.cmd("redraw!")
  if not ok then
    return false, tostring(err)
  end
  return true
end

-- Launch in the background and carry on.
runners.detach = function(cmd)
  vim.fn.jobstart(cmd, { detach = true })
  return true
end

-- Handlers for a MIME type.
--
-- The exact type ("application/pdf") wins, then the major type ("image/*"),
-- then "*".
local function handlers_for(mime)
  local table_ = config.options.attachment_handlers or {}
  mime = tostring(mime or ""):lower()

  local found = table_[mime]
  if not found then
    local major = mime:match("^([^/]+)/")
    found = major and table_[major .. "/*"] or nil
  end
  found = found or table_["*"]

  if not found then
    return {}
  end

  -- Allow a lone handler to be written without nesting it in a list.
  if found.mode or found.run or found.cmd then
    return { found }
  end
  return found
end

-- Run one handler.
local function launch(handler, path, info)
  -- Defer to a user-supplied function when there is one.
  if type(handler.run) == "function" then
    local ok, err = pcall(handler.run, path, info)
    if not ok then
      vim.notify(lang.t("prefix") .. tostring(err), vim.log.levels.ERROR)
    end
    return
  end

  local mode = handler.mode or "save"
  local runner = runners[mode]
  if not runner then
    return vim.notify(lang.e("unknown_open_mode", mode), vim.log.levels.ERROR)
  end

  if mode == "save" then
    return vim.notify(lang.t("saved_one", path), vim.log.levels.INFO)
  end

  local cmd = vim.deepcopy(handler.cmd or {})
  if #cmd == 0 then
    return vim.notify(lang.e("no_open_command"), vim.log.levels.ERROR)
  end
  table.insert(cmd, path)

  if vim.fn.executable(cmd[1]) == 0 then
    return vim.notify(
      lang.e("not_executable", cmd[1], path),
      vim.log.levels.ERROR
    )
  end

  local ok, err = runner(cmd, handler, path)
  if not ok then
    vim.notify(
      lang.t("prefix") .. (err or lang.t("launch_failed")) .. "\n" .. path,
      vim.log.levels.ERROR
    )
  end
end

-- Decide how to open one saved file, and do it.
local function open_one(att)
  local list = handlers_for(att.mime)

  if #list == 0 then
    return vim.notify(lang.t("saved_one", att.path), vim.log.levels.INFO)
  end
  if #list == 1 then
    return launch(list[1], att.path, att)
  end

  local labels = {}
  for i, h in ipairs(list) do
    table.insert(labels, h.label or ("#" .. i))
  end

  vim.ui.select(labels, { prompt = att.filename }, function(_, idx)
    if idx then
      launch(list[idx], att.path, att)
    end
  end)
end

-- Save the attachments, then open them.
--
-- himalaya's `attachment download` reports where each file actually landed
-- (appending "(1)" when a name is taken). Always open the returned path; never
-- a path assembled by guessing.
function M.download_and_open(account, mailbox, id, attachments)
  if #attachments == 0 then
    return vim.notify(lang.e("no_attachments"), vim.log.levels.INFO)
  end

  vim.notify(lang.t("downloading", #attachments), vim.log.levels.INFO)

  cli.download_attachments(account, mailbox, id, config.options.download_dir, function(ok, res)
    if not ok then
      return vim.notify(lang.t("prefix") .. res, vim.log.levels.ERROR)
    end

    local saved = res.attachments or {}
    if #saved == 0 then
      return vim.notify(lang.e("nothing_saved"), vim.log.levels.WARN)
    end

    local dir = vim.fn.fnamemodify(saved[1].path, ":h")
    vim.notify(lang.t("saved_to", #saved, dir), vim.log.levels.INFO)

    -- One file opens directly; several prompt for a pick.
    if #saved == 1 then
      return open_one(saved[1])
    end

    local labels = {}
    for _, a in ipairs(saved) do
      table.insert(labels, string.format("%s  (%s)", a.filename, util.format_size(a.size)))
    end

    vim.ui.select(labels, { prompt = lang.t("pick_attachment") }, function(_, idx)
      if idx then
        open_one(saved[idx])
      end
    end)
  end)
end

return M
