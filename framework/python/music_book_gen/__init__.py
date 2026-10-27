"""Music for books: the generation half.

The Dart package (framework/dart) prepares a book workspace up to a bed plan
(allocation.json). This package turns the plan into audio:

    prompts     what MusicGen is asked for, per cue, per take, per seed
    jobs        a workspace's plan as a self-contained job, and the pool that
                comes back culled and installed into the workspace
    runner      generates a job on whatever GPU it runs on (standalone: this
                file and loopify.py are all a remote machine needs)
    loopify     a clip into a seamless loop, and the audibility guard
    cull        which takes survive: movement, behind the register gate
    measure     timbre and movement, and the distance table a player's
                lead-in reads
    kaggle, modal_app   the runner on someone else's GPU

    python -m music_book_gen --help

See framework/FORMAT.md for the files and framework/README.md for the whole.
"""

__version__ = "0.1.0"
