# Developer notes

The [README](README.md) is enough to use the plugin. This covers what it leaves
out: exactly how each feature behaves and where its limits are, then everything
needed to work on the code.

## How each feature behaves

### Linking

Linking runs ISBN first: if the file name or its metadata hold a valid ISBN, that
is searched for, and an entry the server confirms with the same ISBN is linked
with nothing to confirm. Otherwise it searches title and author and shows the
matches, labelled with publisher and year so editions can be told apart. **Link
by URL…** accepts a NeoDB item page or a link from any site NeoDB can import
from.

The link is kept in the book's own sidecar metadata, so it travels with the file
and survives reinstalling the plugin. It records which server it came from, so a
book linked on one server is never used to post to another.

**The offer on first open** happens once per book, two seconds after the page is
painted. It stays quiet when the option is off, when nobody is signed in, when
the book already has a link, and when anything is on screen at that moment. In
the last case nothing is recorded, so the next open tries again. In all the
others the question is recorded as settled, so unlinking a book later does not
bring it back.

**The dialog that follows a link** asks three things together: the status,
already set to whatever NeoDB holds or to Reading when it holds nothing; whether
the book reports progress on its own; and whether it uploads highlights. The only
way out is Save, because the last two are worthless without the first: progress
hangs off a status, so a book on no shelf cannot report any. Saving a status the
server already had sends nothing. Books linked with an older version have no
answer recorded and follow the global default until their own switch is touched.

### Progress

| File | Reported as | Why |
| --- | --- | --- |
| PDF, DjVu, CBZ | page number | The page numbers are the book's own. |
| EPUB with publisher page numbers | that page number | Real printed pages. |
| Other EPUB, FB2, MOBI | percentage | Page numbers in these depend on the device, font and margins, so they would mean nothing to anybody else. |

A book not yet marked goes onto **Reading** when progress is sent, which is what
sending it means. A book already marked, Finished and Dropped included, is left
where it was put.

**Update progress automatically** is a per-book switch. It reports every hour
while the book is open and once when it closes, whenever the position moved, and
only queues.

### Highlights

The per-book mirror posts each highlight about ten seconds after editing stops.
Only highlights made after the switch went on are posted, so turning it on never
floods a timeline; **Upload all highlights and notes…** sends the backlog for one
book.

Deletions keep step. Delete a highlight and its NeoDB note goes too, and one
deleted before its post went out is never posted at all. Notes posted on purpose,
from the share composer or an export, stay.

### KOReader's own "Export highlights"

NeoDB registers as an export target, so it appears next to Markdown, JSON and
Readwise. It is the only path that reaches many books at once and the only one
that works from the file browser, and it obeys the exporter's own highlight style
and colour filters.

- Only linked books are posted from. Unlinked ones are skipped and counted.
  Nothing goes looking for matches on its own.
- Each highlight is still posted once, however many times it is exported.
- A book is exported from whether or not its own upload switch is on. That switch
  governs the automatic mirror; exporting is deliberate.
- KOReader exports to every ticked target at once, so an export to Markdown also
  posts to NeoDB and wants a connection.
- A backlog larger than the queue goes out in runs, reporting how many are left.
- Needs KOReader **v2025.04** or newer, which is when `Provider` was added. On
  older builds nothing appears.

### The queue

- Repeated progress updates for one book collapse into the newest. Notes are each
  kept.
- An upload that can never succeed, such as one for a deleted entry, is discarded
  rather than blocking what is behind it.
- Uploading stops instead when the trouble is the connection or the account, such
  as a refused sign-in or a rate limit. Everything waits in order and the
  **Uploads** row says why.
- The queue holds 100. When full it refuses new uploads rather than dropping
  waiting ones, so nothing already recorded is lost.

### Known limits

- Saving a mark replaces it wholesale on the server, so every write resends the
  rating, comment and tags already held. Editing a mark on the web while the book
  is open therefore needs **Refresh book info from NeoDB** before the next change.
- A shared highlight is posted once, as it stands ten seconds after it was last
  touched. Editing it afterwards changes nothing on NeoDB, because KOReader does
  not announce an edit to a note's text. Deleting it does work.
- A note posted before note ids were recorded cannot be deleted from the reader.
- When NeoDB merges two entries, the link follows the surviving one by itself.
- Renaming or deleting a book does not disturb anything waiting to upload: queued
  notes are addressed to the NeoDB entry, not to the file.
- The access token is stored in plain text, and the device model may be sent so
  posts can show "from Kobo".

## Source layout

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
| `spec/` | Tests, and the KOReader stubs they run against |

Sibling modules are `neodb_`-prefixed because KOReader puts every plugin
directory on one shared `package.path`, where a generic `api.lua` would collide
with another plugin's.

## Tests

```bash
./spec/run.sh
```

Two harnesses run, `spec/harness.lua` and `spec/harness_exporter.lua`, against
the KOReader stubs in `spec/stubs.lua`. No device and no network are involved.
A failing check prints expected against actual and the run exits non-zero, so it
works as a commit hook.

`LUA=lua5.1 ./spec/run.sh` picks a different interpreter; luajit is the default.

Run the exporter harness under a timezone that has daylight saving to make its
clock cases bite:

```bash
TZ=America/New_York luajit spec/harness_exporter.lua
```

It finds the local spring-forward gap itself and prints `skip` where there is
none, so it passes in UTC too.

The stubs are not only stand-ins, and tests lean on the difference: settings
objects keep LuaSettings' rule that a default is written in only when it is
truthy, `DocSettings:open` copies on open and publishes on flush, and
`Stubs.pressable` mirrors the real per-widget button-table field names, so a
dialog can be operated and a wrong field name fails a test.

One trap the harness itself fell into twice: `pairs` skips a nil value, so
`annotation{ drawer = nil }` quietly keeps the default and tests nothing. There
is a `NONE` sentinel in `spec/harness.lua` for "this field is absent".

## What CI adds

`.github/workflows/test.yml` runs both harnesses on every push and pull request,
plus two gates the harnesses cannot cover:

- every module is compiled, which catches one added and not wired in yet;
- `G_reader_settings` is grepped for outside `neodb_exporter.lua`. It is a
  global, so compiling proves nothing about it, and only the exporter may touch
  it: it keeps its switch in KOReader's own settings.

`.github/workflows/release.yml` builds `neodb.koplugin.zip` when a release is
published: the Lua modules and the licence only, inside an already correctly
named `neodb.koplugin/` folder. The file list is diffed against the repository's
tracked modules first, because the copy is a glob and a plugin shipped without
one of its files fails at load.

## Two traps worth knowing before editing

**luajson**, which KOReader bundles, has two behaviours that both bit this plugin
on real hardware. It decodes JSON `null` to a sentinel *function* rather than
`nil`, so responses go through `Util.scrubNulls`. And it encodes an empty table
as the JSON object `{}` rather than `[]`, so list fields go through
`Util.jsonArray` or are left out entirely. The second one made NeoDB reject every
mark with HTTP 422.

**The exporter target registers at module load, not in `init`.** KOReader loads
`provider*`-named directories first, so `exporter.koplugin` is constructed before
this plugin and has already built its target list by the time our `init` runs.
Registering there would leave NeoDB out of the exporter's own readiness and
network checks until someone opened the export menu. For the same reason
`neodb_exporter.lua` is self-contained: while plugins are loading, each has only
its own directory on `package.path`, so requiring the exporter's `base.lua` does
not resolve.

## Requests are synchronous

LuaSocket blocks KOReader's UI thread for the length of a request, and requests
time out after 25 seconds. Anything that can be reached from a page turn, from
closing a book or from a timer therefore only *queues*, and the queue is drained
at moments where a pause is acceptable. `Util.busy` paints its message before the
call starts, otherwise the screen simply freezes with no explanation.
