"""Turn a paragraph mood plus the book's theme into music-API-style parameters.

Nothing here calls a music service. Phase 0 only needs the parameters printed
next to the prose so a human can judge whether the mapping is plausible. The
shape below is modelled on what an adaptive API like Mubert takes -- a genre
seed, a mood token, an energy level and a tempo -- so Phase 3 is a wiring job
rather than a redesign.
"""

# Per-mood musical character. `bpm` is the range the paragraph's intensity is
# interpolated across; `energy` is the mood's own floor, so a calm paragraph at
# intensity 1.0 still reads as calmer than a tense one at 0.5.
MOOD_PARAMS = {
    "tense":       {"music_mood": "suspense",   "bpm": (84, 132), "energy": 0.70, "texture": "pulsing low strings, percussive attacks"},
    "calm":        {"music_mood": "ambient",    "bpm": (56, 78),  "energy": 0.20, "texture": "sustained pads, wide reverb"},
    "melancholic": {"music_mood": "melancholy", "bpm": (52, 74),  "energy": 0.30, "texture": "solo lead over minor harmony"},
    "triumphant":  {"music_mood": "epic",       "bpm": (88, 130), "energy": 0.85, "texture": "brass and full ensemble"},
    "romantic":    {"music_mood": "romantic",   "bpm": (64, 92),  "energy": 0.45, "texture": "warm strings, close piano"},
    "ominous":     {"music_mood": "dark",       "bpm": (58, 86),  "energy": 0.50, "texture": "low drones, sparse percussion"},
    "whimsical":   {"music_mood": "playful",    "bpm": (96, 138), "energy": 0.50, "texture": "pizzicato strings, light woodwind"},
    "neutral":     {"music_mood": "background", "bpm": (68, 92),  "energy": 0.30, "texture": "neutral bed, low profile"},
}


def map_to_music_params(mood, intensity, theme):
    """Combine one paragraph's mood/intensity with the book-level theme."""
    params = MOOD_PARAMS[mood]
    low, high = params["bpm"]

    # Intensity moves the tempo within the mood's range and lifts the mood's
    # energy floor toward its ceiling. Weighting the floor at half keeps the
    # mood recognisable across the whole intensity range.
    bpm = round(low + (high - low) * intensity)
    energy = round(params["energy"] * 0.5 + intensity * 0.5, 2)

    return {
        "genre": theme["genre_seed"],
        "mood": params["music_mood"],
        "intensity": round(intensity, 2),
        "energy": energy,
        "bpm": bpm,
        "instrumentation": f"{theme['instrumentation']}; {params['texture']}",
        "theme_id": theme["theme_id"],
    }


def format_params(params):
    """One-line rendering for the output table."""
    return (
        f"{params['genre']} / {params['mood']} / "
        f"e{params['energy']:.2f} / {params['bpm']}bpm"
    )
