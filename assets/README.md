# assets

Micro's picture and voice live here. Missing files are created automatically on first run
(a placeholder `micro.gif` and Windows-speech `.wav` clips), so you can start with an empty folder.

| File | Purpose |
|---|---|
| `micro.gif` | Micro, shown on the alert popup (animated or still, transparent background works best) |
| `new-device.mp3` / `.wav` | played for a new / returning unknown device |
| `slow-wifi.mp3` / `.wav` | played when the Wi-Fi is slow |
| `fast-wifi.mp3` / `.wav` | played when the Wi-Fi is fast |
| `<name>.gif` + `<name>-new-device`, `<name>-slow-wifi`, `<name>-fast-wifi` (`.mp3`) | an extra alert character; it appears under tray menu -> Alert character and in Settings |

mp3 wins over wav when both exist. The popup bounces with the real loudness of the clip.
`<name>.env.json` files are caches of that loudness; they are rebuilt automatically.
For mp3 clips the loudness needs `ffmpeg.exe` (put it in this folder, or have it on PATH); without it the bounce uses a built-in rhythm.
