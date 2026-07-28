# NeoDB for KOReader

Link the book you are reading to an entry on a [NeoDB](https://neodb.net)
instance, then set its reading status and progress and share notes, quotes and
ratings — without leaving the book.

```
┌─────────────────────────────────┐
│       The Dispossessed          │
│        Reading  ★★★½            │
├────────────────┬────────────────┤
│  Want to read  │  ✓ Reading     │
├────────────────┼────────────────┤
│  Finished      │  Dropped       │
├────────────────┴────────────────┤
│  Progress: 25%                  │
├────────────────┬────────────────┤
│  Rate & comment│  Add note      │
├────────────────┼────────────────┤
│  Book details  │  Refresh       │
└────────────────┴────────────────┘
```

## Install

Download [the latest release](https://github.com/neodb-social/neodb.koplugin/archive/main.zip),
unzip, rename the folder to `neodb.koplugin` and copy it into KOReader's `plugins` directory:

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
  changes it: Want to read / Reading / Finished / Dropped. Long-press it for the
  book-actions sheet.
- **Update progress** — pre-filled with where you actually are. See below.
- **Rate and comment** — half-star rating from ½ to 5 starts, plus an optional comment.
- **Add note** — a note against the book, optionally stamped with your position.
- **Book details** — what NeoDB knows about this edition, with a **Show QR code**
  button to open the book's page on your phone.

To share a quote, select the text and choose **Share on NeoDB** from the
selection menu. The highlight is prefilled as a block quote with the cursor
after it, ready for your own thought, and your reading position is attached.

## Sharing every highlight

Rather than picking quotes one at a time, a book can post them all as you make
them: **NeoDB → This book → Upload new highlights and notes**. Each highlight or
note you make in that book then becomes a NeoDB note — the passage, whatever you
wrote about it, the chapter as the title, and the position it was made at.

- What the book already holds is left alone. Only highlights made after you flip
  the switch go out, so turning it on never empties a backlog into your timeline.
  **NeoDB → Upload all highlights and notes…** is there for when the backlog *is*
  what you wanted; past ten of them it asks first.
- Nothing interrupts you, and nothing is announced. A batch is queued ten seconds
  after you last touch your annotations, and never while a dialog is still open —
  so the note you are writing goes out *with* its passage however long you take
  over it. Come back to a highlight later, though, and the note you add then is not
  sent; see the limitations below.
- Offline is fine, as everywhere else: highlights queue and go out later.

**Settings** holds the two globals. **Upload new highlights and notes** is what a
book starts with when it is linked; every book keeps its own switch afterwards.
**Crosspost shared highlights** decides whether these reach your followers — its
own switch, separate from the ordinary crosspost setting and off by default, since
a book read closely is a great many quotes.

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

## Working offline

- Marks, progress updates and notes made offline are **queued**, and
  the status you set is shown straight away.
- The queue is uploaded the next time you are online — automatically when you
  open a book, or on demand via **NeoDB → Uploads**. The menu lists exactly what
  is waiting.
- Repeated progress updates for the same book collapse to the newest one; notes
  are each kept separately.
- An update that can never succeed (deleted item, revoked token) is discarded
  rather than blocking the queue.
- The automatic syncs never switch Wi-Fi on by themselves.

## Settings

| Setting | Default | Notes |
| --- | --- | --- |
| Default visibility | Public | Public / Followers only / Private. |
| Progress unit | Automatic | See the table above. |
| Crosspost to connected social networks | off | Marks and notes always reach NeoDB; this also crossposts them to your connected Mastodon and/or Bluesky account. |
| Quote highlights as block quotes | on | Prefixes shared highlights with `> `. |
| Pairing service | `p.neodb.net` | Used by QR sign-in. Clear it to hide that option. |
| Update progress when closing a book | off | Only for books already marked. Queued on close, uploaded later — closing a book never waits on the network. |
| Mark as Finished at the end of a book | off | Fires when you reach the last page of a linked book. |
| Upload new highlights and notes | off | What a book starts with when it is linked; each book keeps its own switch under **This book**. See above. |
| Crosspost shared highlights | off | Whether shared highlights also reach your followers. Separate from the crosspost row above. |

## Notes and limitations

- **Your token is stored in plain text** on device. Anyone with access to the
  device or a backup of it can read them. 
  Revoke from your NeoDB instance if a device is lost.
- Your device's model name may be sent to your NeoDB instance, so it may show up
  in your timeline (e.g. "sent from Kobo") with some app. No other device 
  identifier were shared with your NeoDB instance. 
- Requests block KOReader's UI thread and times out after 25 seconds.
- Posting a mark replaces it on the server, so every write resends the rating,
  comment and tags you already had. If you edit a mark on the web while the book
  is open, use **Refresh from NeoDB** before changing it here.
- When NeoDB merges two entries, the link follows the surviving one by itself.
- A shared highlight is posted **once**, as it stands ten seconds after you last
  touch it. Editing it afterwards, or adding a note to one that has already gone
  out, changes nothing on NeoDB — KOReader does not even announce an edit to a
  note's text. Deleting a highlight before its batch goes out does drop it. The id
  NeoDB gives each note *is* recorded against the highlight that produced it,
  which is what a later version would need to push an edit or a deletion through.
  It reaches the book's sidecar whether that book is open, closed, or has been
  renamed since the highlight was queued — in the last case when you next open it.
- Renaming or deleting a book does not disturb anything waiting to upload: queued
  notes are addressed to the NeoDB entry, not to the file. A book deleted along
  with its sidecar loses its link, and nothing is written back to it.

## Layout

| File | Contents |
| --- | --- |
| `main.lua` | Plugin lifecycle, menus, gestures, highlight hook, auto-sync events |
| `neodb_api.lua` | HTTP client, endpoint wrappers, upload queue transport |
| `neodb_store.lua` | Account, preferences, per-book link, queue persistence |
| `neodb_login.lua` | Instance picker and the three sign-in flows |
| `neodb_match.lua` | Book identification, search UI, link management |
| `neodb_actions.lua` | Status, rating, progress, notes, quotes |
| `neodb_annotations.lua` | Mirroring KOReader's own highlights and notes to NeoDB |
| `neodb_util.lua` | ISBN checksums, star rendering, JSON-null scrubbing, helpers |

Two things worth knowing before editing:

- KOReader bundles **luajson**, which has two traps, both of which bit this
  plugin on real hardware:
  - It decodes JSON `null` to a sentinel *function*, not `nil`, so every
    response goes through `Util.scrubNulls`. Without it,
    `if mark.comment_text then` is true for a null comment.
  - It infers array-ness from a table's contents and reports an **empty** table
    as *not* an array, so `{}` is encoded as the JSON object `{}`. Any list field
    must go through `Util.jsonArray` (or be omitted). This is what made NeoDB
    reject every mark with HTTP 422.
- Sibling modules are `neodb_`-prefixed because KOReader puts every plugin
  directory on one shared `package.path`, where a generic `api.lua` would
  collide with another plugin's.

