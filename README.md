# VG Sentence Mining

A native SwiftUI macOS app for collecting German and Spanish vocabulary from game dialogue.

The local Release build is installed at `~/Applications/VG Sentence Mining.app`.

## Use

1. Connect the T9 drive and open the app.
2. Choose **Start capture**, select the dialogue language, then choose the game window in the macOS sharing picker.
3. Play your game. Return to the app and click a word in the recent dialogue.
4. Review the screenshot, English definition and translation. Play the original audio and adjust its padding if needed.
5. Choose **Send to Anki**. Keep Anki open with AnkiConnect enabled.

The preview opens beside the transcript. Close it to give the transcript the full window. Capture continues when you switch back to the game.

## Local setup

- Speech models live at `/Volumes/T9/VG Sentence Mining/Models`. The first launch downloads the pinned FluidAudio transcription and speaker models; later launches reuse them.
- Transcription uses Parakeet v3 through FluidAudio. Speaker labels are anonymous and can be imperfect, especially over music, sound effects and overlapping voices.
- English assistance runs the installed Codex CLI using its existing login. Configure the executable in Settings if needed. Codex sends the selected text to OpenAI; speech recognition runs on the Mac.
- AnkiConnect must listen on `127.0.0.1:8765`. Export uses the **Basic** note type, **Front** and **Back** fields, and the deck set in Settings (initially **Default**).
- macOS controls capture permission and window selection. Choose the source again after restarting the app.

## Retention

Dialogue and screenshots expire from the rolling 30-minute buffer, including selected drafts. Original audio is stored in one-second temporary chunks and removed as each chunk fully expires. Audio previews also expire. Normal app termination clears temporary captures; the next launch clears captures left by an interrupted run.

Exported image and audio files belong to Anki and survive the capture buffer. The app does not save a separate session archive.

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

Ten regression tests pass. A native check with a delayed CLI also verifies that changing the original sentence rejects its old explanation and that an in-flight response preserves manually edited English. Capture exits discard recognition buffers; partial audio participates in expiry. Idle capture frames reuse the last valid image, while blank or suspended frames invalidate it.

The supplied German video was tested through QuickTime and the live capture pipeline. A paced transcription run measured 1.7 seconds median arrival delay and 3.4 seconds at the 95th percentile, with a 6.8-second maximum on this Mac. These are fixture measurements; game audio and system load affect results. German and Spanish audio fixtures both produced dialogue. Live Codex explanations and Anki image/audio storage were also checked.

The user-approved prerecorded video serves as the repeatable capture test. GeForce Now window capture produced screenshots and audio, but its dialogue has not received the same controlled comparison. Review recognized text before export.

A full 30-minute live game soak and forced ScreenCaptureKit interruption test have not been performed. Buffer expiry is verified with simulated timestamps and actual file deletion.
