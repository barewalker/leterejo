-- Key binding plumbing.
--
-- Configuration is written as "action name -> key"; false leaves an action
-- unbound. Applied per buffer kind.
local config = require("leterejo.config")
local lang = require("leterejo.lang")

local M = {}

-- The key bound to an action, for display. Hard-coding keys in prose would
-- drift out of sync once the user rebinds something.
function M.label(scope, name)
  local k = ((config.options.keymaps or {})[scope] or {})[name]
  return type(k) == "string" and k ~= "" and k or "(unbound)"
end

-- Available keys, wrapped to fit.
--
-- which-key only appears after <leader>, so single-key bindings stay invisible
-- until pressed. These lines are kept on screen instead. There are more
-- actions than one line holds, so it wraps rather than hiding half of them;
-- what still does not fit is marked with an ellipsis instead of disappearing
-- silently.
--
--   items     : list of { action name, message key }; unbound ones are skipped
--   width     : display cells available
--   max_lines : how many lines may be used (two by default)
--
-- Returns a list of lines, never empty.
function M.hint_lines(scope, items, width, max_lines)
  max_lines = max_lines or 2

  local SEP = "   "
  local spec = (config.options.keymaps or {})[scope] or {}
  local parts = {}

  for _, item in ipairs(items) do
    local key = spec[item[1]]
    if type(key) == "string" and key ~= "" then
      -- Tidy up forms like <cr> for display
      local shown = key:gsub("^<(.-)>$", "%1")
      table.insert(parts, shown .. " " .. lang.t(item[2]))
    end
  end

  if #parts == 0 then
    return { "" }
  end

  local function fits(s)
    return not width or width <= 0 or vim.fn.strdisplaywidth(s) <= width
  end

  local lines, current = {}, parts[1]

  for i = 2, #parts do
    local candidate = current .. SEP .. parts[i]
    if fits(candidate) then
      current = candidate
    elseif #lines + 1 < max_lines then
      table.insert(lines, current)
      current = parts[i]
    else
      current = current .. " …"
      break
    end
  end

  table.insert(lines, current)
  return lines
end

-- Bind `actions` (action name -> handler) on `buf` per configuration.
--   scope is "envelopes", "message" or "compose".
function M.apply(buf, scope, actions)
  local spec = (config.options.keymaps or {})[scope] or {}

  for name, fn in pairs(actions) do
    local lhs = spec[name]

    -- false leaves it unbound; a missing entry is treated the same.
    if type(lhs) == "string" and lhs ~= "" then
      vim.keymap.set("n", lhs, fn.handler, {
        buffer = buf,
        nowait = true,
        silent = true,
        desc = "leterejo: " .. (fn.desc or name),
      })
    end
  end
end

return M
