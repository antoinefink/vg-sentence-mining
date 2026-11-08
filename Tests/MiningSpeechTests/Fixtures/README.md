The optional WAV files are local synthetic 16 kHz mono speech. They are ignored
by Git and are not distributed. Apple restricts redistribution of recordings
made with macOS system voices; see section 2F of the
[macOS license](https://www.apple.com/legal/sla/docs/macOSTahoe.pdf).

- `german.wav`: Anna says “Geralt von Riva reist mit Yennefer nach Kaer Morhen. Ciri wartet dort auf Vesemir.”
- `spanish.wav`: Mónica says “Geralt de Rivia viaja con Yennefer a Kaer Morhen. Ciri espera allí a Vesemir.”

To recreate them on your Mac for personal testing, install the Anna and Mónica
voices in macOS settings, then run these commands from the repository root:

```sh
say -v Anna -o /tmp/vg-german.aiff 'Geralt von Riva reist mit Yennefer nach Kaer Morhen. Ciri wartet dort auf Vesemir.'
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/vg-german.aiff Tests/MiningSpeechTests/Fixtures/german.wav
say -v Mónica -o /tmp/vg-spanish.aiff 'Geralt de Rivia viaja con Yennefer a Kaer Morhen. Ciri espera allí a Vesemir.'
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/vg-spanish.aiff Tests/MiningSpeechTests/Fixtures/spanish.wav
```

Do not commit or redistribute those generated recordings. Ordinary unit tests
skip the optional speech integration checks and do not require these files.

Run the optional local-model regression with T9 connected:

```sh
VG_SPEECH_INTEGRATION=1 xcrun swift test -c release --filter glossaryNamesKeepTheirWordTimings
```
