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

-- Whether what we would send can be kept to a size worth sending.
--
-- What crosses to the terminal is pixels. An attachment of 3840x2160 is 33 MB
-- of them, 44 MB once encoded — measured here, and refused by the terminal for
-- exceeding a 32 MB frame. So the picture never appeared, and since a refused
-- frame taught it nothing, the same 44 MB was built again on every frame after
-- that. Shrinking it first is what makes the whole question go away: the same
-- image at 800 across is 1.4 MB.
local function bounded()
  local max = config.options.inline_image_max_pixels
  local spec = config.options.image_resize
  if not max or type(spec) ~= "table" or #spec == 0 then
    return false
  end
  return vim.fn.executable(spec[1]) == 1
end

-- Whether to draw them in this particular view.
--
--   true      wherever the body is shown, but only where the size is bounded
--   "opened"  never in the preview, whatever the size
--   false     never
--
-- The preview is redrawn every time the cursor moves, so it is where an
-- unbounded image costs most. Rather than refuse it outright, refuse it when
-- there is nothing to shrink with — an attachment handed over whole is fine in
-- a message opened deliberately, and is not fine sixty-two times a second.
function M.wanted(opts)
  local mode = config.options.inline_images
  if not mode then
    return false
  end

  if opts and opts.preview then
    if mode ~= true then
      return false
    end
    if not bounded() then
      return false
    end
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

-- Where the shrunk copy of an image is kept.
--
-- Beside the original and named for the size it was made at, so changing the
-- setting makes a new one rather than showing the old one at the wrong size.
-- Always .png: it is what every terminal takes, which also settles the formats
-- that would otherwise be extracted and then refused.
local function scaled_path(path, max)
  return path:gsub("%.[^.]*$", "") .. "-" .. tostring(max) .. ".png"
end

-- Make a copy no larger than `max` pixels on its longest side.
--
-- Because what reaches the terminal is pixels, not the file: a 200 KB JPEG at
-- four thousand pixels across becomes tens of megabytes on the wire, and the
-- body shows it twelve rows tall. One message here produced a 42 MB frame that
-- its terminal then refused as oversized — so the picture never appeared, and
-- the work was repeated for every frame after that.
--
-- `on_done(path)` gets the copy, or nil when there is nothing to shrink with.
local function shrink(src, dst, max, on_done)
  local spec = config.options.image_resize

  if type(spec) ~= "table" or #spec == 0 or vim.fn.executable(spec[1]) ~= 1 then
    return on_done(nil)
  end

  local cmd = {}
  for _, part in ipairs(spec) do
    table.insert(
      cmd,
      (tostring(part):gsub("{%w+}", { ["{src}"] = src, ["{dst}"] = dst, ["{max}"] = tostring(max) }))
    )
  end

  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function()
      on_done(res.code == 0 and vim.fn.filereadable(dst) == 1 and dst or nil)
    end)
  end)
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

  -- Draw the smaller copy, making it first if this is the first sight of the
  -- image. Both are kept: the original is what was attached, and saving it
  -- should not hand over something this reduced for the screen.
  local function draw(path, row)
    local max = config.options.inline_image_max_pixels
    if not max then
      return place(buf, path, row)
    end

    local small = scaled_path(path, max)
    if vim.fn.filereadable(small) == 1 then
      return place(buf, small, row)
    end

    shrink(path, small, max, function(out)
      place(buf, out or path, row)
    end)
  end

  for i, att in ipairs(attachments or {}) do
    local row = rows and rows[i]
    if row and tostring(att.content_type):match("^image/") and att.part then
      local path = cache_path(id, att.part, att.name, att.content_type)

      if vim.fn.filereadable(path) == 1 then
        draw(path, row)
      else
        notmuch.save_part(require("leterejo.state").account, id, att.part, path, function(ok)
          if ok then
            draw(path, row)
          end
        end)
      end
    end
  end
end

return M
