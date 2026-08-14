-- Highlight groups for the list.
--
-- Every group links to one of Neovim's standard groups rather than naming a
-- colour, so the list follows whatever colourscheme is loaded instead of
-- imposing its own. Anyone who wants something different defines the group
-- themselves: these are installed with `default = true`, which yields to an
-- existing definition.
--
-- Links are re-applied on ColorScheme. Loading a colourscheme clears every
-- highlight, including ours, so without that the list loses its colour the
-- first time the user switches theme.
local M = {}

M.ns = vim.api.nvim_create_namespace("leterejo")

local GROUPS = {
  -- The status line at the top of the list.
  LeterejoHeader = { link = "Title" },
  LeterejoHeaderCount = { link = "Number" },
  LeterejoHeaderQuery = { link = "String" },
  LeterejoHeaderNote = { link = "Comment" },

  -- The row naming the columns.
  LeterejoColumns = { link = "Comment" },

  -- The three marker columns. Each has its own group because they mean very
  -- different things: one is a state, one is a choice the user made, and one
  -- is a warning.
  LeterejoUnreadMark = { link = "Special" },
  LeterejoFlaggedMark = { link = "WarningMsg" },
  LeterejoAttachMark = { link = "Constant" },
  LeterejoSuspectMark = { link = "ErrorMsg" },

  -- The columns themselves.
  LeterejoDate = { link = "Comment" },
  LeterejoFrom = { link = "Identifier" },
  LeterejoSubject = { link = "Normal" },

  -- An unread subject. Bold rather than coloured: colour here would fight the
  -- marker column, and every row in a busy inbox is unread.
  LeterejoSubjectUnread = { bold = true },

  -- Threads: the count on a collapsed row, and the guides on expanded ones.
  LeterejoThreadMark = { link = "Number" },
  LeterejoTree = { link = "NonText" },

  -- Whole-line states.
  LeterejoEmpty = { link = "Comment" },
  LeterejoMore = { link = "Comment" },
}

function M.apply()
  for name, spec in pairs(GROUPS) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", spec, { default = true }))
  end
end

local installed = false

function M.setup()
  if installed then
    return
  end
  installed = true

  M.apply()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("LeterejoHighlight", { clear = true }),
    callback = M.apply,
    desc = "leterejo: restore highlight links after a colourscheme change",
  })
end

-- Build a line out of highlighted pieces.
--
-- Extmarks are placed by byte offset while the columns are measured in display
-- cells, so the offsets are accumulated here as the line is assembled rather
-- than searched for afterwards — a subject containing the same text as a
-- sender would otherwise be highlighted in the wrong place.
function M.line()
  local parts, marks, col = {}, {}, 0

  return {
    add = function(text, group)
      text = text or ""
      if group and #text > 0 then
        table.insert(marks, { col, col + #text, group })
      end
      table.insert(parts, text)
      col = col + #text
    end,
    build = function()
      return table.concat(parts), marks
    end,
  }
end

-- Draw the collected marks. `rows` is a list of mark lists, one per line,
-- indexed from the first line of the buffer.
function M.paint(buf, rows)
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)

  for row, marks in pairs(rows) do
    for _, m in ipairs(marks) do
      -- A redraw can race a buffer that shrank under us; a failed mark is not
      -- worth aborting the paint for.
      pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, row - 1, m[1], {
        end_col = m[2],
        hl_group = m[3],
      })
    end
  end
end

return M
