# VG Sentence Mining

A native SwiftUI macOS app for collecting German and Spanish vocabulary from game dialogue.

The local Release build is installed at `~/Applications/VG Sentence Mining.app`.

## Use

1. Connect the T9 drive and open the app.
2. Choose German or Spanish and an optional game glossary in the header. Choose **Start capture**, then choose the game window in the macOS sharing picker.
3. Play your game. Return to the app and click a word in the recent dialogue.
4. Review the screenshot, English definition and translation. Play the generated word pronunciation and the original sentence audio. Sentence clip padding is automatic.
5. Choose **Send to Anki**. Keep Anki open with AnkiConnect enabled.

The preview opens beside the transcript. Close it to give the transcript the full window. Capture continues when you switch back to the game.

## Local setup

- Speech models live at `/Volumes/T9/VG Sentence Mining/Models`. The first launch downloads Whisper large-v3 Turbo and the speaker model; later launches reuse them.
- Transcription uses one local model, Whisper large-v3 Turbo, through pinned WhisperKit 1.1.1. German and Spanish are selected explicitly. FluidAudio provides anonymous speaker labels, which can be imperfect over music, sound effects and overlapping voices.
- English assistance runs the installed Codex CLI using its existing login. Configure the executable in Settings if needed. Codex sends the selected text to OpenAI; speech recognition runs on the Mac.
- AnkiConnect must listen on `127.0.0.1:8765`. In Settings, refresh the available decks and note types, choose a destination for each language, review the field mapping, then choose **Save**. Choices are stored separately for each Anki profile and language. Settings can be resized.
- Word pronunciation offers [MiniMax Speech 2.8 HD](https://replicate.com/minimax/speech-2.8-hd), [ElevenLabs v3](https://replicate.com/elevenlabs/v3) and [Inworld Realtime TTS 2](https://replicate.com/inworld/realtime-tts-2) through Replicate. All three support German and Spanish, with an explicit language setting for single words. Enter your Replicate API key in the app's secure setup sheet or Settings. It is stored in macOS Keychain on this device, never in preferences or a project file.
- macOS controls capture permission and window selection. Choose the source again after restarting the app.

## Game glossaries

Open Settings and choose **Add glossary**. Give the preset a title and paste a
short list of names, places or unusual terms. Each line can contain one word or
phrase. Bulleted and numbered lists, commas, semicolons and tab-separated lists
also work. Duplicate terms are ignored. Your pasted text and title save
automatically.

Each preset has one list shared by German and Spanish. Choose its name beside
the language in the main header, in the capture setup, or with **Use this
glossary** in Settings. **No glossary** clears the recognition hint. Selecting,
editing or deleting a glossary affects new recognition windows; existing
dialogue stays as captured. Deleting the current preset selects **No glossary**.

Glossary terms stay local and are passed to Whisper as prompt tokens. They guide
recognition, but some names may still need correction. Use about 5–10 unusual
names or places for faster transcription. WhisperKit uses up to 111 prompt tokens
from the end of a long list. A timing adapter corrects
WhisperKit 1.1.1's alignment offset when a glossary prompt is present.

Capture continues while recognition runs. A single recognition worker processes
the latest eight-second audio window, rather than queuing every recognition
window behind a slow result.

The speech probe accepts the same pasted-list format:

```sh
xcrun swift run -c release speech-probe sample.wav de --glossary /path/to/glossary.txt
```

## Word audio and card layout

The app uses your selected note type without changing its templates. For the current profile, the suggested destinations are the German and Spanish **Mining** decks with **Migaku German Custom** and **Migaku Spanish Custom**. The app sets their layout switches automatically: the front shows the target word and generated pronunciation; the back shows the sentence, translation, definition, screenshot and original recording.

Expand **Field mapping** to change where each item goes. Dictionary form and definition may share **Definitions**. Both generated word audio and recorded sentence audio are required; other items can be omitted. **Basic** is also supported, with word audio on **Front** and the remaining content on **Back**. Refreshing and saving Settings do not modify Anki. Only **Send to Anki** creates a note. Export checks that the active profile still matches the saved destination.

After a key is configured, choosing a word generates its pronunciation. You can listen with **Play word** before exporting. Settings provides a **Model** picker plus **Test German voice** and **Test Spanish voice** buttons. The picker defaults to MiniMax 2.8 HD and saves changes immediately. A saved choice of the removed MiniMax 2.6 HD or 2.8 Turbo falls back to 2.8 HD. Changing models cancels pending audio and regenerates the selected draft with the new model. Export waits for valid word audio; a failed generation offers a retry.

Only the selected word goes to Replicate and the selected voice provider. The original game recording stays on the Mac. The listed rates are $0.10 per 1,000 input characters for MiniMax and ElevenLabs and $0.025 for Inworld, about $0.001 or $0.00025 for a ten-character word. Replicate requires an account with API credit. See the linked model pages for current pricing.

## Retention

Dialogue and screenshots expire from the rolling 30-minute buffer, including selected drafts. Original audio is stored in one-second temporary chunks and removed as each chunk fully expires. Audio previews also expire. Normal app termination clears temporary captures; the next launch clears captures left by an interrupted run.

Exported image and audio files belong to Anki and survive the capture buffer. The app does not save a separate session archive.

Generated pronunciation is held in memory for the selected draft and cleared when you dismiss, replace or expire that selection. Changing a selection cancels its pending request. The app uses a provider-side deadline and cancels pending predictions when possible.

## Build and verify

Open `VG Sentence Mining.xcodeproj` in Xcode and run the **VG Sentence Mining** scheme. Swift, Xcode and CoreML checks run natively because they require macOS frameworks. Use Docker for other development services and tooling.

```sh
xcodebuild -project 'VG Sentence Mining.xcodeproj' \
  -scheme 'VG Sentence Mining' -configuration Release \
  -derivedDataPath DerivedData build
xcrun swift test -c release
```

The app is built at `DerivedData/Build/Products/Release/VG Sentence Mining.app`. There is no separate lint configuration.

The `speech-probe` executable tests transcription from an audio file:

```sh
xcrun swift run -c release speech-probe sample.wav de --realtime --report /tmp/speech-report.json
```

Use `es` for Spanish. Models must be on the connected T9 drive.

## Verified behavior

The regression suite covers overlapping recognition windows, real repeated words, short words with overlapping timings, speaker boundaries, HTML escaping, original audio extraction and physical media expiry.

Twenty-eight core tests cover glossary paste formats, Unicode, persistence, selection and deletion, separate temporary-media directories for app bundles, safe cleanup of pre-upgrade captures, Replicate requests, trusted output URLs, provider error redaction, Basic and Migaku export payloads, read-only Anki discovery, profile isolation, saved mappings and a disposable Keychain round trip. The optional speech integration test uses synthetic German and Spanish fixtures to verify all five game names have valid word timings, glossary switching clears the previous hint, and digital silence produces no words. Run it with `VG_SPEECH_INTEGRATION=1 xcrun swift test -c release`; it requires T9 and the downloaded local models.

A native check with a delayed CLI also verifies that changing the original sentence rejects its old explanation and that an in-flight response preserves manually edited English. Capture exits discard recognition buffers; partial audio participates in expiry. Idle capture frames reuse the last valid image, while blank or suspended frames invalidate it.

The original Parakeet pipeline was tested with the supplied German video through QuickTime and live capture. Its paced fixture run measured 1.7 seconds median arrival delay and 3.4 seconds at the 95th percentile, with a 6.8-second maximum. These historical measurements predate the switch to Whisper and do not describe its latency. German and Spanish audio fixtures both produced dialogue. Live Codex explanations and Anki image/audio storage were also checked.

The Whisper pipeline's paced 18-second German game fixture measured 3.2 seconds
median arrival delay and 4.2 seconds at the 95th percentile on this Mac. This is
a short fixture measurement; game audio and system load affect results.

The user-approved prerecorded video serves as the repeatable capture test. GeForce Now window capture produced screenshots and audio, but its dialogue has not received the same controlled comparison. Review recognized text before export.

A full 30-minute live game soak and forced ScreenCaptureKit interruption test have not been performed. Buffer expiry is verified with simulated timestamps and actual file deletion.

MiniMax Speech 2.8 HD, ElevenLabs v3 and Inworld Realtime TTS 2 each generated playable German and Spanish test-word audio through the installed app's Settings. The user also confirmed pronunciation works. The current daily Anki profile's deck names, fields and templates were inspected read-only. Configurable export is verified with mocked AnkiConnect responses; no notes, decks, templates or media were modified in that profile during this change.

## Icon

The [full-bleed icon artwork](design/app-icon-fullbleed.png) was generated with the built-in imagegen tool. The [saved prompts](design/app-icon-minimal-prompt.md) describe the white dialogue bubble with a game-control mark on blue. `AppIcon.icon` supplies a fully opaque 1024 × 1024 layer in Apple's native icon format, so macOS applies the outer shape without adding an inset backing tile. The Xcode asset catalog retains the legacy macOS icon sizes.
