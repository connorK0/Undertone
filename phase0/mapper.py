"""Mood + intensity + book theme -> music-API-style parameters.

Nothing here talks to a music service. The point of Phase 0 is to print these
next to the prose so a person can judge whether the mapping is plausible. The
shape follows what an adaptive API like Mubert takes -- a genre seed, a mood
token, an energy level, a tempo -- so wiring one in later is a small job.
"""

# Each mood owns a tempo range and an energy floor. The paragraph's intensity
# slides the tempo across the range and lifts energy toward the ceiling; the
# floor keeps a calm paragraph at intensity 1.0 quieter than a tense one at 0.5.
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
    params = MOOD_PARAMS[mood]
    low, high = params["bpm"]
    return {
        "genre": theme["genre_seed"],
        "mood": params["music_mood"],
        "intensity": round(intensity, 2),
        "energy": round(params["energy"] * 0.5 + intensity * 0.5, 2),
        "bpm": round(low + (high - low) * intensity),
        "instrumentation": f"{theme['instrumentation']}; {params['texture']}",
        "theme_id": theme["theme_id"],
    }


def format_params(params):
    """One table cell's worth."""
    return f"{params['genre']} / {params['mood']} / e{params['energy']:.2f} / {params['bpm']}bpm"
