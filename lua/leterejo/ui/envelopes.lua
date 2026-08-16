-- The envelope list buffer.
--
-- One row per message, or per conversation where the account can group them.
-- Row numbers map back to envelopes so actions can target whatever sits under
-- the cursor.
--
-- The list grows as the cursor nears its end rather than breaking into pages.
-- Paging only ever existed because a fetch over IMAP cost seconds; the index
-- answers a batch in tens of milliseconds, so there is nothing left to ration.
local config = require("leterejo.config")
local hl = require("leterejo.ui.highlight")
local lang = require("leterejo.lang")
local notmuch = require("leterejo.notmuch")
local state = require("leterejo.state")
local util = require("leterejo.ui.util")

local M = {}

local BUFNAME = "leterejo://envelopes"

-- Column widths in display cells; the subject takes whatever remains.
-- The marker column holds three: state, flagged, attachment.
local DEFAULT_WIDTHS = { markers = 3, date = 11, from = 24, thread = 4 }

local function W(name)
  return (config.options.columns or {})[name] or DEFAULT_WIDTHS[name]
end

local function find_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == BUFNAME then
      return b
    end
  end
  return nil
end

-- Modes ---------------------------------------------------------------------

-- Whether the list is grouped into conversations.
--
-- Filtering is always flat: a search result is a set of messages that matched,
-- and folding them into conversations would hide the very rows the user asked
-- for behind a collapsed parent.
local function threaded()
  return not (state.query or config.options.threads == false)
end

-- Order ----------------------------------------------------------------------

-- The orders notmuch cannot give, arranged here instead.
--
-- notmuch sorts by date and by nothing else, so ordering by sender or subject
-- means reading the list in whole and arranging it. Returns the order when it
-- is one of those, and nil when the index is doing the ordering itself.
local function ordered_here()
  local order = state.sorting()
  return (order == "from" or order == "subject") and order or nil
end

-- What a row sorts under.
--
-- Read off the row rather than fetched, so the order is one that can be checked
-- by looking at the screen: the sender column is the sender it sorted on.
local function from_key(e)
  return util.strip_invisible(util.address_label(e.from)):lower()
end

-- The subject with the reply and forward prefixes taken off, so that a message
-- and the replies to it land together rather than under R and F. Japanese mail
-- carries 転送: and Re: in the same header often enough to strip both, and a
-- long thread piles them up, so this runs until nothing more comes off.
local function subject_key(e)
  local s = util.strip_invisible(e.subject or "")

  while true do
    local shorter = s:gsub("^%s*[%(%[]?%s*[Rr][Ee]%s*[%(%[]?%d*[%)%]]?%s*[:：]%s*", "")
    shorter = shorter:gsub("^%s*[Ff][Ww][Dd]?%s*[:：]%s*", "")
    shorter = shorter:gsub("^%s*[転返][送信]%s*[:：]%s*", "")
    if shorter == s then
      break
    end
    s = shorter
  end

  return s:lower()
end

-- Newest first within one sender, or one subject: the second key is always the
-- date, because two rows that sort the same still have to sort somehow, and any
-- other answer would shuffle on every redraw.
local function comparator(order)
  local key = order == "from" and from_key or subject_key

  return function(a, b)
    local ka, kb = key(a), key(b)
    if ka ~= kb then
      return ka < kb
    end
    return tostring(a.date or "") > tostring(b.date or "")
  end
end

-- Whether more rows can be asked for as the cursor nears the end.
--
-- A plain list always can. A filtered one asks the search: a query the index
-- answers resumes at an offset, but a scan already read as far as it was going
-- to and has nothing left to hand over. An order the index cannot give was
-- arranged from the whole list at once, so there is nothing after it either.
local function growable()
  if ordered_here() then
    return false
  end
  if state.query then
    return require("leterejo.search").resumable(state.query.text)
  end
  return true
end

-- Where the body of the row under the cursor is kept on screen, if anywhere.
--
-- Returns "below", "right", or nil for no preview.
--
-- "auto" measures the pane rather than the terminal. Inside herdr or tmux the
-- editor occupies whatever the pane gives it, and that is what decides whether
-- two columns fit — the same session is a tall strip in one pane and a wide
-- board in another. Side by side wins where there is width for two readable
-- columns; otherwise stacked, if there is height for two readable halves;
-- otherwise nothing, because a split neither half can be read in helps nobody.
local function preview_where()
  local mode = config.options.preview
  if mode == false then
    return nil
  end
  if mode == "below" or mode == "right" then
    return mode
  end

  if vim.o.columns >= (config.options.preview_min_width or 160) then
    return "right"
  end
  if vim.o.lines >= (config.options.preview_min_height or 30) then
    return "below"
  end
  return nil
end

local function previewing()
  return state.preview_enabled ~= false and preview_where() ~= nil
end

-- Stop the body from following the cursor, or let it again.
function M.toggle_preview()
  if previewing() then
    state.preview_enabled = false
    state.preview_id = nil

    local win = require("leterejo.ui.message").find_win()
    if win and #vim.api.nvim_list_wins() > 1 then
      vim.api.nvim_win_close(win, true)
    end
    return vim.notify(lang.t("preview_off"), vim.log.levels.INFO)
  end

  state.preview_enabled = true
  if preview_where() == nil then
    -- Turned on, but there is no room for it in a pane this shape.
    return vim.notify(lang.t("preview_no_room"), vim.log.levels.WARN)
  end

  vim.notify(lang.t("preview_on"), vim.log.levels.INFO)
  M.preview()
end

-- Layout --------------------------------------------------------------------

local function thread_width()
  return threaded() and W("thread") or 0
end

-- Width of the window showing the list.
--
-- The current window is not it when an operation is triggered from the body
-- buffer, and measuring that one would lay the columns out for the wrong width.
local function width_of(buf)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == buf then
      return vim.api.nvim_win_get_width(w)
    end
  end
  return vim.api.nvim_win_get_width(0)
end

local function subject_width(buf)
  local fixed = W("markers") + W("date") + W("from") + thread_width()
  -- One space between each column, and one after the last.
  local gaps = thread_width() > 0 and 5 or 4
  return math.max(20, width_of(buf) - fixed - gaps)
end

-- How many lines the key hints took last time they were drawn. They wrap on a
-- narrow window, so the offset from a cursor row to an envelope is not fixed.
local hint_height = 1

-- Rows preceding the list; needed to map a cursor row to an envelope.
local function header_height()
  local n = 1
  if config.options.show_hints then
    n = n + hint_height
  end
  if config.options.show_columns then
    n = n + 1
  end
  return n
end

-- Drawing -------------------------------------------------------------------

-- Where we are, how much of it is on screen, and whether anything can be
-- changed. Assembled piece by piece rather than from one format string so each
-- part can carry its own colour.
local function render_header()
  local b = hl.line()

  b.add(state.account_label() .. " / " .. tostring(state.mailbox), "LeterejoHeader")
  b.add("  ")

  if state.query then
    b.add(lang.t("filtered_by", state.query.text), "LeterejoHeaderQuery")
    b.add("  ")
  end

  if state.envelopes == nil then
    b.add(lang.t("loading"), "LeterejoHeaderNote")
  elseif state.total then
    local key = threaded() and "count_threads" or "count_of"
    b.add(
      lang.t(key, util.group_digits(state.loaded), util.group_digits(state.total)),
      "LeterejoHeaderCount"
    )
  else
    b.add(lang.t("count", #state.envelopes), "LeterejoHeaderCount")
  end

  -- The order, unless it is the one every mail list has by default. Saying
  -- "newest first" on every screen forever teaches nothing; saying "by sender"
  -- explains a list that is not in the order the eye expects.
  if state.sorting() ~= "newest" then
    b.add("  ")
    b.add(lang.t("sorted_by", lang.t("sort_" .. state.sorting())), "LeterejoHeaderNote")
  end

  -- How many rows are picked out. The marks say which; this says how many,
  -- which is the number that matters before pressing d.
  local picked = #state.selection()
  if picked > 0 then
    b.add("  ")
    b.add(lang.t("selected_count", picked), "LeterejoHeaderCount")
  end

  -- While filtering, state the reach as well as the query. A scan only saw a
  -- recent slice, and hiding that invites misreading the result.
  if state.query then
    local scope
    if state.query.index then
      -- notmuch covers every indexed message, so there is no slice to warn about.
      scope = lang.t("scope_index")
    else
      scope = lang.t("scope_local", state.query.scanned or 0)
    end
    b.add("  (" .. scope .. ")", "LeterejoHeaderNote")
    b.add("   ")
    b.add(
      lang.t(
        "search_hint",
        require("leterejo.keymaps").label("envelopes", "search"),
        require("leterejo.keymaps").label("envelopes", "clear_search")
      ),
      "LeterejoHeaderNote"
    )
  end

  if state.is_readonly() then
    b.add(lang.t("readonly"), "LeterejoHeaderNote")
  end

  return b.build()
end

local function render_columns(width)
  local b = hl.line()
  b.add(string.rep(" ", W("markers") + 1), "LeterejoColumns")
  b.add(util.fit(lang.t("col_date"), W("date")) .. " ", "LeterejoColumns")
  b.add(util.fit(lang.t("col_from"), W("from")) .. " ", "LeterejoColumns")
  if thread_width() > 0 then
    b.add(string.rep(" ", thread_width()) .. " ", "LeterejoColumns")
  end
  -- Not padded: trailing blanks on the last column serve nothing and show up
  -- when the line is yanked.
  b.add(util.truncate(lang.t("col_subject"), width), "LeterejoColumns")
  return b.build()
end

-- The thread column: a count on a parent, a guide on a child, blank otherwise.
local function add_thread_cell(b, e)
  if thread_width() == 0 then
    return
  end

  local glyphs = config.options.thread_glyphs or {}

  if e.depth then
    local guide = e.last_child and (glyphs.last_child or "`-") or (glyphs.child or "|-")
    b.add(util.fit(guide, W("thread")) .. " ", "LeterejoTree")
  elseif (e.thread_total or 1) > 1 then
    local mark = e.expanded and (glyphs.expanded or "v") or (glyphs.collapsed or ">")
    b.add(util.fit(mark .. tostring(e.thread_total), W("thread")) .. " ", "LeterejoThreadMark")
  else
    b.add(string.rep(" ", W("thread")) .. " ")
  end
end

local function render_row(e, width)
  local b = hl.line()

  -- Strip invisible characters from the sender and subject.
  --
  -- A direction control means the name on screen is not the string in the
  -- header, which outranks whether the message has been read. Zero-width
  -- padding is not shown here at all: it is ordinary in bulk mail, and a marker
  -- that fires on a third of the inbox says nothing. `is:obfuscated` finds it.
  local from, bidi_a = util.strip_invisible(util.address_label(e.from))
  local subject, bidi_b = util.strip_invisible(e.subject or lang.t("no_subject"))
  local unread = util.is_unseen(e)

  -- Picked out to be acted on together. First, and its own cell: it is the one
  -- marker that says what the next key will do rather than what the message is.
  if state.is_selected(e.id) then
    b.add("#", "LeterejoSelectedMark")
  else
    b.add(" ")
  end

  if bidi_a + bidi_b > 0 then
    b.add("!", "LeterejoSuspectMark")
  elseif unread then
    b.add("*", "LeterejoUnreadMark")
  else
    b.add(" ")
  end

  -- The flagged mark, a star in most other clients. Kept in its own column so
  -- it does not compete with the unread and impersonation markers.
  if util.has_flag(e, "flagged") then
    b.add("+", "LeterejoFlaggedMark")
  else
    b.add(" ")
  end

  if e["has-attachment"] == true then
    b.add("@", "LeterejoAttachMark")
  else
    b.add(" ")
  end
  b.add(" ")

  b.add(util.fit(util.format_date(e.date), W("date")) .. " ", "LeterejoDate")
  b.add(util.fit(from, W("from")) .. " ", "LeterejoFrom")
  add_thread_cell(b, e)
  b.add(util.truncate(subject, width), unread and "LeterejoSubjectUnread" or "LeterejoSubject")

  return b.build()
end

local function redraw(buf)
  -- A fetch can outlive the list: closing it in the meantime is ordinary rather
  -- than exceptional, and the callback then arrives holding a buffer that no
  -- longer exists.
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local width = subject_width(buf)
  local lines, marks = {}, {}

  local function push(line, m)
    table.insert(lines, line)
    if m and #m > 0 then
      marks[#lines] = m
    end
  end

  push(render_header())

  if config.options.show_hints then
    local hints = require("leterejo.keymaps").hint_lines("envelopes", M.HINTS, width_of(buf) - 2)
    hint_height = #hints
    for _, h in ipairs(hints) do
      push(h, { { 0, #h, "LeterejoHeaderNote" } })
    end
  end

  if config.options.show_columns then
    push(render_columns(width))
  end

  for _, e in ipairs(state.envelopes or {}) do
    push(render_row(e, width))
  end

  -- Distinguish "not fetched yet" from "fetched and empty", and say when the
  -- list is still growing so a short list does not read as the whole mailbox.
  if state.envelopes == nil then
    push("  " .. lang.t("loading"), { { 0, 64, "LeterejoEmpty" } })
  elseif #state.envelopes == 0 then
    push(lang.t("empty"), { { 0, 64, "LeterejoEmpty" } })
  elseif growable() then
    if state.loading then
      push(lang.t("loading_more"), { { 0, 64, "LeterejoMore" } })
    elseif state.total and state.loaded >= state.total then
      push(lang.t("end_of_list"), { { 0, 64, "LeterejoMore" } })
    end
  end

  -- A buffer line cannot contain a newline, and one arriving from anywhere — a
  -- mailbox name, a filter string, a header we failed to clean — aborts the
  -- redraw and leaves the list unusable. Cheap enough to guarantee here.
  for i, line in ipairs(lines) do
    if line:find("[\r\n]") then
      lines[i] = line:gsub("[\r\n]", " ")
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  hl.paint(buf, marks)
end

-- Redraw without moving the cursor, for rows appended underneath it.
local function redraw_in_place(buf)
  local win = vim.api.nvim_get_current_win()
  local keep = vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_buf(win) == buf
    and vim.api.nvim_win_get_cursor(win)
    or nil

  redraw(buf)

  if keep and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_is_valid(win) then
    local last = vim.api.nvim_buf_line_count(buf)
    pcall(vim.api.nvim_win_set_cursor, win, { math.min(keep[1], last), keep[2] })
  end
end

-- The window showing the list, whichever window is current.
--
-- The preview fires from a timer, by which point the cursor may be anywhere,
-- and reading window zero would then measure the wrong one.
local function list_win(buf)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == buf then
      return w
    end
  end
  return nil
end

-- The envelope under the cursor, offset by the header rows.
local function envelope_under_cursor()
  local list = state.envelopes or {}
  local buf = find_buf()
  local win = buf and list_win(buf) or nil
  if not win then
    return nil
  end

  local index = vim.api.nvim_win_get_cursor(win)[1] - header_height()
  if index < 1 or index > #list then
    return nil
  end
  return list[index]
end

-- Put the cursor on a message rather than on the heading.
--
-- A fresh buffer starts at line one, which is the header, so nothing is under
-- the cursor until the user presses j — and the preview has nothing to show.
--
-- After a reload that nobody asked for, the cursor goes back to the message it
-- was on rather than to the top: rows that arrived above it must not carry the
-- reader off somewhere else.
local function place_cursor(buf)
  local win = list_win(buf)
  if not win or #(state.envelopes or {}) == 0 then
    return
  end

  local keep = M.keep_on
  M.keep_on = nil

  if keep then
    for i, e in ipairs(state.envelopes) do
      if tostring(e.id) == tostring(keep) then
        pcall(vim.api.nvim_win_set_cursor, win, { i + header_height(), 0 })
        return
      end
    end
  end

  local row = vim.api.nvim_win_get_cursor(win)[1]
  local first = header_height() + 1
  if row < first then
    pcall(vim.api.nvim_win_set_cursor, win, { first, 0 })
  end
end

-- Building the drawn list ----------------------------------------------------

-- Flatten the conversations held into the rows to draw.
--
-- Only called when the set of conversations or which are open changes. In
-- between, the operations edit `state.envelopes` directly so that a message
-- just trashed leaves the screen without another fetch.
local function rebuild()
  if not state.threads then
    return
  end

  local out = {}
  for _, t in ipairs(state.threads) do
    t.expanded = state.expanded[t.thread] ~= nil
    t.depth = nil
    table.insert(out, t)

    local kids = state.expanded[t.thread]
    if kids then
      for i, k in ipairs(kids) do
        k.depth = 1
        k.thread = t.thread
        k.last_child = i == #kids
        table.insert(out, k)
      end
    end
  end

  state.envelopes = out
end

-- Fetching -------------------------------------------------------------------

local function fetch_batch(account, mailbox, offset, limit, on_done)
  -- An order notmuch cannot give still has to arrive in some order before it
  -- can be put in another; it asks for newest-first and sorts afterwards.
  local sort = state.sorting()

  if state.query then
    return require("leterejo.search").run(account, mailbox, state.query.text, offset, limit, sort, on_done)
  end
  local query = notmuch.query_for(account, mailbox)
  if threaded() then
    return notmuch.list_threads(account, query, offset, limit, sort, on_done)
  end
  return notmuch.list_at(account, query, offset, limit, sort, on_done)
end

-- Ask for the next batch. Guarded so a burst of cursor movement cannot start
-- several fetches for the same rows.
local function load_more(buf)
  if state.loading or not growable() then
    return
  end
  if state.total and state.loaded >= state.total then
    return
  end

  local account, mailbox = state.account, state.mailbox
  local text = state.query and state.query.text
  state.loading = true

  fetch_batch(account, mailbox, state.loaded, config.options.chunk_size, function(ok, rows)
    state.loading = false

    -- Discard if we moved elsewhere, or the filter changed, while fetching.
    if state.account ~= account or state.mailbox ~= mailbox then
      return
    end
    if text ~= (state.query and state.query.text) then
      return
    end

    if not ok then
      return vim.notify(lang.t("prefix") .. tostring(rows), vim.log.levels.ERROR)
    end

    if #rows == 0 then
      -- A short batch is the end, whatever the count said.
      state.total = state.loaded
      return redraw_in_place(buf)
    end

    state.loaded = state.loaded + #rows

    if threaded() then
      vim.list_extend(state.threads or {}, rows)
      rebuild()
    else
      vim.list_extend(state.envelopes or {}, rows)
    end

    redraw_in_place(buf)
  end)
end

-- Start the list from nothing.
local function load_first(buf)
  local account, mailbox = state.account, state.mailbox

  state.reset_list()
  if threaded() then
    state.threads = {}
  else
    state.envelopes = nil
  end
  redraw(buf)

  -- The total arrives on its own; it is only needed for the heading, so the
  -- rows are not held up waiting for it.
  --
  -- A filter started while this was out would otherwise be labelled with the
  -- whole mailbox's total: the count is slow enough (a second, on a large
  -- mailbox) for that to be an ordinary sequence of keystrokes, not a race.
  notmuch.count(account, notmuch.query_for(account, mailbox), threaded(), function(ok, total)
    if ok and state.account == account and state.mailbox == mailbox and not state.query then
      state.total = total
      redraw_in_place(buf)
    end
  end)

  state.loading = true
  fetch_batch(account, mailbox, 0, config.options.chunk_size, function(ok, rows)
    state.loading = false

    if state.account ~= account or state.mailbox ~= mailbox then
      return
    end

    if not ok then
      state.envelopes = {}
      redraw(buf)
      return vim.notify(lang.t("prefix") .. tostring(rows), vim.log.levels.ERROR)
    end

    state.loaded = #rows
    if threaded() then
      state.threads = rows
      rebuild()
    else
      state.envelopes = rows
    end
    redraw(buf)

    -- A tall window can show more rows than one batch holds, and the cursor may
    -- never move far enough to ask for the rest.
    if #rows > 0 and #(state.envelopes or {}) < vim.api.nvim_win_get_height(0) then
      load_more(buf)
    end

    -- Nothing has moved the cursor, so the preview has had no reason to fire.
    place_cursor(buf)
    M.preview()
  end)
end

local function load_search(buf)
  local account, mailbox, text = state.account, state.mailbox, state.query.text
  local search = require("leterejo.search")

  local query = state.query
  state.reset_list()
  state.query = query
  redraw(buf)

  vim.notify(lang.t("searching", text), vim.log.levels.INFO)

  -- Same as the plain list: the total is only for the heading, so the rows do
  -- not wait for it. Without it a truncated result reads as the whole answer.
  search.count(account, mailbox, text, function(ok, total)
    if ok and state.query and state.query.text == text then
      state.total = total
      redraw_in_place(buf)
    end
  end)

  state.loading = true
  search.run(account, mailbox, text, 0, config.options.chunk_size, function(ok, res, info)
    state.loading = false

    if not ok then
      state.envelopes = {}
      redraw(buf)
      return vim.notify(lang.t("prefix") .. tostring(res), vim.log.levels.ERROR)
    end

    -- Discard if the filter was cleared or changed while waiting.
    if not state.query or state.query.text ~= text then
      return
    end
    if state.account ~= account or state.mailbox ~= mailbox then
      return
    end

    state.query.index = info and info.index
    state.query.scanned = info and info.scanned
    state.envelopes = res
    state.loaded = #res
    redraw(buf)
  end)
end

-- Read the whole list in, and put it in an order the index cannot give.
--
-- Counted first. Past the limit the answer is to say so and go back to date
-- order: sorting the part that happens to have been read would be a list
-- claiming an order it does not have, which is the one thing worse than not
-- offering the order at all. Filtering first is what makes these usable on a
-- large mailbox, and is usually the real question anyway.
local function load_whole(buf)
  local account, mailbox = state.account, state.mailbox
  local order = state.sorting()
  local text = state.query and state.query.text

  local query = state.query
  state.reset_list()
  state.query = query
  if threaded() then
    state.threads = {}
  end
  redraw(buf)

  -- Whether this is still the list that was asked for.
  local function ours()
    return state.account == account
      and state.mailbox == mailbox
      and (state.query and state.query.text) == text
      and state.sorting() == order
  end

  local function count(on_done)
    if text then
      return require("leterejo.search").count(account, mailbox, text, on_done)
    end
    return notmuch.count(account, notmuch.query_for(account, mailbox), threaded(), on_done)
  end

  count(function(ok, total)
    if not ours() then
      return
    end
    if not ok then
      state.envelopes = {}
      redraw(buf)
      return vim.notify(lang.t("prefix") .. tostring(total), vim.log.levels.ERROR)
    end

    local cap = config.options.sort_scan_limit or 2000
    if total and total > cap then
      vim.notify(lang.e("sort_too_many", total, cap), vim.log.levels.WARN)
      state.sort = "newest"
      return M.refresh()
    end

    if total == 0 then
      state.envelopes, state.total = {}, 0
      return redraw(buf)
    end

    vim.notify(lang.t("sort_reading"), vim.log.levels.INFO)
    state.loading = true

    -- A scan reports no total — it reads a slice and looks at it — so it is
    -- asked for its own limit and what comes back is what there is.
    local limit = total or config.options.suspicious_scan_limit or 5000

    fetch_batch(account, mailbox, 0, limit, function(ok2, rows, info)
      state.loading = false
      if not ours() then
        return
      end
      if not ok2 then
        state.envelopes = {}
        redraw(buf)
        return vim.notify(lang.t("prefix") .. tostring(rows), vim.log.levels.ERROR)
      end

      table.sort(rows, comparator(order))

      state.loaded, state.total = #rows, #rows
      if state.query then
        state.query.index = info and info.index
        state.query.scanned = info and info.scanned
      end

      if threaded() then
        state.threads = rows
        rebuild()
      else
        state.envelopes = rows
      end

      redraw(buf)
      place_cursor(buf)
      M.preview()
    end)
  end)
end

-- Redraw from what is already held, without fetching anything.
--
-- Used after an operation that changed a message: the row is corrected in place
-- so the screen answers at once, and the next refetch confirms it.
function M.redraw()
  local buf = find_buf()
  if buf then
    redraw(buf)
  end
end

-- Read the list again after something else fetched, without taking the reader
-- anywhere.
--
-- For the timer, which fires while the list is being read. Rows arriving above
-- the cursor would otherwise shift whatever is under it, so the message that
-- was under the cursor is put back under it. A filtered list is left alone
-- entirely: rebuilding a search someone is working through is not a courtesy.
function M.reload_quietly()
  local buf = find_buf()
  if not buf or state.query then
    return
  end

  local e = envelope_under_cursor()
  M.keep_on = e and e.id or nil

  state.reset_list()
  M.refresh()
end

-- Fetch what the server has, then read the list again.
--
-- Nothing arrives on its own yet, so this is the only thing that brings new
-- mail down. The list is read again either way: a sync that failed leaves the
-- index exactly as it was, which is still worth drawing.
function M.sync()
  local lieer = require("leterejo.lieer")
  local account = state.account

  if not lieer.configured(account) then
    state.reset_list()
    return M.refresh()
  end

  vim.notify(lang.t("syncing"), vim.log.levels.INFO)

  lieer.sync(account, function(ok, res, _, kind)
    -- `blocked` means lieer has already said why, in words that name the way
    -- out; saying it again in ours would only add a second prefix.
    if not ok and kind ~= "blocked" then
      vim.notify(lang.e("sync_failed", tostring(res)), vim.log.levels.WARN)
    end
    if state.account == account then
      state.reset_list()
      M.refresh()
    end
  end)
end

-- Refetch and redraw the list.
function M.refresh()
  local buf = find_buf()
  if not buf then
    return
  end

  -- An order the index cannot give is read in whole, filtered or not.
  if ordered_here() then
    return load_whole(buf)
  end
  if state.query then
    return load_search(buf)
  end
  return load_first(buf)
end

-- The preview ------------------------------------------------------------------

local preview_timer = nil

-- Show the row under the cursor below the list, without leaving the list.
--
-- Debounced: running down fifty rows should not fetch fifty bodies. Each
-- request carries a token so a slow one for a row already passed cannot land on
-- top of the row now under the cursor.
local function preview_now()
  if not previewing() then
    return
  end

  local e = envelope_under_cursor()
  if not e then
    return
  end
  if state.preview_id == e.id and require("leterejo.ui.message").find_win() then
    return -- already showing it
  end

  state.preview_token = state.preview_token + 1
  state.preview_id = e.id

  require("leterejo.ui.message").open(e, {
    focus = false,
    quiet = true,
    token = state.preview_token,
    where = preview_where(),
    ratio = config.options.preview_ratio,
  })
end

local function preview_soon()
  if not previewing() then
    return
  end
  if preview_timer then
    preview_timer:stop()
  end
  preview_timer = vim.defer_fn(preview_now, config.options.preview_delay or 90)
end

-- Refresh the preview from somewhere the cursor has not moved — a list that has
-- just been drawn, or a mailbox that has just been switched.
M.preview = preview_soon

-- Resizing -----------------------------------------------------------------

-- Which way the preview is arranged at the moment, or nil if there is none.
local function preview_arrangement(buf)
  local win = require("leterejo.ui.message").find_win()
  if not win then
    return nil
  end
  local list = list_win(buf)
  if not list then
    return nil
  end

  local lp = vim.api.nvim_win_get_position(list)
  local mp = vim.api.nvim_win_get_position(win)
  return mp[1] > lp[1] and "below" or "right"
end

local resize_timer = nil

-- Lay everything out again for a pane that changed shape.
--
-- Three things go stale at once, and all three are visible. The columns were
-- measured against the old width, so the subject is cut short on a pane that
-- just got wider. "auto" chose stacked or side by side for a shape the pane no
-- longer has. And the body was rendered by w3m to fit a window of another size,
-- which matters most for a table, since w3m lays those out to the width it was
-- given and nothing rewraps them afterwards.
local function relayout()
  local buf = find_buf()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  redraw(buf)

  -- Leave a body the reader opened deliberately alone. Only the preview, which
  -- put itself there, may be moved or taken away.
  if state.preview_id == nil then
    return
  end

  local message = require("leterejo.ui.message")
  local want, have = preview_where(), preview_arrangement(buf)

  if have and want ~= have then
    local win = message.find_win()
    if win and #vim.api.nvim_list_wins() > 1 then
      vim.api.nvim_win_close(win, true)
    end
    state.preview_id = nil
  end

  if not want then
    -- The pane is too small for two halves now.
    local win = message.find_win()
    if win and #vim.api.nvim_list_wins() > 1 then
      vim.api.nvim_win_close(win, true)
    end
    state.preview_id = nil
    return
  end

  -- Draw the body again at the width it now has.
  state.preview_id = nil
  M.preview()
end

local function relayout_soon()
  if resize_timer then
    resize_timer:stop()
  end
  resize_timer = vim.defer_fn(relayout, 120)
end

-- Conversations ---------------------------------------------------------------

-- The thread row the cursor is on or inside.
local function thread_at_cursor()
  local e = envelope_under_cursor()
  if not e or not e.thread then
    return nil
  end
  return e
end

local function collapse_thread()
  local buf = find_buf()
  if not buf or not threaded() then
    return
  end

  local e = thread_at_cursor()
  if not e or not state.expanded[e.thread] then
    return
  end

  -- Closing from a child would leave the cursor pointing at a row that is about
  -- to disappear, so put it on the parent first.
  local parent_row
  for i, row in ipairs(state.envelopes or {}) do
    if row.thread == e.thread and not row.depth then
      parent_row = i
      break
    end
  end

  state.expanded[e.thread] = nil
  rebuild()
  redraw(buf)

  if parent_row then
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(win) == buf then
      pcall(vim.api.nvim_win_set_cursor, win, { parent_row + header_height(), 0 })
    end
  end
end

local function expand_thread()
  local buf = find_buf()
  if not buf then
    return
  end
  if not threaded() then
    return vim.notify(lang.t("no_threads_here"), vim.log.levels.INFO)
  end

  local e = thread_at_cursor()
  if not e or state.expanded[e.thread] then
    return
  end

  if (e.thread_total or 1) <= 1 then
    return vim.notify(lang.t("thread_single"), vim.log.levels.INFO)
  end

  local account, thread = state.account, e.thread
  vim.notify(lang.t("thread_loading"), vim.log.levels.INFO)

  notmuch.thread_messages(account, thread, function(ok, msgs)
    if not ok then
      return vim.notify(lang.t("prefix") .. tostring(msgs), vim.log.levels.ERROR)
    end
    if state.account ~= account or not state.threads then
      return
    end

    state.expanded[thread] = msgs
    rebuild()
    redraw_in_place(buf)
  end)
end

-- Open or close the conversation under the cursor, whichever it is not.
local function toggle_thread()
  local e = thread_at_cursor()
  if e and state.expanded[e.thread] then
    return collapse_thread()
  end
  return expand_thread()
end

-- Keys ------------------------------------------------------------------------

local function setup_keymaps(buf)
  -- Attachments are reachable from the list too, without opening the body:
  -- notmuch already parsed the MIME tree when it indexed the file, so asking
  -- what a message carries costs nothing.
  local function attachments()
    local e = envelope_under_cursor()
    if not e then
      return
    end

    if e["has-attachment"] == false then
      return vim.notify(lang.e("no_attachments"), vim.log.levels.INFO)
    end

    local id = e.id
    vim.notify(lang.t("checking_attachments"), vim.log.levels.INFO)

    notmuch.attachments(state.account, id, function(ok, atts)
      if not ok then
        return vim.notify(lang.t("prefix") .. tostring(atts), vim.log.levels.ERROR)
      end

      require("leterejo.attachments").download_and_open(state.account, id, atts or {})
    end)
  end

  -- The two ways in: type one, or pick one. Each offers the other, so which
  -- key was pressed first does not matter.
  local filters

  -- Filtering. Everything is answered by the index, except the two markers it
  -- never saw, which are answered by reading the mailbox back.
  local function search()
    vim.ui.input({
      prompt = lang.t("search_prompt"),
      default = state.query and state.query.text or "",
    }, function(input)
      if input == nil then
        return -- cancelled
      end

      input = vim.trim(input)

      -- Nothing typed: offer the ones worth having on a key. Someone who
      -- pressed the filter key and then had nothing in mind is exactly who the
      -- list is for. Clearing has its own key.
      if input == "" then
        return filters()
      end

      state.query = { text = input }
      state.clear_selection()
      state.reset_list()
      M.refresh()
    end)
  end

  -- The filters worth having on a key rather than in the fingers.
  --
  -- Two of these cannot be typed usefully at all: the sender under the cursor
  -- is an address nobody wants to retype, and is:suspicious is not a query the
  -- index can answer — it is computed while drawing, so it has to be spelled
  -- exactly to be recognised.
  -- Two entries are not queries but choices about them.
  local WRITE, CLEAR = "\0write", "\0clear"

  filters = function()
    local items, query_of = {}, {}

    -- The query is shown as well as described: the description says what it is
    -- for, and the query itself teaches what to type next time.
    local function offer(query, description)
      local named = query ~= WRITE and query ~= CLEAR
      local line = named and (util.fit(query, 18) .. "  " .. description) or description
      table.insert(items, line)
      query_of[line] = query
    end

    for _, f in ipairs(config.options.filters or {}) do
      offer(f.query, f.label or (f.describe and lang.t(f.describe)) or "")
    end

    -- The sender under the cursor, by address where there is one.
    --
    -- A conversation row has no address: notmuch summarises a thread with
    -- display names alone. The name is still a real query — names are indexed
    -- too — so it is worth offering rather than leaving the entry out on
    -- exactly the rows the user is usually looking at.
    local e = envelope_under_cursor()
    local first = e and (e.from or {})[1] or nil
    local sender = first and (first.email or first.name)
    if sender and sender ~= vim.NIL and sender ~= "" then
      sender = tostring(sender)
      offer("from:" .. (sender:find("%s") and ('"' .. sender .. '"') or sender), lang.t("filter_from_here"))
    end

    offer(WRITE, lang.t("filter_write"))
    if state.query then
      offer(CLEAR, lang.t("filter_clear"))
    end

    require("leterejo.pickers").pick(items, lang.t("pick_filter"), function(line)
      local query = query_of[line]
      if query == nil then
        return
      end

      if query == WRITE then
        return search()
      end

      state.query = query ~= CLEAR and { text = query } or nil
      state.clear_selection()
      state.reset_list()
      M.refresh()
    end)
  end

  -- What an operation acts on: the rows picked out, or the one under the
  -- cursor when none are.
  --
  -- Nothing gets a second key for "do this to the selection". An action means
  -- the same thing either way, and a pair of keys for one verb is a pair to
  -- keep straight at the moment mail is being deleted.
  local function targets()
    local picked = state.selection()
    if #picked > 0 then
      return picked
    end
    local e = envelope_under_cursor()
    return e and { e } or {}
  end

  -- Put a tag on what is being acted on, or take one off.
  --
  -- The ones already carried are marked and listed first, so the same key both
  -- adds and removes without asking which is meant. A name that is not in the
  -- list yet can be typed: Gmail makes the label when the change is pushed, so
  -- there is nowhere else to create one.
  --
  -- With several messages in hand a tag has three states rather than two, and
  -- only "every one of them has it" counts as on: choosing a tag some of them
  -- carry puts it on the rest, which is the reading that lets one key make the
  -- selection agree.
  local function tag_message()
    local list = targets()
    if #list == 0 then
      return
    end

    local ids = {}
    for _, e in ipairs(list) do
      table.insert(ids, e.id)
    end

    notmuch.tags_of_many(state.account, ids, function(ok, union, shared)
      if not ok then
        return vim.notify(lang.t("prefix") .. tostring(union), vim.log.levels.ERROR)
      end

      local carried = {}
      for _, t in ipairs(union) do
        carried[t] = true
      end

      notmuch.tags(state.account, function(ok2, all)
        if not ok2 then
          return vim.notify(lang.t("prefix") .. tostring(all), vim.log.levels.ERROR)
        end

        local items, name_of = {}, {}

        local function offer(name)
          local mark = lang.t("tag_off")
          if shared[name] then
            mark = lang.t("tag_on")
          elseif carried[name] then
            mark = lang.t("tag_some")
          end

          local line = mark .. name
          table.insert(items, line)
          name_of[line] = name
        end

        -- What they already have, then everything else.
        for _, t in ipairs(union) do
          offer(t)
        end
        for _, t in ipairs(all) do
          if not carried[t] then
            offer(t)
          end
        end

        local NEW = "\0new"
        table.insert(items, lang.t("tag_new"))
        name_of[lang.t("tag_new")] = NEW

        local prompt = #list > 1 and lang.t("pick_tag_many", #list) or lang.t("pick_tag")

        require("leterejo.pickers").pick(items, prompt, function(lines)
          local add, remove, make_new = {}, {}, false

          for _, line in ipairs(lines) do
            local name = name_of[line]
            if name == NEW then
              make_new = true
            elseif name and shared[name] then
              table.insert(remove, name)
            elseif name then
              table.insert(add, name)
            end
          end

          local actions = require("leterejo.actions")
          local function go()
            if #list == 1 then
              return actions.change_tags(list[1], add, remove)
            end
            actions.many.change_tags(list, add, remove)
          end

          if not make_new then
            return go()
          end

          -- Ask for the new one, then send everything as a single change.
          vim.ui.input({ prompt = lang.t("tag_prompt") }, function(input)
            if input and vim.trim(input) ~= "" then
              table.insert(add, vim.trim(input))
            end
            go()
          end)
        end, { multi = true })
      end)
    end)
  end

  -- Pick the row under the cursor out, or put it back, and step down so a run
  -- of them can be taken with one key rather than two.
  local function select_row()
    local e = envelope_under_cursor()
    if not e then
      return
    end

    state.toggle_selected(e.id)
    M.redraw()

    local win = list_win(buf)
    if win then
      local row = vim.api.nvim_win_get_cursor(win)[1]
      if row < header_height() + #(state.envelopes or {}) then
        pcall(vim.api.nvim_win_set_cursor, win, { row + 1, 0 })
      end
    end
  end

  -- The same over the lines a motion covered.
  --
  -- The whole range goes one way rather than each row flipping: a range that
  -- already holds a mixture would otherwise come out as the opposite mixture,
  -- which is nobody's intention. Everything picked out means put it all back;
  -- anything else means pick it all out.
  local function select_range()
    -- '< and '> are only set once visual mode has been left, so leave it first.
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<esc>", true, false, true), "nx", false)

    local list = state.envelopes or {}
    local first = math.max(vim.fn.line("'<") - header_height(), 1)
    local last = math.min(vim.fn.line("'>") - header_height(), #list)
    if first > last then
      return
    end

    local all_picked = true
    for i = first, last do
      if not state.is_selected(list[i].id) then
        all_picked = false
        break
      end
    end

    for i = first, last do
      if all_picked or not state.is_selected(list[i].id) then
        state.toggle_selected(list[i].id)
      end
    end

    M.redraw()
  end

  local function select_key()
    local mode = vim.fn.mode()
    if mode == "v" or mode == "V" or mode == "\22" then
      return select_range()
    end
    return select_row()
  end

  -- Change the order the list is in.
  local ORDERS = { "newest", "oldest", "from", "subject" }

  local function pick_sort()
    local items, order_of = {}, {}

    for _, order in ipairs(ORDERS) do
      local line = (state.sorting() == order and lang.t("tag_on") or lang.t("tag_off"))
        .. lang.t("sort_" .. order)
      table.insert(items, line)
      order_of[line] = order
    end

    require("leterejo.pickers").pick(items, lang.t("pick_sort"), function(line)
      local order = order_of[line]
      if not order or order == state.sorting() then
        return
      end

      -- The selection is by message id, so it survives the reordering: the
      -- same rows are picked out, in another place on the screen.
      state.sort = order
      state.reset_list()
      M.refresh()
    end)
  end

  -- An action on the row under the cursor.
  local function on_row(fn)
    return function()
      local e = envelope_under_cursor()
      if e then
        fn(e)
      end
    end
  end

  -- An action on whatever is being acted on: the selection as one change, or
  -- the row under the cursor.
  local function act(name)
    return function()
      local picked = state.selection()
      if #picked > 0 then
        return require("leterejo.actions").many[name](picked)
      end

      local e = envelope_under_cursor()
      if e then
        require("leterejo.actions")[name](e)
      end
    end
  end

  require("leterejo.keymaps").apply(buf, "envelopes", {
    read = {
      desc = lang.t("desc_read"),
      handler = on_row(function(e)
        -- With the preview already showing it, <CR> means "let me work in it"
        -- rather than "fetch it". Stepping into the window is the whole action.
        local message = require("leterejo.ui.message")
        if previewing() and state.preview_id == e.id and message.find_win() then
          return vim.api.nvim_set_current_win(message.find_win())
        end
        message.open(e, { where = preview_where(), ratio = config.options.preview_ratio })
      end),
    },
    expand = { desc = lang.t("desc_expand"), handler = expand_thread },
    collapse = { desc = lang.t("desc_collapse"), handler = collapse_thread },
    toggle_thread = { desc = lang.t("desc_toggle_thread"), handler = toggle_thread },
    help = {
      desc = lang.t("desc_help"),
      handler = function()
        require("leterejo.ui.help").open("envelopes")
      end,
    },
    attachments = { desc = lang.t("desc_attachments"), handler = attachments },
    raw_headers = {
      desc = lang.t("desc_raw_headers"),
      handler = on_row(function(e)
        require("leterejo.ui.source").open(state.account, e.id, { headers_only = true })
      end),
    },
    raw_source = {
      desc = lang.t("desc_raw_source"),
      handler = on_row(function(e)
        require("leterejo.ui.source").open(state.account, e.id)
      end),
    },
    toggle_seen = { desc = lang.t("desc_toggle_seen"), handler = act("toggle_seen") },
    toggle_flagged = { desc = lang.t("desc_toggle_flagged"), handler = act("toggle_flagged") },
    trash = { desc = lang.t("desc_trash"), handler = act("trash") },
    archive = { desc = lang.t("desc_archive"), handler = act("archive") },
    spam = { desc = lang.t("desc_spam"), handler = act("spam") },
    move = { desc = lang.t("desc_move"), handler = act("move") },
    tag = { desc = lang.t("desc_tag"), handler = tag_message },
    mailbox = {
      desc = lang.t("desc_mailbox"),
      handler = function()
        require("leterejo.pickers").pick_mailbox()
      end,
    },
    account = {
      desc = lang.t("desc_account"),
      handler = function()
        require("leterejo.pickers").pick_account()
      end,
    },
    search = { desc = lang.t("desc_search"), handler = search },
    preview = { desc = lang.t("desc_toggle_preview"), handler = M.toggle_preview },
    filters = { desc = lang.t("desc_filters"), handler = filters },
    select = { desc = lang.t("desc_select"), handler = select_key, modes = { "n", "x" } },
    sort = { desc = lang.t("desc_sort"), handler = pick_sort },
    clear_search = {
      desc = lang.t("desc_clear_search"),
      handler = function()
        -- The selection first. It is the more recent thing to have wanted
        -- undone, and clearing the filter would take the rows it names off the
        -- screen with it — leaving a count in the heading for messages that are
        -- no longer anywhere to be seen.
        if next(state.selected) then
          state.clear_selection()
          return M.redraw()
        end

        if state.query then
          state.query = nil
          state.reset_list()
          M.refresh()
        end
      end,
    },
    refresh = {
      desc = lang.t("desc_refresh"),
      handler = function()
        -- Fetch first, then read again. Re-reading the index alone is what
        -- this used to do, and it can only ever show what the last sync
        -- brought down — press it after sending and the copy of your own
        -- message is not there, because nothing has been to the server.
        M.sync()
      end,
    },
    compose = {
      desc = lang.t("desc_compose"),
      handler = function()
        require("leterejo.compose").compose()
      end,
    },
    drafts = {
      desc = lang.t("desc_drafts"),
      handler = function()
        require("leterejo.compose").drafts()
      end,
    },
    reply = {
      desc = lang.t("desc_reply"),
      handler = on_row(function(e)
        require("leterejo.compose").reply(e)
      end),
    },
    reply_other = {
      desc = lang.t("desc_reply_other"),
      handler = on_row(function(e)
        require("leterejo.compose").reply_other(e)
      end),
    },
    forward = {
      desc = lang.t("desc_forward"),
      handler = on_row(function(e)
        require("leterejo.compose").forward(e)
      end),
    },
    close = {
      desc = lang.t("desc_close"),
      handler = function()
        vim.api.nvim_buf_delete(buf, { force = true })
      end,
    },
  })
end

-- Keys still listed at the top for anyone who turns show_hints back on.
-- Ordered by how often they are wanted: a narrow window drops from the end.
M.HINTS = {
  { "read", "hint_read" },
  { "reply", "hint_reply" },
  { "forward", "hint_forward" },
  { "compose", "hint_compose" },
  { "drafts", "hint_drafts" },
  { "toggle_seen", "hint_seen" },
  { "trash", "hint_trash" },
  { "archive", "hint_archive" },
  { "select", "hint_select" },
  { "search", "hint_search" },
  { "sort", "hint_sort" },
  { "filters", "hint_filters" },
  { "mailbox", "hint_mailbox" },
  { "tag", "hint_tag" },
  { "account", "hint_account" },
  { "attachments", "hint_attachments" },
  { "refresh", "hint_refresh" },
  { "close", "hint_close" },
  { "move", "hint_move" },
  { "toggle_flagged", "hint_flagged" },
  { "spam", "hint_spam" },
}

-- Ask for more rows once the cursor comes within reach of the end.
local function watch_cursor(buf)
  local group = vim.api.nvim_create_augroup("LeterejoCursor", { clear = true })

  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    group = group,
    desc = "leterejo: show the row under the cursor below the list",
    callback = preview_soon,
  })

  -- Not buffer-local: the pane can change shape while the cursor is in the
  -- body, and the list still has to be laid out again.
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = group,
    desc = "leterejo: lay the list and the preview out again after a resize",
    callback = relayout_soon,
  })

  vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled" }, {
    buffer = buf,
    group = group,
    desc = "leterejo: extend the list as it is scrolled",
    callback = function()
      if not growable() then
        return
      end

      local win = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_buf(win) ~= buf then
        return
      end

      -- Measure against the last visible line, not the cursor: scrolling with
      -- the mouse or Ctrl-E never moves the cursor at all.
      local bottom = vim.fn.line("w$")
      local rows = #(state.envelopes or {})
      if rows - (bottom - header_height()) <= config.options.chunk_lookahead then
        load_more(buf)
      end
    end,
  })
end

-- Open the list, reusing the buffer when one already exists.
function M.open()
  hl.setup()

  local buf = find_buf()

  if not buf then
    -- Listed, so it appears wherever buffers are listed. It is a place the
    -- reader goes back to, and one that cannot be reached from the buffer list
    -- has to be reached by remembering a command instead.
    buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(buf, BUFNAME)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "leterejo-envelopes"
    setup_keymaps(buf)
    watch_cursor(buf)
  end

  vim.api.nvim_win_set_buf(0, buf)
  vim.wo.wrap = false
  vim.wo.number = false
  vim.wo.relativenumber = false
  vim.wo.cursorline = true

  -- Do not draw here. refresh() draws "loading" itself, and drawing an empty
  -- state first would flash "no messages".
  M.refresh()
end

return M
