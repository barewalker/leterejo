# Porting from Sherpa

This tree began as Sherpa renamed. Sherpa grew around constraints that no longer
hold, and the point of restarting is to remove what those constraints left
behind rather than carry it forward.

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

## Done

**Reading is always the local index.** `cache.lua` is gone, and with it
`persist_cache` and the draw-then-catch-up dance. So is paging: `page_size`,
`continuous`, `state.page`, the `(page N)` in the heading and the `]` / `[` keys.
So is `local_mail` and everything that branched on it — `notmuch.is_local`,
`cli.can_thread`, and the `"auto"` arms that asked whether reading was local.
The screen calls notmuch directly, so the read half of `cli.lua` went with it
(`list_envelopes`, `list_threads`, `read_message`, `fetch_structure`,
`list_attachments`, `download_attachments`, `list_mailboxes`, `count_envelopes`).
Filtering no longer has a server-search or a scan-locally path, only the index
and the two `is:` filters the index cannot answer.

Two smaller ones. `cli.warm_up` is gone: it ran `himalaya account list` before
the first list to get pinentry out of the way, and `account list` only
enumerates the configuration — it is unlikely to have read `pass` at all. Now
that reading never leaves the machine, the only thing reaching for a password is
sending, which the user asked for and can answer a prompt during. And the compose
buffer wrote `X-Sherpa-Account:` while sending read `X-Leterejo-Account:`, so the
header never matched and the account always fell back to the current one.

## To remove

**The IMAP UID.** `notmuch.uid_of`, `cli.resolve_ids`, the `,U=<n>` filename
parsing and `err_archive_only`. lieer names files `<Gmail id>:2,<flags>`, so
there is no UID in them to recover — every message would report itself as
archive-only. Goes together with the write path below, which is what still
calls it.

**What is left of `cli.lua`.** Sending, and `list_accounts` because himalaya's
configuration is still where accounts are declared. `compose.lua` can call it
directly.

## To add

**Writing through tags.** `actions.lua` resolves a UID and calls
`himalaya flag` / `message move`. It should set or clear a notmuch tag and then
run `gmi sync`.

The mapping lieer uses (`lieer/local.py:36`, `translate_labels_default`):

    INBOX→inbox  UNREAD→unread  STARRED→flagged  IMPORTANT→important
    SENT→sent  DRAFT→draft  TRASH→trash  SPAM→spam

So: mark read is `-unread`, archive is `-inbox`, trash is `+trash`, spam is
`+spam`, flag is `+flagged`. `CATEGORY_*` is ignored by default.

**`sync`, not `push`.** `gmi sync` pushes first and then pulls
(`gmailieer.py:492`). lieer refuses to push when the remote has moved on:

    update: remote has changed, will not update (1914765 > 1914502)
    push: not all changes could be pushed, will re-try at next push.

**A rejected push loses the change.** Measured on the Sherpa side: tag, push
rejected, then the pull that follows brings the old tag back — and lieer's
promise to "re-try at next push" is empty, because by then there is nothing left
locally to retry. So a write is not done when `gmi sync` returns zero: the tag
has to be read back and the write reissued if it did not stick.

Measured: pull 1.8 s, push 2.2 s.

**Two syncs cannot overlap, and the second one says so.** lieer takes an
exclusive `fcntl` lock on `.lock` in the repository, and `sync`, `pull` and
`push` all take it without blocking (`local.py`, `load_repository`; only `send`
waits, which is not our path). A second one exits non-zero at once with
`failed to lock repository (probably in use by another gmi instance)`. That is
the shape we want — a timer firing while a write is syncing fails visibly
instead of queueing up — so the write path should recognise that string and
retry shortly rather than report it to the user as a failure. The lock is per
repository, so separate accounts in separate trees still run in parallel.

**Never delete `.lock`.** The lock is released when the file descriptor closes,
so a crashed `gmi` leaves the file but not the lock, and there is nothing to
clean up. Deleting it is actively harmful: a running process holds the inode,
not the name, so a new `gmi` simply creates a fresh `.lock` and takes it — and
then both run at once with no exclusion at all. When a sync looks stuck, check
whether `rchar` in `/proc/<pid>/io` is still rising; with no progress output,
that is the only sign of life there is.

**Reply and forward, assembled here.** `compose.lua` hands `envelope.id` (a
Message-ID) to `himalaya message reply <id>`, which wants an IMAP UID. This is
the same shape as the attachment bug Sherpa hit and fixed
(`sherpa: Invalid message UID '004d01dc74a2$...'`), so reply and forward have
been broken for local reading and simply went unused. Under lieer they need no
UID at all: the original is in the index, so the quote, `In-Reply-To` and
`References` can be built here and handed to `message compose --send`.

**A timer.** Nothing fetches mail on its own yet, which is why new mail did not
appear. lieer holds an OAuth token in a file and never touches gpg, so unlike
mbsync it can run unattended — this is what §6-1 of the design notes was
blocked on.

Set `gmi set --timeout 60` first. The default is 600, and a stalled request
hangs silently for ten minutes; that happened here. Note also that lieer prints
no progress when its output is not a terminal, so a timer cannot tell a running
sync from a stuck one by reading it, and that `--limit` cannot be combined with
removing local messages — run it with `--no-remove-local-messages`.

`notmuch new` is not needed: lieer registers what it fetched itself
(`local.py:615`).

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
