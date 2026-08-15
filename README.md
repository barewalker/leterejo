# leterejo.nvim

A mail client for Neovim that reads from a local [notmuch][] index, changes
state by tagging, and sends through [himalaya][]. Mail is fetched by
[lieer][], which syncs a Maildir against Gmail over its API.

A list of fifty costs 37 ms and a body 10–20 ms, because nothing on the reading
path leaves the machine.

Japanese is a first-class case: the index is built for it, subjects and
attachment names are decoded here rather than trusted to notmuch, and a message
that arrives as HTML — over half of them here — is rendered before it is shown.

日本語版: [README.ja.md](README.ja.md)

## Who this is for

**Gmail, and someone willing to run a sync tool.** There is no IMAP path: mail
is on this machine or it is not readable. If you already use notmuch, this will
feel like putting a screen on it. If you do not, expect to spend half an hour
setting the underneath up — and see [What it does not do](#what-it-does-not-do)
before you decide.

```
       Gmail
         │  lieer (gmi sync — the API, both ways)
         ↓
   ~/Mail/<account>-lieer/mail/        one store per account
         │
         ↓  notmuch, one index per account
   leterejo ──→ notmuch    list, body, search, and every change of state
            └─→ himalaya   sending only
```

## Requirements

| | why |
|---|---|
| Neovim 0.10+ | `vim.system`, inline virtual text |
| [notmuch][] | the index everything is read from |
| [lieer][] (`gmi`) | fetches mail and carries changes back to Gmail |
| [himalaya][] v2 | sends |
| `w3m` (optional) | renders mail that has no plain-text part |
| [snacks.nvim][] (optional) | draws images the message carries |
| [fzf-lua][] (optional) | nicer pickers, and multiple selection when tagging |

## Setting up an account

`:checkhealth leterejo` reports what is missing at any point. Run it first, and
again after each step.

**1. Let leterejo prepare what it can.**

```vim
:LeterejoSetup work
```

That creates `~/Mail/work-lieer`, writes `~/.config/notmuch/work` naming it as
that account's index, creates the (empty) index, and prints the commands left
to run. Nothing is overwritten: it stops if either already exists.

**2. Authorise and fetch.** These need a browser and your Gmail password, so
they are yours to run:

```sh
cd ~/Mail/work-lieer
gmi init you@example.com
gmi auth                      # --noauth_local_webserver if the browser is elsewhere
gmi set --timeout 60          # the default is ten silent minutes
gmi set --no-remove-local-messages
gmi pull                      # everything, once. Allow an hour for 30,000
```

Run them through the wrapper `:LeterejoSetup` writes if you have more than one
account — the environment matters, and getting it wrong is silent. See
[Two things that fail silently](#two-things-that-fail-silently).

**3. Tell the plugin.**

```lua
require("leterejo").setup({
  accounts = {
    work = {
      email = "you@example.com",       -- himalaya v2 will not send without it
      lieer_dir = "~/Mail/work-lieer",
      notmuch_config = "~/.config/notmuch/work",
    },
  },
  lieer = { interval = 5 },            -- fetch every five minutes
})
```

himalaya needs its own configuration for sending; see [its
documentation][himalaya]. Only the sending half is used.

## Two things that fail silently

**`new.tags` must be empty.** lieer applies notmuch's `new.tags` to every file
it registers, on top of the labels Gmail gave. The default is `unread;inbox`,
which tags *everything* inbox and unread — and worse, a local tag Gmail does not
have is offered to Gmail on the next push, so archiving one old message would
put it back in the inbox. `:LeterejoSetup` writes an empty one.

**`XAPIAN_CJK_NGRAM=1` on every call, including lieer's.** Without it a run of
CJK is indexed as one term, so a word inside a longer one cannot be found —
and two-character words still work, which hides it. The plugin passes it; `gmi`
and `notmuch` run by hand need the wrapper.

## Keys

In the list:

| | |
|---|---|
| `<cr>` `r` `R` `f` `c` | read, reply, reply the other way, forward, write |
| `s` `F` | mark read or unread, flag |
| `e` `d` `S` | archive, trash, spam |
| `t` `M` | put tags on or take them off, move to another tag |
| `m` `a` | switch tag, switch account |
| `x` `o` | pick this row out (visual: the range), change the order |
| `/` `g/` `<esc>` | filter, pick a filter, clear the selection then the filter |
| `A` `D` | attachments, saved drafts |
| `p` `u` `?` `q` | preview on/off, fetch and reload, keys, close |
| `l` `h` `<tab>` | open, close, toggle a conversation |

Every action works on the rows picked out with `x` when there are any,
and on the row under the cursor when there are none — so there is no second key
for "do this to the selection". A change to fifty is one tagging call and one
push, not fifty syncs.

Order: newest and oldest first are the index's own doing and hold for a mailbox
of any size. By sender and by subject are not — notmuch sorts by date and
nothing else — so those read the list in whole and are refused past
`sort_scan_limit` rather than sorting the part that happened to have arrived.

Writing: `<leader>hs` sends, `<leader>hw` (or `:w`) saves the draft,
`<leader>hu` files it on the server, `<leader>ha` suggests an address,
`<leader>hg` picks a signature, `<leader>hq` discards. In the header area Enter
moves to the next field and `dd` clears one. A forward carries what the
original carried, in the Attach field.

## What it does not do

- **No IMAP.** Reading is the local index or nothing
- **The inbox is not Gmail's Primary tab**, and will not become it. It holds
  everything Gmail labels `INBOX`. To keep the tabs, `gmi set
  --ignore-tags-remote ""` and one full pull files them as ordinary tags, and
  `g/` offers a Primary-equivalent view — but a classifier's guess is a filter
  you reach for, not the default that decides what you never see
- **Nothing writes to Gmail except tagging and sending.** No filters, no
  settings, no delete-for-real

## Configuration

All of this is also `:help leterejo` once the plugin is installed.

Every option is documented where it is defined, in
[`lua/leterejo/config.lua`](lua/leterejo/config.lua). The ones most often
wanted:

| | |
|---|---|
| `lang` | `"en"` or `"ja"` — the interface |
| `message_lang` | the wording that goes *into* mail (quote lines, forward headers) |
| `templates`, `signature`, `signatures`, `quote` | what a new message opens with |
| `lieer.interval` | minutes between fetches; 0 for none |
| `sort`, `sort_scan_limit` | the order the list starts in, and how far the two orders notmuch cannot give may read |
| `preview`, `preview_min_width` | whether the body follows the cursor |
| `attachment_handlers` | how a saved attachment is opened |

## Design notes

[design-notes.md](design-notes.md) records how this was arrived at and what was
measured on the way, including the things that cost an evening: himalaya's
Maildir backend being slower than IMAP, Gmail's bandwidth limit, why the first
fetch is a full pull, and what lieer does when it refuses to push.

[notmuch]: https://notmuchmail.org/
[lieer]: https://github.com/gauteh/lieer
[himalaya]: https://github.com/pimalaya/himalaya
[snacks.nvim]: https://github.com/folke/snacks.nvim
[fzf-lua]: https://github.com/ibhagwan/fzf-lua
