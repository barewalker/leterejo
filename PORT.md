# Porting from Sherpa

This tree is Sherpa renamed, nothing more. Sherpa grew around constraints that
no longer hold, and the point of restarting is to remove what those constraints
left behind rather than carry it forward.

Delete this file when the list is empty.

## What changed underneath

| | Sherpa assumed | Leterejo assumes |
|---|---|---|
| Reading | some accounts over IMAP, some local | **always the local notmuch index** |
| Syncing | mbsync, fetching in UID order | **lieer, over the Gmail API** |
| Writing | himalaya over IMAP, needing an IMAP UID | **`notmuch tag` then `gmi sync`** |
| Sending | himalaya | himalaya (unchanged, and the reason it stays) |
| Waiting | seconds per operation, hidden by a cache | tens of milliseconds, nothing to hide |

Measured on the way here: a list of fifty went 2,100 ms → 37 ms, a body from
seconds to 10–20 ms, and a full sync from three days on mbsync to about seventy
minutes on lieer. `design-notes.md` §13 has the numbers.

## To remove

**`cache.lua`, entirely.** It existed to hide the two seconds himalaya spent
reconnecting. Callers: `ui/envelopes.lua`, `ui/message.lua`, `actions.lua`,
`compose.lua`, `init.lua`, `cli.lua`. Also drop `persist_cache` from the
configuration and the `bypass()` dance inside the module.

**Paging.** `page_size`, `next_page`, `prev_page`, `state.page`,
`state.reset_page`, the `(page N)` in the heading, and the paged branch of
`load_page`. A local index has no reason to break at fifty. `list_envelopes`
takes a page number only because himalaya did.

**The IMAP UID.** `notmuch.uid_of`, `cli.resolve_ids`, and the `,U=<n>` filename
parsing. lieer names files by the Gmail message id, so there is no UID to
recover, and none is needed once writing goes through tags.

**`err_archive_only`.** It said a message could be read but not changed, which
was true only of Takeout mail with no UID. Under lieer every message can be
changed.

**`local_mail`, and everything that branches on it.** `cli.can_thread`,
`notmuch.is_local`, and the `"auto"` arms of `continuous`, `threads` and
`preview` that ask whether reading is local. It always is.

**Most of `cli.lua`.** Reading already goes to notmuch. Once writing goes to
tags, what remains of the himalaya layer is sending, and `compose.lua` can call
it directly.

## To add

**Writing through tags.** `actions.lua` currently resolves a UID and calls
`himalaya flag`/`message move`. It should set or clear a notmuch tag and then
run `gmi sync`.

The mapping lieer uses (`lieer/local.py`):

    INBOX→inbox  UNREAD→unread  STARRED→flagged  IMPORTANT→important
    SENT→sent  DRAFT→draft  TRASH→trash  SPAM→spam

So: mark read is `-unread`, archive is `-inbox`, trash is `+trash`, spam is
`+spam`, flag is `+flagged`.

**`sync`, not `push`.** lieer refuses to push when the remote has moved on:

    update: remote has changed, will not update (1914765 > 1914502)

That is a correct conflict guard, and it means the write path must pull first.
`gmi sync` does both. Measured: pull 1.8 s, push 2.2 s.

**A timer.** Nothing fetches mail on its own yet, which is why new mail did not
appear. lieer holds an OAuth token in a file and never touches gpg, so unlike
mbsync it can run unattended — this is what §6-1 of the design notes was
blocked on.

Set `gmi set --timeout 60` first. The default is 600, and a stalled request
hangs silently for ten minutes; that happened here.

## To keep

These were measured or paid for and are the reason this is worth continuing.

- **`XAPIAN_CJK_NGRAM=1` on every call.** Without it a run of CJK indexes as one
  term, so a word inside a longer one cannot be found — and two-character words
  still work, which hides it. The most-starred notmuch plugin for Neovim does
  not pass it at all.
- **Invisible characters, in two tiers.** A direction control means the sender
  on screen is not the sender that was sent; zero-width padding is ordinary in
  bulk mail. Measured over 3,000 messages: 950 carried something invisible, 915
  of those from one spam domain, exactly 2 carried an override. One marker for
  both fires on a third of the inbox and means nothing.
- **HTML through w3m, and the wrap heuristic.** w3m honours the width it is
  given for prose but not for a table, so wrapping destroys tables. A table row
  carries a dozen runs of two spaces and a long URL carries none.
- **The list**: one continuous list, conversations, colour by linked highlight
  groups, column names, the preview that follows the cursor and arranges itself
  by the shape of the pane.
- **Images the message carries, and never the remote ones.**
- **`:checkhealth`**, including the cell-size check — a terminal reporting no
  pixel size makes images fail silently, and nothing else says so.
