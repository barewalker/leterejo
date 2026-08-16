-- Small helpers for the screen.
--
-- Subjects and senders often contain wide characters, so counting characters
-- misaligns the columns. Everything here works in display cells instead.
local M = {}

local lang = require("leterejo.lang")

-- Characters that occupy no width: zero-width spaces, joiners, direction
-- marks, byte-order marks. Spam and spoofed mail slips them inside words to
-- defeat string matching (a sender posing as "ANA" with a joiner in between).
-- Left in place they skew the columns and hide the impersonation.
--
-- The direction controls matter more than the rest. An override reverses the
-- text after it, so a sender written "pj.oc.nozamA" arrives on screen reading
-- "Amazon.co.jp" — the string in the header and the name the reader sees are
-- different, which is the whole point of using it. One turned up in this
-- archive on the first day of looking.
local INVISIBLE = {
  "\226\128\139", -- U+200B zero-width space
  "\226\128\140", -- U+200C zero-width non-joiner
  "\226\128\141", -- U+200D zero-width joiner
  "\226\128\142", -- U+200E left-to-right mark
  "\226\128\143", -- U+200F right-to-left mark
  "\226\128\170", -- U+202A left-to-right embedding
  "\226\128\171", -- U+202B right-to-left embedding
  "\226\128\172", -- U+202C pop directional formatting
  "\226\128\173", -- U+202D left-to-right override
  "\226\128\174", -- U+202E right-to-left override
  "\226\129\160", -- U+2060 word joiner
  "\226\129\166", -- U+2066 left-to-right isolate
  "\226\129\167", -- U+2067 right-to-left isolate
  "\226\129\168", -- U+2068 first strong isolate
  "\226\129\169", -- U+2069 pop directional isolate
  "\239\187\191", -- U+FEFF byte-order mark
}

-- The direction controls, kept apart from the rest.
--
-- These two groups look the same in a header and mean different things, and
-- measuring them together makes both useless. A direction override rewrites
-- what the reader sees — "pj.oc.nozamA" arrives reading "Amazon.co.jp" — so one
-- is worth a warning. Zero-width padding inside a word only defeats a string
-- match, which is the ordinary furniture of bulk mail.
--
-- Measured over 3,000 messages here: 950 carried something invisible, but 915
-- of those came from a single spam domain padding its words, and exactly 2
-- carried an override — both impersonating Amazon. One marker for both would
-- have fired on a third of the inbox and meant nothing.
local BIDI = {
  ["\226\128\170"] = true, -- U+202A left-to-right embedding
  ["\226\128\171"] = true, -- U+202B right-to-left embedding
  ["\226\128\172"] = true, -- U+202C pop directional formatting
  ["\226\128\173"] = true, -- U+202D left-to-right override
  ["\226\128\174"] = true, -- U+202E right-to-left override
  ["\226\129\166"] = true, -- U+2066 left-to-right isolate
  ["\226\129\167"] = true, -- U+2067 right-to-left isolate
  ["\226\129\168"] = true, -- U+2068 first strong isolate
  ["\226\129\169"] = true, -- U+2069 pop directional isolate
}

-- Strip what must not reach the screen.
--
-- Returns the cleaned string, how many direction controls were in it, and how
-- many of the rest. Every one of them is removed either way: any of them throws
-- the columns out. Only the counting distinguishes them.
--
-- Control characters are taken out too, but deliberately left out of the
-- count. A carriage return or newline in a header is not cosmetic — a buffer
-- line cannot hold one, so leaving it in place makes the redraw fail outright.
-- They arrive from ordinary RFC 5322 folding as often as from anything
-- untoward, though, and counting them would raise the impersonation marker on
-- every long subject until the marker meant nothing.
--
-- They become a space rather than vanishing, or an unfolded header would run
-- two words together; the runs are collapsed afterwards.
function M.strip_invisible(s)
  s = s or ""
  local bidi, padding = 0, 0

  for _, ch in ipairs(INVISIBLE) do
    local n
    s, n = s:gsub(ch, "")
    if BIDI[ch] then
      bidi = bidi + n
    else
      padding = padding + n
    end
  end

  s = s:gsub("%c", " "):gsub("%s%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

  return s, bidi, padding
end

-- The subset of the above that a message body is better off without.
--
-- The list strips all of them, because any one of them throws the columns out.
-- A body has no columns to protect, so the test is different: does the
-- character mean anything to a reader? The direction controls and the various
-- blank separators do not — Neovim cannot draw them and shows "<202e>" instead,
-- so leaving them in trades a deception for a mess.
--
-- The two joiners are kept. They hold emoji sequences together, and a family
-- emoji coming apart into three people is a real loss on ordinary mail.
local MEANINGLESS = {
  "\226\128\139", -- U+200B zero-width space
  "\226\128\142", -- U+200E left-to-right mark
  "\226\128\143", -- U+200F right-to-left mark
  "\226\128\170", -- U+202A left-to-right embedding
  "\226\128\171", -- U+202B right-to-left embedding
  "\226\128\172", -- U+202C pop directional formatting
  "\226\128\173", -- U+202D left-to-right override
  "\226\128\174", -- U+202E right-to-left override
  "\226\129\160", -- U+2060 word joiner
  "\226\129\166", -- U+2066 left-to-right isolate
  "\226\129\167", -- U+2067 right-to-left isolate
  "\226\129\168", -- U+2068 first strong isolate
  "\226\129\169", -- U+2069 pop directional isolate
  "\239\187\191", -- U+FEFF byte-order mark
}

-- Clean a body for display, leaving its line structure alone.
function M.strip_deceptive(s)
  s = s or ""
  for _, ch in ipairs(MEANINGLESS) do
    s = s:gsub(ch, "")
  end
  return s
end

-- Display width of a string; wide characters count as two.
function M.width(s)
  return vim.fn.strdisplaywidth(s or "")
end

-- Truncate to `width` display cells, ending with "…" when anything was cut.
function M.truncate(s, width)
  s = s or ""
  if width <= 0 then
    return ""
  end
  if M.width(s) <= width then
    return s
  end

  -- Add one character at a time so a wide one is never split.
  local out, acc = {}, 0
  for _, ch in ipairs(vim.fn.split(s, "\\zs")) do
    local w = M.width(ch)
    if acc + w > width - 1 then
      break
    end
    table.insert(out, ch)
    acc = acc + w
  end

  return table.concat(out) .. "…"
end

-- Pad on the right until the string occupies `width` cells.
function M.pad(s, width)
  s = s or ""
  local diff = width - M.width(s)
  if diff <= 0 then
    return s
  end
  return s .. string.rep(" ", diff)
end

-- Fit to exactly `width` cells (truncate, then pad).
function M.fit(s, width)
  return M.pad(M.truncate(s, width), width)
end

-- Decode quoted-printable.
-- RFC 2047's Q form differs from the base rule: underscore means space.
local function decode_quoted_printable(s)
  s = s:gsub("_", " ")
  return (s:gsub("=(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

-- Decode RFC 2047 encoded words.
--
-- Mail headers carry ASCII only, so non-ASCII filenames and subjects arrive
-- shaped like `=?UTF-8?B?...?=`. himalaya decodes subjects and senders for us,
-- but the attachment names from `imap fetch --structure` come through raw.
function M.decode_rfc2047(s)
  if type(s) ~= "string" or not s:find("=%?") then
    return s or ""
  end

  local decoded = s:gsub("=%?([%w%-]+)%?([BbQq])%?(.-)%?=", function(charset, kind, data)
    local raw
    if kind:upper() == "B" then
      local ok, out = pcall(vim.base64.decode, data)
      if not ok then
        return nil -- leave the original when it cannot be decoded
      end
      raw = out
    else
      raw = decode_quoted_printable(data)
    end

    -- Convert when the charset is not UTF-8 (Japanese mail still uses
    -- ISO-2022-JP). Leave it alone if the conversion fails.
    if charset:upper() ~= "UTF-8" then
      local converted = vim.fn.iconv(raw, charset, "utf-8")
      if converted ~= "" then
        raw = converted
      end
    end

    return raw
  end)

  -- Whitespace between adjacent encoded words is layout only; drop it.
  return (decoded:gsub("%?=%s+=%?", "?==?"))
end

-- Group thousands, so a five-digit message count can be read at a glance.
function M.group_digits(n)
  local s = tostring(math.floor(tonumber(n) or 0))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end

-- Render a byte count in readable units.
function M.format_size(bytes)
  bytes = tonumber(bytes) or 0
  if bytes >= 1024 * 1024 then
    return string.format("%.1f MiB", bytes / 1024 / 1024)
  elseif bytes >= 1024 then
    return string.format("%.0f KiB", bytes / 1024)
  end
  return string.format("%d B", bytes)
end

-- Sender label, falling back to the address when there is no display name.
-- In v2's JSON `from` is an array and `name` may be null.
function M.address_label(addrs)
  local a = (addrs or {})[1]
  if not a then
    return ""
  end
  if a.name ~= nil and a.name ~= vim.NIL and a.name ~= "" then
    return a.name
  end
  return a.email or ""
end

-- Format an ISO 8601 timestamp for the list.
--
-- "MM-DD HH:MM" within the current year, "YYYY-MM-DD" outside it. Showing the
-- time of day on a message from three years ago wastes the space that says
-- which year it was — and with an archive spanning 2018 to now, that is the
-- part worth reading.
--
-- himalaya returns the sender's own offset, so convert to local time first.
function M.format_date(iso, full)
  if type(iso) ~= "string" then
    return ""
  end

  local y, mo, d, h, mi, sign, oh, om =
    iso:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):%d+([+%-])(%d+):(%d+)")

  if not y then
    -- Also accept the trailing-Z (UTC) form.
    y, mo, d, h, mi = iso:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):%d+Z")
    if not y then
      return iso:sub(6, 16)
    end
    sign, oh, om = "+", "0", "0"
  end

  -- Normalise to a UTC epoch, then render it in local time.
  local utc = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = 0,
    isdst = false,
  })

  local offset = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == "-" and -1 or 1)

  -- os.time reads its input as local time, so cancel that shift out.
  local local_offset = os.difftime(os.time(os.date("*t", utc)), os.time(os.date("!*t", utc)))

  local at = utc - offset + local_offset

  if full then
    -- Everything, for a line someone else will read: a quote attributed to
    -- "08-07 23:26" leaves them working out which year it was.
    return os.date("%Y-%m-%d %H:%M", at)
  end

  if os.date("%Y", at) == os.date("%Y") then
    return os.date("%m-%d %H:%M", at)
  end
  return os.date("%Y-%m-%d", at)
end

-- Collect attachments from a MIME structure.
--
-- Walks nested multiparts and treats every leaf as an attachment except the
-- body itself (an unnamed text/*). Names arrive encoded, so decode them.
function M.collect_attachments(structure)
  local found = {}

  local function walk(part)
    if type(part) ~= "table" then
      return
    end

    for _, child in ipairs(part.parts or {}) do
      walk(child)
    end

    if part.parts and #part.parts > 0 then
      return -- a container is not itself an attachment
    end

    local ctype = tostring(part.content_type or ""):lower()
    local name = part.name

    -- Unnamed parts of a body type are not attachments.
    if (name == nil or name == vim.NIL) and ctype:match("^text/") then
      return
    end

    table.insert(found, {
      -- Cleaned like any other header: an attachment name is listed above the
      -- body, so a newline in it would break that redraw the same way.
      name = (name ~= nil and name ~= vim.NIL) and M.strip_invisible(M.decode_rfc2047(name))
        or lang.t("no_name"),
      content_type = part.content_type or "",
      size = part.size or 0,
    })
  end

  walk(structure)
  return found
end

-- Whether an envelope carries a flag. himalaya reports them by IANA keyword
-- without the backslash: "seen", "answered", "flagged", "draft".
function M.has_flag(envelope, name)
  for _, f in ipairs(envelope.flags or {}) do
    if f.iana == name then
      return true
    end
  end
  return false
end

-- Whether an envelope is unread.
function M.is_unseen(envelope)
  return not M.has_flag(envelope, "seen")
end

-- Make sure a buffer's colours are loaded, not merely asked for.
--
-- Setting `filetype` is not the same as the syntax having been read. The option
-- fires a FileType autocmd and the autocmd is what reads the syntax file — and
-- an autocmd can be suppressed. `eventignore` is set by perfectly ordinary
-- things: fzf-lua wraps opening and closing a picker in it. Create a buffer in
-- that moment and the option says "mail" while nothing was ever loaded, so the
-- message is grey — and stays grey for the rest of the session, because setting
-- the option to the value it already holds changes nothing and fires nothing.
--
-- Measured: with `eventignore=all` in force, `filetype` reads "mail",
-- `b:current_syntax` is nil, and the header lines have no highlight at all.
-- That is exactly what was reported, after an account picker and after tagging
-- a selection — both of which are pickers.
--
-- `b:current_syntax` is the honest answer: the syntax file sets it and refuses
-- to run twice on the strength of it. So that is what is checked, and the file
-- is read directly rather than by asking for the option again.
--
-- Left alone when syntax is off altogether: that is a choice, not a mishap.
function M.ensure_syntax(buf, name)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  if vim.bo[buf].filetype ~= name then
    vim.bo[buf].filetype = name
  end

  if not vim.g.syntax_on or vim.b[buf].current_syntax == name then
    return
  end

  pcall(vim.api.nvim_buf_call, buf, function()
    vim.cmd("runtime! syntax/" .. name .. ".vim")
  end)
end

return M
