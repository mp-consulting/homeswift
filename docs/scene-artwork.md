# Scene artwork

143 original AI-generated photographic compositions, created on 2026-10-28 using text prompts.
No Hue photograph was passed to the generator. Existing gallery titles are retained as requested.
This records provenance, not a legal-clearance or exclusive-copyright guarantee.

`Sources/HomeswiftUI/Web/artwork-*.webp` contains 640-pixel-wide thumbnails (WebP quality 78).
Generation metadata, intermediate PNG masters and export bundles are not shipped with Homeswift.
`Sources/HomeswiftMCP/SceneArtwork.swift` maps stable artwork ids to titles and approximate colour palettes.
Gallery mood ids use `gallery-` to avoid changing existing moods such as Relax.
Palettes use approximate sRGB hues derived from the reference colour coordinates; brightness is a
Homeswift setting rather than an exact Hue preset. Gallery moods set once and can be undone.

To change thumbnails, export a replacement image to its existing artwork filename and run
`swift Scripts/embed-assets.swift web Sources/HomeswiftUI/Web Sources/HomeswiftUI/WebAssets.swift`.
Scenes persist only the optional catalogue id, not an arbitrary URL or filesystem path.

`scene-artwork-themes.json` records the theme membership and ordering from the reference catalogue.
A scene may appear in several themes. The UI translates theme headings, while retaining scene titles.

Eight additional original mood photographs depict candles, a fireplace, a home cinema,
a rainbow over waves, a disco ball, a police lightbar, lightning and an alert beacon.
They are separate from the 143 gallery compositions. Scenes saved from these moods
retain their dedicated photographs. The full name review replaced 13 gallery images
and corrected six mood assignments, including the race-day locations and literal subjects.
