-- Images shown in the message, drawn by the terminal.
--
-- Only what the message actually carries: an attachment, or a part the HTML
-- refers to by `cid:`. Remote images are never fetched, and that is a decision
-- rather than an omission — the majority of images in bulk mail are one-pixel
-- trackers whose whole purpose is to report that the message was opened.
-- Loading them on display would tell every sender exactly when their mail was
-- read, which is precisely what reading mail in a terminal is meant to avoid.
--
-- The drawing itself belongs to snacks.nvim, which speaks the kitty graphics
-- protocol. Without it, or in a terminal that cannot draw, nothing happens and
-- the attachment list reads as it did before.
local config = require("leterejo.config")

local M = {}

-- Where extracted images are kept between draws.
--
-- The terminal renders from a file, so each part has to be written out once.
-- Names are a digest of the message and part rather than the attachment's own
-- name: a name from a message is attacker-controlled, and one containing a
-- slash would write outside this directory.
local function cache_dir()
  local dir = vim.fn.stdpath("cache") .. "/leterejo/images"
  vim.fn.mkdir(dir, "p")
  return dir
end

local function cache_path(id, part, name, content_type)
  -- The type first: a name split across RFC 2231 parameters can come back
  -- without its extension, and what draws the image decides by extension.
  local ext = require("leterejo.notmuch").extension_for(content_type)
    or tostring(name or ""):match("%.([%w]+)$")
    or "img"
  local digest = vim.fn.sha256(tostring(id) .. "\0" .. tostring(part)):sub(1, 32)
  return cache_dir() .. "/" .. digest .. "." .. ext:lower()
end

-- Whether images can be drawn here at all.
function M.available()
  if not config.options.inline_images then
    return false
  end

  local ok = pcall(require, "snacks")
  if not ok or not Snacks or not Snacks.image then
    return false
  end

  local supports = Snacks.image.supports_terminal
  return type(supports) == "function" and supports()
end

-- Whether to draw them in this particular view.
--
-- A picture in a terminal is two things: the image registered once, and a small
-- instruction to show it. Only the second should repeat. But a multiplexer draws
-- its own text over the picture and has to put it back on every frame, and one
-- of them was measured re-preparing the whole image each time to decide it did
-- not need to send it — 62 times a second, a full core, for a body nobody was
-- touching. The preview follows the cursor, so it is exactly where that costs
-- most and is wanted least.
--
-- Hence `"opened"`: drawn in a message asked for by name, not in the one that
-- happens to be under the cursor. `inline_images = true` restores them
-- everywhere, which is the right setting once the terminal stops doing that.
function M.wanted(opts)
  local mode = config.options.inline_images
  if not mode then
    return false
  end
  if opts and opts.preview and mode ~= true then
    return false
  end
  return M.available()
end

-- Forget the images drawn in this buffer.
--
-- Every redraw rebuilds the lines underneath them, so placements from the
-- previous message would otherwise be left pointing at rows that now belong to
-- a different one.
function M.clear(buf)
  if not (Snacks and Snacks.image and Snacks.image.placement) then
    return
  end
  pcall(Snacks.image.placement.clean, buf)
end

local function place(buf, path, row)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if not Snacks.image.supports_file(path) then
    return -- a format the terminal will not take, e.g. an unconverted TIFF
  end

  pcall(Snacks.image.placement.new, buf, path, {
    pos = { row, 0 },
    inline = true,
    max_height = config.options.inline_image_max_height or 12,
  })
end

-- Draw the images of a message.
--
--   attachments : as listed above the body
--   rows        : attachment index -> the buffer line its entry is on
--   opts.preview: the body is following the cursor rather than opened
--
-- Extraction is per part and asynchronous, so a message with six images does
-- not hold the screen while they are written out. Each placement checks the
-- buffer is still valid, because the reader may have moved on.
function M.show(buf, id, attachments, rows, opts)
  -- Cleared even when nothing will be drawn: the buffer is reused for every
  -- message, so a picture from the last one would otherwise stay on rows that
  -- now belong to this one.
  M.clear(buf)

  if not M.wanted(opts) then
    return
  end

  local notmuch = require("leterejo.notmuch")

  for i, att in ipairs(attachments or {}) do
    local row = rows and rows[i]
    if row and tostring(att.content_type):match("^image/") and att.part then
      local path = cache_path(id, att.part, att.name, att.content_type)

      if vim.fn.filereadable(path) == 1 then
        place(buf, path, row)
      else
        notmuch.save_part(require("leterejo.state").account, id, att.part, path, function(ok)
          if ok then
            place(buf, path, row)
          end
        end)
      end
    end
  end
end

return M
