# NeoDB for KOReader

Link the book you are reading to its entry on a NeoDB server, then keep your
status, progress, rating, notes and highlights up to date without leaving the
book.

## What is NeoDB

[NeoDB](https://neodb.net) is a free and open source catalogue of books, films
and more, a little like Goodreads or StoryGraph. The difference is that there is
no single NeoDB owned by a single company: many servers run it, and they talk to
each other over open protocols such as ActivityPub and ATProto. You may use it to
share your reading with friends on Mastodon and Bluesky, or keep a completely
private reading journal.

## Screenshots

| Link to a book | Rate and comment | Sync options |
|:---:|:---:|:---:|
| ![Linking a book to NeoDB](screenshots/link.png) | ![Rating a book and writing a comment](screenshots/mark.png) | ![Choosing what this book syncs](screenshots/options.png) |

## Install

**From a plugin store**, which handles updates afterwards. Search for **NeoDB** in
[Storefront](https://github.com/ultimatejimmy/storefront.koplugin) or
[AppStore](https://github.com/omer-faruq/appstore.koplugin).

**Manually**: download `neodb.koplugin.zip` from
[the latest release](https://github.com/neodb-social/neodb.koplugin/releases/latest)
and unzip it into KOReader's `plugins` folder. The zip already holds a correctly
named folder, so there is nothing to rename.

| Device | Folder |
| --- | --- |
| Kobo | `.adds/koreader/plugins/` |
| Kindle | `koreader/plugins/` |
| Android | `koreader/plugins/` under internal storage |
| Desktop | `koreader/plugins/` next to the program |

Restart KOReader after install. The plugin appears under **☰ → Tools → NeoDB**. 

## Signing in NeoDB

Tap **☰ → Tools → NeoDB → Sign in to NeoDB…** and pick one of these.

- **Scan a QR code** is the easiest. Scan it, sign in on your phone, then tap
  **Done** on the reader.
- **Enter a server address myself** involves nobody but your server. Approve the
  plugin in a browser and type the short code back, or paste a token you made at
  `https://your-server/developer/`.
- **Read a token from a file** avoids typing. Save the token as the first line of
  `neodb_token.txt` in your KOReader folder, then pick this option.

## Linking a book

Once signed in, the first time you open a book, the plugin offers to match an
entry in the server catalogue. You can also match it yourself from either 
**NeoDB → Find this book on NeoDB…**, which searches by ISBN / title + author; 
or from **Link by URL…**, which takes a link from NeoDB, Goodreads, Google Books, 
Open Library or Douban.

After linking, you may choose whether to send progress and highlights
automatically. Your choice are kept per book and can be changed later under
**Settings for this book**.

## What you can do once linked

Most features are under the **☰ → Tools → NeoDB** menu:

- **Read Status**: set to Want to read, Reading, Finished, Dropped.
- **Update progress** sends where you are now.
- **Rate and comment**, from half a star to five, with an optional comment.
- **Add note**, with your position attached if you want.
- **Post something…** writes a post with no book attached.
- **Settings for this book** holds that book's own switches.

To share one quote, select the text and choose **Share on NeoDB** from the
selection menu.

To update reading progress once an hour, turn on
**Settings for this book → Update reading progress automatically**.

To upload highlights automatically, turn on  
**Settings for this book → Upload new highlights and notes automatically**.

To upload highlights manually, use **NeoDB → Upload all highlights and notes…**.

To upload highlights for many books at once, use **☰ → Tools → Export highlights**.

to have one-gesture access, bind **NeoDB: book actions** in 
**Settings → Taps and gestures → Gesture manager**.

## Working offline

Anything you do offline is queued, and goes out next time you are online by
itself when you open a book, or on demand from **NeoDB → Uploads**.


## Things to know

- Most settings explain themselves if you long-press them.
- **Your access token is stored in plain text** on the device. Anybody with the
  device, or with a backup of it, can read it. If you lose the device, cancel the
  token on your NeoDB server.
- Your device model may be sent to your server, so posts may show something like
  "from Kobo". Nothing else identifying is sent.

[dev_notes.md](dev_notes.md) covers the rest: exactly how each feature behaves,
its limits, and everything needed to work on the plugin.
