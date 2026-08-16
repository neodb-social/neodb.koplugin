# NeoDB for KOReader

This plugin links the book you are reading in KOReader to a book edition on a NeoDB
server, then sync progress / notes / highlights / ratings, all without leaving the book.

## What's NeoDB

[NeoDB](https://neodb.net) is a free, open-sourced, distributed community, somewhat similar to Goodreads and
StoryGraph, but many such self-hosted servers that interconnected via open protocols like 
ActivityPub and ATProto. You may use NeoDB to share your reading journey with friends on 
Mastodon and Bluesky, or use it purely for private reading log, as NeoDB's privacy settings 
support both.

## Screenshots

| Link to a book | Rate and comment | Sync progress/highlights/etc |
|:---:|:---:|:---:|
| ![Link to a book](screenshots/link.png) | ![Rate and comment](screenshots/mark.png) | ![Options to sync highlights/etc](screenshots/options.png) |

## Install

### From a plugin store

If you use one of the community plugin managers, it is the easiest route, and it
handles updates afterwards. Both list this plugin: search for **NeoDB** and
install it.

- [Storefront](https://github.com/ultimatejimmy/storefront.koplugin)
- [AppStore](https://github.com/omer-faruq/appstore.koplugin)

### By hand

Download `neodb.koplugin.zip` from
[the latest release](https://github.com/neodb-social/neodb.koplugin/releases/latest)
and unzip it into KOReader's `plugins` directory. It already holds a correctly
named folder, so there is nothing to rename:

| Device | Path |
| --- | --- |
| Kobo | `.adds/koreader/plugins/` |
| Kindle | `koreader/plugins/` |
| Android | `koreader/plugins/` under internal storage |
| Desktop | `koreader/plugins/` next to the binary |

Restart KOReader. The plugin appears under **☰ → Tools → NeoDB**

For one-gesture access, bind **NeoDB: book actions** in
*Settings → Taps and gestures → Gesture manager*

## Signing in

Signing in is required, but just once. 
Open any book, then **☰ → Tools → NeoDB → Sign in to NeoDB…**.

### Scan a QR code (easiest)

The plugin shows a short link as a QR code; scan and sign in on your phone,
then tap **Done** on the reader.

This goes through a small pairing service on `p.neodb.net` ([source](https://github.com/neodb-social/portal)),
which is to help sign-in process and will not store any credentials after a few minutes.

If you would rather not involve a third party, point **Settings → Pairing
service** at your own deployment, or clear it to remove the option entirely.

### Enter a server address myself

The normal OAuth process, with no third party. Pick your instance, then choose one of:

**Authorize in a browser** — the plugin registers itself with the instance and
shows the authorization URL, as a QR code where available. You approve on
another device and type the code back.

**Type an access token** — if you would rather create one at
`https://your-instance/developer/`.

**Read a token from a file** — no typing. Save the token as the first line of a
text file named `neodb_token.txt`, copy it to your KOReader directory (or its
`settings/` subfolder) over USB, then pick this option.


## Linking a book

**NeoDB → This book → Find this book on NeoDB…** does the work:

1. If a valid ISBN can be found in the file's name or metadata, it searches for
   that. When the server confirms an entry with the same ISBN, the book is
   linked immediately.
2. Otherwise it searches by title and author and shows the matches, labelled
   with publisher and year so you can tell editions apart.
3. **Link by URL…** accepts a NeoDB book link, or a link from any site NeoDB can
   import from e.g. Goodreads, Google Books, Open Library, and Douban

The link is stored in the book's own sidecar metadata, so it survives a plugin
reinstall and travels with the file. It records which instance it came from, so
a link made on one server will not be used to post to another.

## Day to day

Everything is reachable from the book-actions sheet above, or from the menu:

- **The top row** names where the book stands, and opens the shelf list that
  changes it: Want to read / Reading / Finished / Dropped, and nothing else.
  Long-press it for the book-actions sheet. Before you have signed in or linked
  the book, that row offers the step you are missing instead of the shelves.
- **Update progress** — updates reading progress manually. See below.
- **Rate and comment** — rating from ½ to 5 starts, plus an optional comment.
- **Add note** — make a note, optionally stamped with your position.
- **Settings for this book** — what NeoDB knows about this edition, with a 
  **Show QR code** button to open the book's page on your phone.
- **Post something…** — a post about nothing in particular. See below.

To share a quote manually, select the text and choose **Share on NeoDB** from the
selection menu. The highlight is prefilled as a block quote with the cursor
after it, ready for your own thought, and your reading position is attached.

## Posting something

**NeoDB → Post something…** writes a plain post on your NeoDB account, with no
book attached to it. It is the one entry that needs neither a link nor an open
book, so it is there in the file browser too, and it can be bound to a gesture as
**NeoDB: post something**.

Who sees it is a button on the composer, and it opens on your **Default
visibility** setting:

| Visible to | Means |
|---|---|
| Public | Anyone, and listed in public timelines. |
| Unlisted | Anyone with the link, but kept out of public timelines. |
| Followers only | The people who follow you. |
| Private | Only you. |

Written offline, the post is queued and goes out with everything else.

## Sharing every highlight

Instead of picking quotes one at a time, a book can post each highlight as you
make it: **NeoDB → Settings for this book → [ ] Upload new highlights and notes automatically**.

- Only highlights made after you turn the switch on are posted, so turning it on
  never floods your timeline with a backlog. To send the backlog, use
  **NeoDB → Upload all highlights and notes…**.
- Uploads happen quietly in the background, 10 seconds after you stop editing.
  Offline, they queue like everything else.
- Deletions keep step. Delete a highlight and its NeoDB note goes too. One deleted
  before its post went out is never posted at all. Notes you posted on purpose,
  from the share composer or an export, stay.

The switch is offered when you link the book, and **Defaults for a new book →
Upload new highlights and notes** only decides which way it is offered; each book
keeps its own answer afterwards. **Crosspost shared highlights** decides whether
these notes also reach your followers on a connected Mastodon or Bluesky account.

## Using KOReader's own "Export highlights"

NeoDB registers itself as an export target, so it appears in **☰ → Tools → Export
highlights → Choose formats and services** next to Markdown, JSON and Readwise.
Tick it once, and it asks before turning on. Every one of the exporter's entry
points can then post to NeoDB, including all books in history and a
multi-selection in the file browser. This is the only path that reaches many books
at once, and the only one that works from the file browser. It also obeys the
exporter's own highlight style and colour filters.

- **Only linked books are posted from.** Unlinked ones are skipped and counted.
  Nothing goes looking for matches on its own.
- **Each highlight is still posted once.** The exporter re-sends everything on
  every run, but the plugin keeps its own record per book.
- Exporting posts from a linked book whether or not that book's own switch is on.
  The switch governs the automatic mirror; exporting is something you chose to do.
- KOReader exports to every enabled target at once, so an export to Markdown will
  also post to NeoDB, and will want a network connection. Untick NeoDB when you
  only want a file.
- A backlog larger than the 100-item queue goes out in runs. You are told how many
  are left, and the next export continues where the last one stopped.
- Needs KOReader **v2025.04** or newer. On older builds nothing appears, and
  **Upload all highlights and notes…** does the same job for one book.

## How progress is reported

NeoDB accepts a page number or a percentage. Which one is right depends on the
file, so the default (**Progress unit: Automatic**) decides per book:

| File | Reported as | Why |
| --- | --- | --- |
| PDF, DjVu, CBZ | page number | The page numbers are the book's own. |
| EPUB with a publisher page map | that page label | Real printed page numbers. |
| Other EPUB, FB2, MOBI… | percentage | Reflowed page numbers depend on your device, font and margins, so they would mean nothing to anyone else. |

You can override this per update with the **Unit** button in the progress
dialog, or globally in Settings.

A book you have not marked yet is put on **Reading** when you send progress, which
is what sending it implies. A book already marked, including *Finished* or
*Dropped*, is left exactly where you put it.

A book can also report on its own, every hour while you read and when it is
closed, whenever the position moved. That is **Update progress automatically**,
per book: offered when you link it, and changeable under **Settings for this
book**. It is queued quietly, so reading never waits on the network.

## Working offline

Marks, progress, notes and posts made offline are **queued**, and what you set is
shown straight away. The queue goes out the next time you are online:
automatically when you open a book, or on demand from **NeoDB → Uploads**, which
lists exactly what is waiting. Nothing here switches Wi-Fi on by itself.

- Repeated progress updates for one book collapse to the newest. Notes are each
  kept separately.
- An upload that can never succeed, such as one for a deleted entry, is discarded
  rather than blocking the queue behind it.
- Uploading **stops** instead when the trouble is the connection or your account,
  such as a refused login or a rate limit. Everything waits in order, and the
  **Uploads** row says why. A refused login is announced once, since it will not
  fix itself.
- The queue holds 100. When it is full it **refuses** new uploads rather than
  dropping old ones, so nothing already recorded is lost. A larger backlog goes
  out in runs, and you are told how many are still to go.

## Settings

| Setting | Default | Notes |
| --- | --- | --- |
| Default visibility | Public | Public / Followers only / Private. |
| Progress unit | Automatic | See the table above. |
| Crosspost to connected social networks | off | Marks and notes always reach NeoDB; this also crossposts them to your connected Mastodon and/or Bluesky account. |
| Quote highlights as block quotes | on | Prefixes shared highlights with `> `. |
| Pairing service | `p.neodb.net` | Used by QR sign-in. Clear it to hide that option. |
| Mark as Finished at the end of a book | off | Fires when you reach the last page of a linked book. |
| Crosspost shared highlights | off | Whether shared highlights also reach your followers. Separate from the crosspost row above. |
| Defaults for a new book → Update progress automatically | off | What the dialog offers when you link a book. |
| Defaults for a new book → Upload new highlights and notes | off | The same, for the highlight mirror. |

Neither row under **Defaults for a new book** does anything by itself. Both are
what the dialog below opens on, and your answer is written onto that book — so
changing a default later leaves the books you have already linked alone.

## When you link a book

Linking ends in one dialog, and it is the only place these three are asked
together:

- **the status** — preselected from whatever NeoDB already holds for the book, or
  **Reading** when it holds nothing;
- **Update progress** — this book reports where you are, on its own;
- **Upload highlights** — this book mirrors each new highlight and note.

There is no way past it but **Save**, because the other two are worthless without
the first: progress hangs off a status, so a book on no shelf cannot report any.
If you wanted none of it, **Settings for this book → Remove mark…**
undoes the status; the switches are on the same submenu.

Saving a status the server already had writes nothing and sends nothing.

Both switches can be changed at any time under **NeoDB → Settings for this
book**. A book you linked with an older version of this plugin has no answer
recorded, so it follows the global default until you touch its own switch.

## Technical notes and limitations

- **Your access token is stored in plain text** on the device. Anyone with the
  device, or with a backup of it, can read it. Revoke it on your NeoDB instance if
  you lose the device.
- Your device model may be sent to your instance, so posts can show something like
  "from Kobo" in some apps. Nothing else identifying is sent.
- Requests block KOReader's UI thread, and time out after 25 seconds.
- Posting a mark replaces it on the server, so every write resends the rating,
  comment and tags you already had. If you edit a mark on the web while the book
  is open, use **Refresh from NeoDB** before changing it here.
- When NeoDB merges two entries, the link follows the surviving one by itself.
- A shared highlight is posted once, as it stands 10 seconds after you last touch
  it. Editing it afterwards changes nothing on NeoDB, because KOReader does not
  announce an edit to a note's text. Deleting it does work, as above.
- A note posted by a version of this plugin from before note ids were recorded
  cannot be deleted from here.
- Renaming or deleting a book does not disturb anything waiting to upload: queued
  notes are addressed to the NeoDB entry, not to the file.

## Source code layout

| File | Contents |
| --- | --- |
| `main.lua` | Plugin lifecycle, menus, gestures, highlight hook, auto-sync events |
| `neodb_api.lua` | HTTP client, endpoint wrappers, upload queue transport |
| `neodb_store.lua` | Account, preferences, per-book link, queue persistence |
| `neodb_login.lua` | Instance picker and the sign-in flows |
| `neodb_match.lua` | Book identification, search UI, link management |
| `neodb_actions.lua` | Status, rating, progress, notes, quotes |
| `neodb_annotations.lua` | Mirroring KOReader's own highlights and notes to NeoDB |
| `neodb_exporter.lua` | NeoDB as a target in KOReader's "Export highlights" |
| `neodb_util.lua` | ISBN checksums, star rendering, JSON-null scrubbing, helpers |
| `spec/` | Tests. `./spec/run.sh` runs them under luajit, with KOReader stubbed. |

Two things to know before editing:

- KOReader bundles **luajson**, which has two traps that both bit this plugin on
  real hardware. It decodes JSON `null` to a sentinel *function* rather than
  `nil`, so responses go through `Util.scrubNulls`; and it encodes an empty table
  as the JSON object `{}` rather than `[]`, so list fields go through
  `Util.jsonArray` or are left out. The second one made NeoDB reject every mark
  with HTTP 422.
- Sibling modules are `neodb_`-prefixed because KOReader puts every plugin
  directory on one shared `package.path`, where a generic `api.lua` would collide
  with another plugin's.

