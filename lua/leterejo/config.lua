-- Defaults, merged with whatever the user passes to setup().
local M = {}

M.defaults = {
  -- Language of the interface: "en" or "ja". English by default.
  -- lang.extend() can add or override individual messages.
  lang = "en",

  -- Language of the words that go into the mail itself: the line above a
  -- quote, and the headers over a forwarded message.
  --
  -- Separate from the interface, because they are read by whoever receives the
  -- message rather than by the person writing it. English by default, which is
  -- what a header is conventionally written in.
  --
  -- The greeting a message opens with is not here: that is `templates`, and it
  -- is written by you.
  message_lang = "en",

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

  -- The order the list is drawn in.
  --
  --   "newest"   newest first
  --   "oldest"   oldest first
  --   "from"     by sender
  --   "subject"  by subject, with Re: and Fwd: ignored so a conversation and
  --              its replies land together
  --
  -- The first two are the index's own doing, so they cost nothing and hold for
  -- the whole mailbox however large. The other two are not: notmuch sorts by
  -- date and by nothing else, so ordering by sender means reading the list in
  -- whole and arranging it here — which is honest only while the list is small
  -- enough to read in. See sort_scan_limit.
  --
  -- This is the starting order; the `sort` key changes it for the list in front
  -- of you, the way a filter does, and switching mailbox keeps it.
  sort = "newest",

  -- How many messages may be read in to order them by sender or by subject.
  --
  -- Past this the order stays by date and the reason is said out loud, rather
  -- than sorting the part that happens to have been read and letting a list
  -- claim an order it does not have. Filtering first is what makes those orders
  -- usable on a large mailbox — and is usually what was wanted anyway: "in this
  -- account, by sender" is a question about a few hundred messages.
  sort_scan_limit = 2000,

  -- Which way an opened conversation reads.
  --
  --   "oldest"  oldest message first, the way a conversation happened
  --   "newest"  newest first, for following a long thread rather than
  --             reading it through
  thread_order = "oldest",

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
  --   send_only  : this account is only somewhere to send from, so do not
  --                offer it as somewhere to read. An account whose mail is not
  --                synced here has nothing of its own to show: switching to it
  --                would draw the same index under a different name
  --   templates  : how a new message opens, per kind. See templates below
  --   signature / signature_file : what a message ends with. See below
  --   sent_mailbox : where to keep a copy of what this account sends. See
  --                sent_mailbox further down
  --   unlock_command : how to open the password store for this account,
  --                e.g. { "pass", "show", "mail/work" }. See unlock_command
  --                further down for why this is worth setting
  --   lieer_dir  : the lieer repository for this account — the directory
  --                holding .gmailieer.json and the mail it fetched. Changes
  --                made here are pushed by running `gmi sync` in it
  --   notmuch_config : the notmuch configuration naming this account's index.
  --                One index per account: two accounts both have an `inbox`,
  --                and sharing an index would merge a message addressed to
  --                both into one entry carrying the union of their labels —
  --                which the next push would then offer to each of them
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

  -- How a new message opens, per kind: "compose", "reply", "forward".
  --
  -- A string (newlines and all) or a list of lines. Set per account in the
  -- accounts table to write differently from different addresses.
  --
  -- These are filled in before the buffer opens:
  --   {name}     the sender being replied to, by display name where there is
  --              one and address otherwise
  --   {email}    their address
  --   {subject}  the subject of the message being answered
  --   {date}     when it was sent
  --
  -- A greeting is the whole point of this in Japanese: 「{name} 様」 is how the
  -- message has to start, and typing it out every time is the work worth
  -- saving.
  templates = {},

  -- How the original appears inside a reply or a forward.
  --
  -- Everything here is optional; unset means the wording built in, written in
  -- `message_lang`. These lines are read by whoever receives the message, so
  -- they are worth writing yourself if the built-in wording is not how you
  -- would put it.
  --
  --   headline         the line above the quote. {date} {name} {email}
  --                    {address} {subject} are filled in, as in `templates`
  --   headline_no_name the same, for a message whose sender has no name
  --   prefix           what each quoted line begins with
  --   forwarded_head   the line that opens a forwarded message
  --   forwarded_headers which of the original's headers to list under it
  --   labels           what to call them
  --
  -- e.g. quote = {
  --        headline = "{date} に {name} さんは書きました:",
  --        prefix = "| ",
  --      }
  quote = {
    headline = nil,
    headline_no_name = nil,
    prefix = "> ",
    forwarded_head = nil,
    forwarded_headers = { "from", "date", "subject", "to", "cc" },
    labels = nil,
  },

  -- What every message ends with. A string, or a list of lines.
  --
  -- Put in the buffer under the "-- " delimiter mail has used for this since
  -- RFC 3676, rather than handed to himalaya's --signature: what is on the
  -- screen should be what is sent, and it can be edited before it goes.
  --
  -- signature_file names a file to read it from instead, for a signature kept
  -- outside the configuration. Both can be set per account.
  signature = nil,
  signature_file = nil,

  -- The signatures to choose between, by name. `signature` above is the one a
  -- message starts with; this is what the signature key offers instead.
  --
  -- e.g. signatures = {
  --        work = "Taro Yamada\nExample Co., Ltd.",
  --        short = "山田",
  --      }
  signatures = {},

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

  -- Filters offered on a key, so the common ones need not be typed.
  --
  -- `query` is what the filter actually is; `describe` names a message
  -- explaining it, and `label` overrides that with a string of your own. The
  -- query is shown beside the description, which is also how one learns what
  -- to type when the list is not enough.
  --
  -- is:suspicious and is:obfuscated are not queries notmuch can answer — the
  -- markers are computed while drawing, from invisible characters Xapian never
  -- indexed — so they are read back and examined. That is the one filter here
  -- that costs real time, and the header says how many were looked at.
  -- Gmail's tabs are labels like any other, and are kept when lieer has been
  -- told to stop dropping them (`gmi set --ignore-tags-remote ""`). They are
  -- offered here as one view rather than made the meaning of the inbox: the
  -- classification is Gmail's guess, and a default that hides two thirds of
  -- what arrived on someone else's guess is the one thing a local client
  -- should not do — there are no tabs on a list to notice it with.
  --
  -- The tags are `promotions` and the rest, not `CATEGORY_PROMOTIONS`: lieer
  -- renames Gmail's labels on the way in, the same way `STARRED` arrives as
  -- `flagged`. Written as a subtraction rather than `tag:personal`, because a
  -- message Gmail never classified carries no category at all — 7,404 of the
  -- 31,429 in one inbox here, which is mail from before the tabs existed and
  -- anything a filter delivered straight past them. The positive form drops
  -- those without saying so; this one keeps them.
  filters = {
    { query = "is:unread", describe = "filter_unread" },
    {
      query = "tag:inbox and not tag:promotions and not tag:updates "
        .. "and not tag:social and not tag:forums",
      describe = "filter_primary",
    },
    { query = "is:flagged", describe = "filter_flagged" },
    { query = "has:attachment", describe = "filter_attachment" },
    { query = "is:suspicious", describe = "filter_suspicious" },
    { query = "is:obfuscated", describe = "filter_obfuscated" },
    { query = "tag:spam", describe = "filter_spam" },
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
    -- Gmail's own sorting, when lieer has been told to keep it. These say
    -- which tab a message was filed under, which is a fact about it rather
    -- than a place to put one — and Gmail decides them, so putting one on by
    -- hand means offering Gmail a label it will disagree with.
    --
    -- lieer renames them on the way in: CATEGORY_PROMOTIONS arrives as
    -- `promotions`, the way STARRED arrives as `flagged`. Which means a label
    -- of your own called `personal` would land on the same tag as Gmail's tab
    -- and be hidden here with it — rename yours if that happens, since the
    -- collision is in the index and not something this can tell apart.
    "personal",
    "social",
    "promotions",
    "updates",
    "forums",
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
  --   interval     : minutes between fetches, or 0 for none. This is what
  --                  lieer made possible: mbsync needed a passphrase out of
  --                  gpg and so could not run unattended, while lieer holds an
  --                  OAuth token in a file and never touches gpg. The list
  --                  reloads afterwards without moving the reader, and a
  --                  filtered list is left alone
  lieer = {
    executable = "gmi",
    dir = nil,
    sync_on_write = true,
    interval = 0,
    timeout = 120000,
    retries = 2,
    retry_delay = 3000,
  },

  -- How to open the password store, when something needs a password.
  --
  -- himalaya reads the SMTP password from a command — `pass show ...` and the
  -- like — which asks gpg-agent, which runs pinentry when its cache is cold.
  -- pinentry-curses draws on GPG_TTY, and that is the terminal Neovim is
  -- holding: the prompt lands on top of the editor and the keys typed at it go
  -- to the editor. Nothing can be entered.
  --
  -- Naming the same command here lets the unlock happen in a terminal buffer
  -- instead, which has a terminal of its own for pinentry to use. What the
  -- command prints is discarded, since what it prints is the password.
  --
  -- For this to be reached at all, **himalaya's own password command must be
  -- unable to prompt**. gpg asked for a passphrase it does not have simply
  -- waits, so a send hangs instead of failing, and a failure is what brings us
  -- here. Take the prompt away from it in himalaya's configuration:
  --
  --   password.command = [
  --     "env", "PASSWORD_STORE_GPG_OPTS=--pinentry-mode cancel",
  --     "pass", "show", "mail/work" ]
  --
  -- `pass` hands that variable to gpg, which then fails at once with
  -- "Operation cancelled" rather than drawing over the editor. Measured: eight
  -- seconds and still waiting without it, exit 2 in under a second with it.
  --
  -- The command below is the opposite case and must *not* carry that option:
  -- it is the one that is supposed to ask.
  --
  -- Per account, set `unlock_command` in the accounts table above; this is the
  -- fallback. e.g. { "pass", "show", "mail/work" }
  unlock_command = nil,

  -- What domain the Message-ID carries.
  --
  --   "from"  the domain the message is sent from (the default)
  --   false   whatever himalaya put there
  --
  -- himalaya builds it from this machine's hostname, which is not a domain
  -- anyone can look up and does not match the sender. Nothing in SPF, DKIM or
  -- DMARC reads the Message-ID, so this is not why a message would fail any of
  -- them — but a receiving filter that compares it with From has one more
  -- reason to doubt the message, and every other client sends the two matching.
  --
  -- Correcting it means letting himalaya build the message and then sending
  -- that, which is one more local run of himalaya per message.
  message_id_domain = "from",

  -- Where a copy of a sent message is kept.
  --
  -- Per account, set `sent_mailbox` in the accounts table above; this is the
  -- fallback. Leave it unset for a provider that files sent mail itself —
  -- Gmail does so for anything sent through its own SMTP — because asking for
  -- both leaves two copies. Set it for a server that does nothing unless told,
  -- which is most of them.
  --
  -- Note that a copy in Sent is not the same as a copy in the inbox: a work
  -- machine collecting mail over POP3 sees the inbox and nothing else, so a
  -- Bcc to yourself is what reaches it. The two arrangements answer different
  -- questions and can both be used.
  sent_mailbox = nil,

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
    -- Path to a notmuch config, for accounts that do not name their own.
    -- nil uses notmuch's own default.
    --
    -- With more than one account, give each its own `notmuch_config` instead:
    -- an index holds one account's mail, and its tags are that account's
    -- labels. See the accounts table above.
    config = nil,

    -- Which mail the address suggestions are collected from, and how long a
    -- collection stays good for (seconds).
    --
    -- `notmuch address` walks every matching message — 18 seconds over 32,000
    -- here — so the answer is kept in a file and read from there. Nobody
    -- typing an address should wait for that, and a day-old list of people you
    -- have written to is not meaningfully worse than a fresh one.
    address_query = "date:2years..",
    address_max_age = 86400,

    -- Read the subject and sender from the message file rather than trust
    -- notmuch's decoding of them.
    --
    -- notmuch stops at the first RFC 2047 encoded word, so a header written in
    -- ISO-2022-JP — most Japanese mail — arrives cut off part way through: 22%
    -- of a recent sample here, and every attachment name that carries a
    -- parenthesis. Reading the file costs a few milliseconds per hundred
    -- messages. Set to false to take notmuch at its word.
    repair_headers = true,

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
      mailbox = "m", -- switch to another tag (what Gmail calls a label)
      tag = "t", -- put a tag on this message, or take one off
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
      -- Pick rows out to act on together. Every operation above works on the
      -- selection when there is one and on the row under the cursor when there
      -- is not, so nothing has a second key. Also bound in visual mode, where
      -- it takes the lines the motion covered.
      --
      -- Not <Space>: it is the leader in a common setup (LazyVim), and a
      -- buffer-local mapping of it with nowait fires before the second key can
      -- be typed — every <leader> mapping would stop working in the list. x is
      -- free here, since the buffer cannot be edited, and is what a checkbox
      -- gets ticked with elsewhere.
      select = "x",
      sort = "o", -- change the order the list is in
      preview = "p", -- stop the body following the cursor, or let it again
      refresh = "u", -- refetch
      drafts = "D", -- open a saved draft
      -- Not "\\": that is the local leader in a common setup (LazyVim), where
      -- pressing it waits for a second key and this never fires. "g" is
      -- already a prefix, so hanging this off it takes no single key away.
      filters = "g/", -- pick a filter instead of typing one
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
      address = "<leader>ha", -- suggest an address for the field under the cursor
      signature = "<leader>hg", -- choose which signature to end with
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
  --   markers : picked out / unread / flagged / attachment, one cell each
  --   date    : "MM-DD HH:MM" needs 11, "YYYY-MM-DD" needs 10
  --   from    : a Japanese company name runs past 24 more often than not, so
  --             widen this on a wide screen
  --   thread  : the count on a collapsed conversation, "v123"
  --
  -- The first marker cell stays blank until something is picked out, rather
  -- than appearing then: a column that arrives with the first selection would
  -- shift every subject one cell to the right at the moment the eye is on them.
  columns = {
    markers = 4,
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
