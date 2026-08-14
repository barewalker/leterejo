-- Defaults, merged with whatever the user passes to setup().
local M = {}

M.defaults = {
  -- Language of the interface: "en" or "ja". English by default.
  -- lang.extend() can add or override individual messages.
  lang = "en",

  -- The himalaya executable; a bare name is fine when it is on PATH.
  -- Only writing goes through it: reading comes from the notmuch index.
  executable = "himalaya",

  -- Account to open with. nil uses himalaya's default (default = true).
  account = nil,

  -- How many rows to add per batch while scrolling the list.
  --
  -- The list is one continuous run rather than pages. Paging only ever existed
  -- because a fetch over IMAP cost seconds; from the index a batch costs tens
  -- of milliseconds, so there is nothing to ration and a break at fifty is just
  -- an interruption. Rows are added as the cursor nears the end.
  chunk_size = 200,

  -- How close to the end the cursor has to come before the next batch is asked
  -- for. Large enough that the rows arrive before they are looked at.
  chunk_lookahead = 40,

  -- Group the list into conversations.
  --
  -- A collapsed row stands for the whole thread and carries its newest message,
  -- so replying or archiving from it behaves as expected. Expanding fetches the
  -- thread's messages, which is why it happens on a key rather than up front.
  --
  --   true    one row per conversation
  --   false   one row per message
  --
  -- A filtered list is always flat: a search result is the set of messages that
  -- matched, and folding them into conversations would hide the very rows the
  -- user asked for behind a collapsed parent.
  threads = true,

  -- Glyphs for the thread column. ASCII by default on purpose: the obvious
  -- alternatives (▸ ▾ ├ └) are East Asian Ambiguous, so they occupy one cell or
  -- two depending on the terminal and 'ambiwidth', and the columns come apart
  -- when the two disagree.
  thread_glyphs = {
    collapsed = ">",
    expanded = "v",
    child = "|-",
    last_child = "`-",
  },

  -- Per-account settings, keyed by the account name in himalaya's config.
  --
  --   email      : your own address on that account. Needed to fill From, and
  --                to drop yourself from a reply-all. himalaya's
  --                `account list` does not report addresses, so it goes here
  --   readonly   : refuse every operation that would modify mail
  --   lieer_dir  : the lieer repository for this account — the directory
  --                holding .gmailieer.json and the mail it fetched. Changes
  --                made here are pushed by running `gmi sync` in it
  --   folders    : mailbox name -> the directory a sync tool actually made,
  --                e.g. { inbox = "gmail/INBOX" }
  --   queries    : mailbox name -> a notmuch query, for views that are not one
  --                directory, e.g. { inbox = "tag:inbox" }
  --   query_for  : function(mailbox) -> notmuch query, when the two tables
  --                above are not enough
  --
  -- Empty by default. Anything named here is merged into what setup() is
  -- given, so a shipped example would appear in every user's account list.
  accounts = {},

  -- Default reply behaviour: "all" or "sender". Whichever is not the
  -- default remains available on its own key.
  reply_mode = "all",

  -- The tags standing for the states this plugin knows by name.
  --
  -- A mailbox is a tag and a change of state is a change of tag, because on
  -- Gmail a mailbox is a label. Marking read is `-unread`, archiving is
  -- `-inbox`, and deleting is `+trash` — there is no delete, and undoing one is
  -- taking the tag off again.
  --
  -- These are lieer's translation of Gmail's own labels (UNREAD, STARRED,
  -- INBOX, TRASH, SPAM), so they are set here for the case where a translation
  -- overlay changed them, not as a matter of taste.
  tags = {
    unread = "unread",
    flagged = "flagged",
    inbox = "inbox",
    trash = "trash",
    spam = "spam",
  },

  -- Tags that are not places, and so are not offered as mailboxes.
  --
  -- Every tag in the index is a mailbox, since that is what a Gmail label is —
  -- except the ones that describe a message rather than say where it is.
  -- Offering those would be offering to move mail into "unread".
  mailbox_hidden_tags = {
    "unread",
    "flagged",
    "attachment",
    "replied",
    "passed",
    "signed",
    "encrypted",
    "new",
  },

  -- Pushing what changed here up to Gmail.
  --
  --   dir          : the lieer repository, when one account covers everything.
  --                  Per account, set `lieer_dir` in the accounts table above.
  --                  Nothing is guessed: the index can span several
  --                  repositories, and picking the wrong one would push one
  --                  account's changes at another
  --   sync_on_write: run `gmi sync` after every change. With it off, changes
  --                  stay in the index until something else syncs
  --   timeout      : how long one sync may take (milliseconds)
  --   retries      : how many times to come back when another gmi holds the
  --                  repository. It takes the lock without waiting, so a sync
  --                  meeting a timer fails at once rather than queueing
  --   retry_delay  : how long to wait before coming back (milliseconds)
  lieer = {
    executable = "gmi",
    dir = nil,
    sync_on_write = true,
    timeout = 120000,
    retries = 2,
    retry_delay = 3000,
  },

  -- Where `upload` files a draft on the server, for reaching it from a phone
  -- or the webmail.
  --
  -- Per account, set `draft_mailbox` in the accounts table above; this is the
  -- fallback. The name goes through the account's [mailbox.alias] map in
  -- himalaya's own config, so a short "drafts" works where one is defined and
  -- anything else is passed verbatim ("Drafts", "[Gmail]/Drafts").
  --
  -- nil means the action reports that there is nowhere to put it. Drafts are
  -- kept on this machine either way, and that is what :w writes; this is the
  -- deliberate extra step, because IMAP can only append — each upload leaves
  -- another copy beside the last.
  draft_mailbox = nil,

  -- Whether to ask before moving a message to the trash.
  -- Archiving and reporting spam do not ask: both are easy to undo by hand.
  confirm_delete = true,

  -- How long to wait for one himalaya command (milliseconds).
  -- v2 renegotiates TCP+TLS+SASL every time, so a short limit fails healthy
  -- calls. Nothing on the reading path waits on this any more.
  timeout = 60000,

  -- Where to save attachments. nil saves to ~/Downloads.
  download_dir = nil,

  -- Draw images the message carries, in the message itself.
  --
  -- Only what is inside the message: an attachment, or a part the HTML refers
  -- to by `cid:`. Remote images are never fetched, and that is deliberate — the
  -- majority of images in bulk mail are one-pixel trackers whose only purpose
  -- is to report that the message was opened.
  --
  -- Needs snacks.nvim and a terminal that speaks the kitty graphics protocol.
  -- Without either, nothing is drawn and the attachment list reads as before.
  inline_images = true,

  -- How many lines an image may take. A banner would otherwise fill the window
  -- and push the text it belongs to off the bottom.
  inline_image_max_height = 12,

  -- The local notmuch index, which is where everything is read from.
  --
  -- The list, bodies, attachments and filtering all come from here, in tens of
  -- milliseconds. Nothing on this path touches the network: what the index
  -- holds is whatever the sync last put there.
  --
  -- XAPIAN_CJK_NGRAM=1 is always passed. Japanese search needs it at query
  -- time as well as when the index is built, and without it a word inside a
  -- run of Japanese cannot be found at all.
  notmuch = {
    executable = "notmuch",
    -- Path to a notmuch config. nil uses notmuch's own default.
    config = nil,

    -- How to turn a message that carries only HTML into something readable.
    -- More than half the mail here is of that kind, and without this it
    -- arrives as raw tags — which is also what himalaya did.
    -- Set to nil to keep the markup as is.
    html_renderer = { "w3m", "-dump", "-T", "text/html", "-cols", "100" },
  },

  -- Key bindings. Set one to false to leave that action unbound.
  keymaps = {
    -- The list buffer.
    --
    -- It is not modifiable, so single keys such as a and c are free to use —
    -- the convention mutt and aerc follow. which-key only appears after
    -- <leader>, so a hint line is kept on screen instead.
    envelopes = {
      read = "<cr>", -- open the message under the cursor
      reply = "r", -- reply, per reply_mode
      reply_other = "R", -- reply the other way (all <-> sender)
      forward = "f", -- forward
      compose = "c", -- write a new message
      account = "a", -- pick an account
      mailbox = "m", -- pick a mailbox
      search = "/", -- filter
      clear_search = "<esc>", -- clear the filter
      -- Not g: that is a prefix, so binding it alone would break gg.
      attachments = "A", -- save and open attachments
      toggle_seen = "s", -- mark read or unread
      toggle_flagged = "F", -- add or remove the flagged mark
      trash = "d", -- move to the trash mailbox
      archive = "e", -- move to the archive mailbox
      spam = "S", -- move to the spam mailbox
      move = "M", -- move to a mailbox you pick
      refresh = "u", -- refetch
      drafts = "D", -- open a saved draft
      -- l and h do nothing useful in a list of fixed-width rows, so they open
      -- and close the conversation instead. <Tab> toggles.
      expand = "l",
      collapse = "h",
      toggle_thread = "<tab>",
      help = "?", -- list the keys
      close = "q",
    },

    -- The message buffer; also not modifiable, so single keys suffice.
    message = {
      reply = "r", -- reply, per reply_mode
      reply_other = "R", -- reply the other way (all <-> sender)
      forward = "f", -- forward
      attachments = "A", -- save and open attachments (g would break gg)
      toggle_headers = "h", -- toggle the folded headers
      toggle_seen = "s", -- mark read or unread
      toggle_flagged = "F", -- add or remove the flagged mark
      trash = "d", -- move to the trash mailbox
      archive = "e", -- move to the archive mailbox
      spam = "S", -- move to the spam mailbox
      move = "M", -- move to a mailbox you pick
      toggle_wrap = "w", -- wrap long lines, or scroll sideways past a table
      help = "?", -- list the keys
      close = "q",
      close_alt = "<esc>",
    },

    -- The compose buffer.
    -- Prose is typed here, so single keys are not available.
    --
    -- Sending has a key of its own and nothing else does it. :w saves the
    -- draft, which is what writing means everywhere else in the editor.
    compose = {
      send = "<leader>hs", -- send
      save = "<leader>hw", -- save the draft here (:w does the same)
      upload = "<leader>hu", -- put a copy of the draft in the server's Drafts
      discard = "<leader>hq", -- discard
    },
  },

  -- Whether to keep the available keys listed at the top of the screen.
  --
  -- Off: it costs two or three rows of every screen forever to teach something
  -- learnt once, and pushes the mail down. The `help` key shows the same list
  -- in a floating window when it is actually wanted.
  show_hints = false,

  -- Whether to name the columns above the list.
  show_columns = true,

  -- Keep the body of the row under the cursor on screen beside the list.
  --
  -- A body costs tens of milliseconds from the index, so it can simply be
  -- there. Following the cursor over IMAP would have meant a two-second fetch
  -- per row, which is why this could not exist before.
  --
  --   "auto"    pick by the shape of the pane (below)
  --   "below"   list on top, body underneath
  --   "right"   list on the left, body on the right
  --   true      the same as "auto"
  --   false     never; <CR> opens the body as before
  --
  -- "auto" reads the pane rather than the terminal, so a tall split inside
  -- herdr or tmux stacks while the same session full-screen sits side by side.
  -- Side by side is preferred when there is width for two readable columns;
  -- failing that, stacked if there is height for two readable halves; failing
  -- both, no preview, because a split neither half can be read in helps nobody.
  preview = "auto",

  -- The thresholds "auto" decides on, in cells.
  --
  -- Width is the whole pane, so 160 means two columns of eighty — about the
  -- narrowest a wrapped message reads well in. Height is the whole pane too.
  preview_min_width = 160,
  preview_min_height = 30,

  -- How much of the pane the preview takes when the split is made.
  preview_ratio = 0.5,

  -- How long the cursor has to settle before the body is fetched, in
  -- milliseconds. Scrolling through fifty rows should not fetch fifty bodies.
  preview_delay = 90,

  -- Column widths, in display cells. The subject takes whatever is left.
  --
  --   markers : unread / flagged / attachment, one cell each
  --   date    : "MM-DD HH:MM" needs 11, "YYYY-MM-DD" needs 10
  --   from    : a Japanese company name runs past 24 more often than not, so
  --             widen this on a wide screen
  --   thread  : the count on a collapsed conversation, "v123"
  columns = {
    markers = 3,
    date = 11,
    from = 24,
    thread = 4,
  },

  -- Addresses to Bcc automatically.
  --
  -- Keyed either by account name or by the address in From, and the address
  -- wins. That matters when the two differ: sending as a work address through
  -- another provider's server should still keep the work copy, whichever route
  -- the message took.
  --
  -- Useful where the sent folder is unavailable — quota-constrained servers,
  -- or a workflow that already keeps copies elsewhere. The copy arrives in the
  -- inbox like any other message.
  -- e.g. { work = "you@work.example" }, or { ["you@work.example"] = "you@work.example" }
  auto_bcc = {},

  -- How many envelopes `is:suspicious` reads back to look at.
  --
  -- The suspicion mark is computed while drawing, not indexed, so there is no
  -- query for it — the mailbox has to be read and examined. The header reports
  -- how many were seen, so a capped answer does not read as a complete one.
  suspicious_scan_limit = 5000,

  -- Whether to fold headers down to the interesting ones when opening a body.
  -- Dozens of Received: lines otherwise push the body off the screen.
  fold_headers = true,

  -- Whether to wrap long lines in the body.
  --
  --   "auto"  wrap, unless the body looks laid out in columns
  --   true    always wrap
  --   false   never wrap; scroll sideways
  --
  -- w3m honours the width it is given for prose but not for a table, so a wide
  -- one comes back two or three times the window and wrapping destroys it.
  -- "auto" tells a table from a long URL by the runs of two spaces that pad a
  -- table into columns. The `toggle_wrap` key overrides it per message.
  message_wrap = "auto",

  -- Headers kept visible when folding. Lower case.
  visible_headers = {
    "from",
    "to",
    "cc",
    "bcc",
    "reply-to",
    "subject",
    "date",
  },

  -- How to open attachments, listed per MIME type.
  --
  -- Two or more handlers prompt for a pick; a single one runs directly. An
  -- unmatched type falls back to the major type ("image/*"), then to "*".
  --
  -- A handler may set:
  --   label     : name shown when picking
  --   cmd       : command to run; the saved path is appended
  --   mode      : how to launch it (below)
  --   direction : "right" | "down"  split direction (herdr / tmux)
  --   ratio     : split size (herdr / tmux)
  --   focus     : whether to follow the new pane (herdr / tmux); off by default
  --   run       : function(path, info) — for anything the above cannot express
  --
  -- mode is one of:
  --   "save"       save only; launch nothing
  --   "herdr"      run in a new herdr pane
  --   "tmux"       run in a new tmux pane
  --   "terminal"   run in a terminal window inside Neovim
  --   "fullscreen" hand the screen over and wait for it to exit
  --   "detach"     launch in the background (for tools opening their own window)
  --
  -- Note: tools relying on kitty's graphics protocol (some image viewers among them)
  -- cannot display inside Neovim, which owns the alternate screen and redraws
  -- over them. Send those to an outside pane with "herdr" or "tmux".
  -- Saving is the only thing that can be assumed to work everywhere, so it is
  -- the whole default. A worked example with a viewer is in the README.
  attachment_handlers = {
    ["*"] = { { label = "Just save", mode = "save" } },
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

-- Whether the given account is read-only.
function M.is_readonly(account)
  if not account then
    return false
  end
  local a = M.options.accounts[account]
  return a ~= nil and a.readonly == true
end

return M
