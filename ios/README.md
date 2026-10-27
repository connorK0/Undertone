# Undertone for iOS

A reader whose score follows the page, built on the framework in
`../framework/` (`music_book_core` for the decisions, `music_book_player` for
the sound). It is separate from `phase1/`, the Windows reader, and shares no
code with it except through the framework.

## How books get onto the phone

A phone cannot prepare a book: there is no model to tag with and no GPU for
MusicGen. Books are prepared on a computer and carried over as a pack:

```sh
# on the computer, in framework/dart (see framework/README.md)
dart run music_book ingest  pride.epub ~/books/pride
dart run music_book prepare ~/books/pride --arc 0
# ... generate the beds (framework/python), then:
dart run music_book pack ~/books/pride pride.zip
```

On the phone, either tap **Import** in the library and pick the zip, or drop
it into the app's folder in the Files app (or in Finder, over USB). The
app's Documents folder is shared for exactly that (`Info.plist`), and any
pack found there is unpacked the next time the library refreshes. Where the
reader left off is kept beside the book (`reader.json`) and survives a newer
pack of the same book.

## Building

Needs a Mac with Xcode; nothing here can be built for iOS on Windows.

```sh
flutter pub get
open ios/Runner.xcworkspace    # set a signing team once
flutter run -d <iphone>
```

The bundle id is `com.musicbook.musicBookReader`; change it to one you own
before signing. The `windows/` platform is there only so the app can be run
and tested on the development machine.

## Tests

```sh
flutter test      # 5 tests, headless
```

The library lists a prepared book and says how to get one when empty; a
dropped pack is unpacked; opening a book reports the reading position to the
score and saves the place; and a real `ScorePlayer`, with no audio device,
turns that position and the book's own tags into the set's cue.

## Not yet verified

- **It has never been built for iOS.** Everything above ran on Windows.
- **No sound has been played by this app.** The tests run the player with
  no audio device, so they check which cue it chooses, not what it sounds
  like.
- **The silent switch and the lock screen.** Whether the ring/silent switch
  mutes the score depends on the audio session category flutter_soloud sets
  on iOS, which has not been checked. Nothing asks for background audio
  (`UIBackgroundModes`), so the score is expected to stop when the app is
  backgrounded, which suits a reader but is untested.
- **A real book.** The tests use a three-chapter book written by the test.
  The phase1 test book has not been packed and opened here.
