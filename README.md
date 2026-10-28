# NeoDB for KOReader

Link the book you are reading to its entry on a NeoDB server, then keep your status, progress, rating, notes and highlights up to date without leaving the book.

## What is NeoDB

[NeoDB](https://neodb.net) is a free and open source catalogue of books, films and more, similar to Goodreads or StoryGraph. The difference is that there is no single NeoDB owned by a single company: many servers run it, and they talk to each other over open protocols such as ActivityPub and ATProto. You may use it to share your reading with friends on Mastodon and Bluesky, or keep a completely private reading journal.

## Screenshots

| Link to a book | Rate and comment | Sync options |
|:---:|:---:|:---:|
| ![Linking a book to NeoDB](screenshots/link.png) | ![Rating a book and writing a comment](screenshots/mark.png) | ![Choosing what this book syncs](screenshots/options.png) |

## Install

The interface follows KOReader's language setting: Simplified Chinese is fully
translated, and English uses the original labels. Generated note titles and the
quote introduction follow the same language; your book metadata and note text
are never translated. Restart KOReader after changing its interface language.

**From a plugin store**, which handles updates afterwards: search for **NeoDB** in [Storefront](https://github.com/ultimatejimmy/storefront.koplugin) or [AppStore](https://github.com/omer-faruq/appstore.koplugin).

**Manually**: download `neodb.koplugin.zip` from [the latest release](https://github.com/neodb-social/neodb.koplugin/releases/latest) and unzip it into KOReader's `plugins` folder. The zip already holds a correctly named folder, so there is nothing to rename.

| Device | Folder |
| --- | --- |
| Kobo | `.adds/koreader/plugins/` |
| Kindle | `koreader/plugins/` |
| Android | `koreader/plugins/` under internal storage |
| Desktop | `koreader/plugins/` next to the program |

Restart KOReader after install. The plugin appears under **☰ → Tools → NeoDB**.

To see which version you have, tap **☰ → Tools → NeoDB → Settings → About this plugin**. A copy built from the source rather than installed from a release reports `dev`.

## Signing in NeoDB

Tap **☰ → Tools → NeoDB → Sign in to NeoDB…** and pick one of these.

- **Scan a QR code** is the easiest. Scan it, sign in on your phone, then tap **Done** on the reader.
- **Enter a server address myself** involves nobody but your server. Approve the plugin in a browser and type the short code back, or paste a token you made at `https://your-server/developer/`.
- **Read a token from a file** avoids typing. Save the token as the first line of `neodb_token.txt` in your KOReader folder, then pick this option.

## Linking a book

Once signed in, the first time you open a book, the plugin offers to match an entry in the server catalogue. You can also match it yourself from either **NeoDB → Find this book on NeoDB…**, which searches by ISBN / title + author; or from **Link by URL…**, which takes a link from NeoDB, Goodreads, Google Books, Open Library or Douban.

After linking, you may choose whether to send progress and highlights automatically. Your choice are kept per book and can be changed later under **Settings for this book**.

## What you can do once linked

Most features are under the **☰ → Tools → NeoDB** menu:

- **Read Status**: set to Want to read, Reading, Finished, Dropped.
- **Update progress** sends where you are now.
- **Rate and comment**, from half a star to five, with an optional comment.
- **Add note**, with your position attached if you want.
- **Post something…** writes a post with no book attached.
- **Settings for this book** holds that book's own switches.

Choose **Add note & share** to write a note about selected text and share it to
NeoDB. The title and scrollable body are edited in one window. The editor adapts
to the on-screen keyboard and follows KOReader's virtual keyboard setting when
a hardware keyboard is available. Drag the window by its header, as with the
native note editor. The default title is empty.

The quote button cycles through four modes:

- **Quote: below note** (default): append the selected passage when posting.
- **Quote: above note**: prepend the passage when posting.
- **Quote: none**: post only the note, without a passage or introduction.
- **Quote: custom**: put the passage in the editor before the note, so the whole
  post can be freely edited. Nothing is added when posting.

Automatic quote modes keep the added passage out of the editor and local note.
Custom mode saves the entire editor body, including any remaining quotation,
when local saving is explicitly enabled. Reopening a saved custom note does not
insert its quotation again. Ordinary and custom drafts are retained separately
when switching modes. None and custom require a non-empty body.

**Save locally: on / off** controls whether posting also saves the editor body
as a KOReader note. It starts on for new selections, unless changed in settings,
but always starts **off for existing annotations** to protect their local notes.
Turn it on explicitly to edit an existing local note. An empty body in automatic
quote mode saves a highlight without a note. Cancelling creates no annotation.

Under **NeoDB → Settings → Selection sharing defaults**, configure quote mode,
attaching progress, saving new notes locally, crossposting selected text,
automatic titles and quote introductions. Composer overrides apply only to that
post. Global visibility, block quote formatting and crossposting remain in the
main Settings menu. Both global and selection crossposting are **off by default**
and have independent switches. Existing explicitly saved preferences are kept.

Automatic titles and introductions are off by default. Each can be enabled as
**Plain text** or **With emoji**. Titles include the book, chapter and live
percentage when available, for example `Reading notes | Dune · Chapter One · 48%`.
The decorated version starts with `📖`. Other title presets show only the book,
the book and chapter, or the book and progress. **Custom…** accepts a title
template with `{book}`, `{chapter}` and `{progress}` placeholders.

Introduction presets include `Quoted passage:`, `Quoted passage: 👇`, `Excerpt:`,
`Original text:` and `From the book:`. **Custom…** accepts your own introduction,
including multiple lines. The introduction precedes the quotation regardless of
whether that quotation appears above or below the note. Sharing uses the same
introduction setting, including posts without note text. Custom mode adds neither
an automatic introduction nor an extra quote.

The editor was checked with **KOReader v2026.07.1**. Its optimized two-field
layout uses internal widget APIs behind a guarded resize operation. If that
layout cannot be resized, it preserves the drafts in the standard body editor
with an **Edit title** button. Keyboard and focus changes avoid repainting all
windows when the layout has not changed. E-ink refresh behavior still needs
physical-device testing.

To update reading progress once an hour, turn on **Settings for this book → Update reading progress automatically**.

To upload highlights automatically, turn on  
**Settings for this book → Upload new highlights and notes automatically**.

To upload highlights manually, use **NeoDB → Upload all highlights and notes…**.

To upload highlights for many books at once, use **☰ → Tools → Export highlights**.

to have one-gesture access, bind **NeoDB: book actions** in **Settings → Taps and gestures → Gesture manager**.

## Working offline

Anything you do offline is queued. It goes out the next time you open a book, and you can send it yourself at any moment from **NeoDB → Uploads**, which also shows what is waiting. An upload that fails is tried three more times over about two minutes, then left for the next occasion.

To have the queue send itself instead, turn on **Settings → Upload automatically when connected**. It is off until you ask for it. With it on, anything waiting goes out quietly whenever the device goes online, whatever put it online: turn Wi-Fi on for some other reason and your backlog leaves behind it, with nothing to open and nothing to tap.

This never turns Wi-Fi on by itself, never interrupts you, and never sits there checking. KOReader tells the plugin when the device connects, so a reader who stays offline for a week pays no battery for it.


## Things to know

- Most settings explain themselves if you long-press them.
- **Your access token is stored in plain text** on the device. Anybody with the device, or with a backup of it, can read it. If you lose the device, cancel the token on your NeoDB server.
- Your device model may be sent to your server, so posts may show something like "from Kobo". Nothing else identifying is sent.
- [dev_notes.md](dev_notes.md) covers the rest: exactly how each feature behaves, its limits, and everything needed to work on the plugin.
