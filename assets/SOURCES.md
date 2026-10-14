# Where the sounds and icons come from

| File | Source | Licence |
|---|---|---|
| `sounds/chime.wav` | Written by `tool/chime` in this repository. | AGPL-3.0-only, as the repository. |
| `sounds/call_join.wav` | `src/sound/join_call.ogg` in Element Call, taken from the loaf.moe fork at `28da7a19`. | Element Call is AGPL-3.0-only or Element's commercial licence; its `src/sound/LICENCE.md` lists `join_call` as created by Element. |
| `sounds/call_leave.wav` | `src/sound/left_call.ogg`, same repository and commit. | Element Call's, as above. Its `src/sound/LICENCE.md` has no line for `left_call`. |
| `icons/discord.png`, with `2.0x/` and `3.0x/` | `icons/discord.svg` from Simple Icons, `develop` as of 2026-10-14, kept as `tool/icons/discord.svg`. Discord's mark, drawn beside a name to say its messages come over the Discord bridge. | Simple Icons is CC0 1.0. |

The two call sounds were converted with:

```
ffmpeg -i <source>.ogg -ac 1 -ar 48000 -c:a pcm_s16le <file>.wav
```

The badge is rendered at 14, 28 and 42 pixels, one per asset variant, with:

```
rsvg-convert -w <px> -h <px> tool/icons/discord.svg -o <file>.png
```
