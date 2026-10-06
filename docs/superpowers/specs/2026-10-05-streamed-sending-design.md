# Streamed sending

## Why

Sending a file read the whole of it into memory (`XFile.readAsBytes`) and
handed it to `Room.sendFileEvent`, which keeps it there: a cached copy to
disk, an encrypted copy, and the request body. A 174 MB, 61 s 4K iPhone clip
costs several times its size in memory, enough for iOS to end the app. And
nothing shows until all of it is read: the row appears only after the read,
so a big video looks like the app ignored the tap.

`package:matrix` 13 has no streaming path. `MatrixFile`, `sendFileEvent`,
`Client.uploadContent` and `encryptFile` all take one `Uint8List`. So files
no longer go through `sendFileEvent`.

## What changes

- A picked file is sent from its path. `Attachment` carries a path and a
  size, never bytes.
- The row appears at once, before anything is read: the SDK's own kind of
  placeholder (an `m.room.message` with the transaction id as its event id,
  `unsigned` status sending), written through `Client.handleSync` in a
  database transaction, as `sendFileEvent` does. So it is persisted, the
  timeline maps it as today, and a relaunch finds it failed, to retry or
  discard.
- A file over the server's limit (`Client.getConfig`, cached by the SDK) is
  refused before the row: a toast names the file, its size and the limit.
  If the limit can't be read, the upload goes and the server decides.
- The body streams from disk in chunks. In an encrypted room each chunk goes
  through AES-256-CTR (`CtrDecryptor`, which is the same operation, renamed
  `CtrCipher`) and into a running SHA-256 (`package:crypto`), giving the
  `file` block of the spec's encrypted attachments. CTR keeps the length, so
  the request has a `Content-Length`, and progress has a total.
- The upload is a `StreamedRequest` to `/_matrix/media/v3/upload` through
  `client.httpClient`, so `LoafHttpClient`'s idle limit and progress apply as
  now. `ensureNotSoftLoggedOut()` runs first, as the SDK's requests do. A
  `413` / `M_TOO_LARGE` says "too big", as before.
- Then `Room.sendEvent(content, txid:)` under the same transaction id
  replaces the placeholder, as `sendFileEvent` does at its end. Encryption of
  the event, the reply relation and send retries are the SDK's.
- Images still get dimensions, a blurhash and an 800 px thumbnail, as now,
  but made by `NativeImplementationsIsolate` off the UI isolate: today the
  SDK's pure-Dart resizer runs on it. Images are read whole for this; that
  is bounded by the upload limit, and decoding needs the pixels anyway.
  Video gets size and mimetype; a poster frame, dimensions and duration are
  a separate piece of work (below).

## Where the file lives while sending

- A picker's temporary copy (under the app's temporary directory: PHPicker
  and the iOS Files picker both copy there) is moved, not copied, into
  `<support>/outgoing/<txid>`: the OS may clear temp, and a failed send
  must still be retryable after a relaunch.
- A file picked on a computer is the user's own; it is read in place, never
  moved.
- The placeholder records the path and the reply target in `unsigned`
  (`moe.loaf.outgoing`). Retry reads them back. If the file is gone, retry
  says so, and discard stays.
- `outgoing/` is emptied of a file once its message is sent or discarded,
  of anything no placeholder names when the account opens, and entirely on
  sign-out.

## Failure

Every failure marks the placeholder failed through `handleSync`; the row
offers retry and discard, as text does. Retry of a file sent by the old path
(an SDK placeholder with a cached copy) still goes through `sendAgain`.

## Tests

The timeline tests' fake server, extended to record upload bodies:

- the row is there before the upload starts, and nothing is read for it;
- a file streams in chunks, and memory is never asked for the whole of it
  (a test file larger than one chunk, read through a counting stream);
- an encrypted room's upload decrypts, with the SDK's own
  `decryptFileImplementation`, to the original, and its hash matches;
- too big: toast, no row, no upload;
- failure, retry after a relaunch (a database on disk), file gone on retry,
  discard removes the outgoing copy;
- a reply still quotes; progress still reports.

## Not in this

- **Video posters and metadata** (AVFoundation's `AVAssetImageGenerator` on
  Apple, GStreamer on Linux): other clients show a blank box without them.
- **Shrinking video before sending** (`AVAssetExportSession` / GStreamer),
  versus raising the server's `max_request_size` (20 MB): a 61 s 4K clip is
  174 MB.
