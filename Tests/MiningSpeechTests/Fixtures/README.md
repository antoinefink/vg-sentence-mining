The WAV files are synthetic 16 kHz mono speech created with macOS voices.
They contain no game recordings or personal audio.

- `german.wav`: Anna says “Geralt von Riva reist mit Yennefer nach Kaer Morhen. Ciri wartet dort auf Vesemir.”
- `spanish.wav`: Mónica says “Geralt de Rivia viaja con Yennefer a Kaer Morhen. Ciri espera allí a Vesemir.”

Run the optional local-model regression with T9 connected:

```sh
VG_SPEECH_INTEGRATION=1 xcrun swift test -c release --filter glossaryNamesKeepTheirWordTimings
```
