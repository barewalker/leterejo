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

**Writing is tagging.** `actions.lua` sets or clears a notmuch tag and then
runs `gmi sync` in the account's lieer repository. Marking read is `-unread`,
archiving is `-inbox`, trash and spam are `+trash` / `+spam` with the inbox
label taken off, and moving is relabelling: the chosen label on, the one being
looked at off. A mailbox is a tag now, so `query_for` answers `tag:"..."` and
the mailbox picker lists the tags in use rather than walking the tree for
Maildir folders; `folders` and `queries` on an account still name a directory or
spell out a query, which is what the Takeout archive needs.

Since the write path no longer needs an IMAP UID, `notmuch.uid_of`,
`cli.resolve_ids`, the `,U=` parsing and `err_archive_only` are gone, and with
them the rest of `cli.lua`'s write half. What is left of that file is sending
and the account list.

A sync that returns zero is not taken as success. lieer refuses to push onto a
remote that has moved on and the pull in the same run puts the old tags back, so
the tags are read again afterwards; if the change did not survive it is applied
once more against the state that just arrived, and only if that fails too does
the user hear about it and the list get read again. A sync meeting another `gmi`
fails at once rather than queueing (the lock is taken without waiting), so that
case is recognised by its message and retried after a pause.

**Replies and forwards are written here.** `message reply` wants the id the
backend uses — an IMAP UID — and what this holds is a Message-ID, which is all
notmuch can look a message up by, so replying never worked from the index. The
answer is assembled instead: the recipients from the original's headers, the
subject with one "Re:", the quote in the buffer where it can be cut down, and
`In-Reply-To` / `References` to keep it in its thread.

Encoding stays himalaya's. It builds the message from the fields as before, to
standard output rather than the wire; the two threading headers go in — they
are message ids, so there is no encoding to get wrong — and `message send`
takes the result back on standard input. A draft filed on the server goes the
same way through `message add`.

A forward carries the original below what the sender adds, headed by From,
Date, Subject and To. It does not carry attachments, and says so when the
message has any: himalaya's own forward would have, but that needs the
backend's id too.

**Fetching on a timer.** `lieer.interval` minutes, syncing each repository in
turn and reloading the list without moving the reader. This is what lieer made
possible and mbsync could not: mbsync needed a passphrase out of gpg, so it
could not run unattended.

Two smaller ones. `cli.warm_up` is gone: it ran `himalaya account list` before
the first list to get pinentry out of the way, and `account list` only
enumerates the configuration — it is unlikely to have read `pass` at all. Now
that reading never leaves the machine, the only thing reaching for a password is
sending, which the user asked for and can answer a prompt during. And the compose
buffer wrote `X-Sherpa-Account:` while sending read `X-Leterejo-Account:`, so the
header never matched and the account always fell back to the current one.

## What lieer does, measured

The write path is built on these, so they are worth keeping written down.

**The label map** (`lieer/local.py:36`, `translate_labels_default`):

    INBOX→inbox  UNREAD→unread  STARRED→flagged  IMPORTANT→important
    SENT→sent  DRAFT→draft  TRASH→trash  SPAM→spam

`CATEGORY_*` is ignored by default.

**`gmi sync` pushes first, then pulls** (`gmailieer.py:492`). A push onto a
remote that has moved on is refused:

    update: remote has changed, will not update (1914765 > 1914502)
    push: not all changes could be pushed, will re-try at next push.

and the pull that follows in the same run puts the old tags back — so the
promise to re-try is empty, because by then there is nothing left locally to
re-try. Measured: pull 1.8 s, push 2.2 s.

**Two syncs cannot overlap, and the second one says so.** lieer takes an
exclusive `fcntl` lock on `.lock` in the repository, and `sync`, `pull` and
`push` all take it without blocking (`local.py`, `load_repository`; only `send`
waits, which is not our path). A second one exits non-zero at once with
`failed to lock repository (probably in use by another gmi instance)`. The lock
is per repository, so separate accounts in separate trees still run in parallel.

**Never delete `.lock`.** The lock is released when the file descriptor closes,
so a crashed `gmi` leaves the file but not the lock, and there is nothing to
clean up. Deleting it is actively harmful: a running process holds the inode,
not the name, so a new `gmi` simply creates a fresh `.lock` and takes it — and
then both run at once with no exclusion at all. When a sync looks stuck, check
whether `rchar` in `/proc/<pid>/io` is still rising; with no progress output,
that is the only sign of life there is.

**`notmuch new` is not needed:** lieer registers what it fetched itself
(`local.py:615`).

**Empty `new.tags` before the first pull.** lieer reads notmuch's `new.tags`
and applies it to every file it registers, on top of the labels Gmail gave
(`local.py:694`). notmuch's default is `unread;inbox`, so a full pull here left
all 32,415 messages tagged `inbox` and 31,778 tagged `unread` — including 2,335
in `sent`, which cannot be in the inbox. The list is unusable that way, but the
real hazard is the push: a message whose local tags include a label Gmail does
not have offers that label on the next push, so archiving one old message would
have put it *into* the Gmail inbox and marked it unread.

Emptying `new.tags` only helps the next file. Correcting the ones already
written takes a second `gmi pull --force`: a partial pull only revisits what
changed on Gmail, and these had not. On the second pass the files exist, so
lieer takes the other branch — `tags.clear()`, then exactly the remote labels —
which is the only thing that reconciles them. It costs metadata alone;
`get_content` fetches only what is missing.

**One store, or the tags will disagree.** Reading three stores into one index
(a Takeout export, an mbsync tree, the lieer repository) produced two spellings
of every nested label — `WORK/Jobcan` from lieer, `WORK.Jobcan` from the
Maildir-hierarchy import — on the same messages, since notmuch merges by
Message-ID and tags belong to the message rather than the file. Deleting the
files does not remove the tags; only a pull that rewrites them does.

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
