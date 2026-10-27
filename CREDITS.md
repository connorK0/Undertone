# Credits and third-party material

## Music: `phase1/assets/music/licensed/`

Loops from [OpenGameArt](https://opengameart.org), included unmodified as an
alternative set of beds for the Windows reader. The two CC-BY tracks are
licensed under [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/). The
rest are [CC0](https://creativecommons.org/publicdomain/zero/1.0/), credited
here as their authors ask.

| file | title | author | licence |
| --- | --- | --- | --- |
| `tense.mp3` | [Perpetual Tension](https://opengameart.org/content/perpetual-tension) | Zander Noriega | CC BY 3.0 |
| `ominous.ogg` | [Dark Ambient Loop 13](https://opengameart.org/content/dark-ambient-loop-13) | MundoSound | CC BY 3.0 |
| `calm.mp3` | [Crystal Cave (song18)](https://opengameart.org/content/crystal-cave-song18) | cynicmusic ([pixelsphere.org](http://pixelsphere.org) / The Cynic Project) | CC0 |
| `triumphant.mp3` | [Awake! (Megawall-10)](https://opengameart.org/content/awake-megawall-10) | cynicmusic ([cynicmusic.com](http://cynicmusic.com), [pixelsphere.org](http://pixelsphere.org)) | CC0 |
| `whimsical.mp3` | [Enchanted Tiki 86](https://opengameart.org/content/enchanted-tiki-86) | cynicmusic | CC0 |
| `melancholic.ogg` | [Tragic ambient main menu](https://opengameart.org/content/tragic-ambient-main-menu) | HaelDB | CC0 |
| `neutral.wav` | [Loading screen loop](https://opengameart.org/content/loading-screen-loop) | HaelDB | CC0 |
| `romantic.mp3` | [The Field Of Dreams](https://opengameart.org/content/the-field-of-dreams) | pauliuw | CC0 |

The other beds in `phase1/assets/music/` are synthesized by this project's own
scripts (`phase1/tool/make_loops.py`, `phase1/tool/make_theme_treatments.py`)
and contain no third-party material. Like the code, they are all rights
reserved.

## Books

Public-domain texts from [Project Gutenberg](https://www.gutenberg.org), used
as test fixtures and sample books:

- *Alice's Adventures in Wonderland*, Lewis Carroll
- *A Christmas Carol*, Charles Dickens
- *Dracula*, Bram Stoker
- *Pride and Prejudice*, Jane Austen

They appear as ePubs in `phase1/test/fixtures/` and
`framework/dart/test/fixtures/`, and as excerpts in `phase1/assets/books/` and
`phase0/sample_books/`. `chapter1.txt` ("The Lamplighter's Round") was written
for this project.

## Models

- **MusicGen** (Meta), which generates the music beds, is used through Hugging
  Face Transformers. Its weights are licensed
  [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/), which does not
  cover commercial use. This repository contains no MusicGen output.
- **Qwen2.5 7B**, which tags moods, runs locally through
  [Ollama](https://ollama.com) under the Apache 2.0 licence.
