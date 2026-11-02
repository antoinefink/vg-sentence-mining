# Agent instructions

- Use Docker for development tooling and services; run credentialed CLIs on the host.
- Use native Swift, Xcode and CoreML tooling for macOS checks.
- Keep local copies of game audio as needed for debugging and regression tests.
- After each change, run the relevant checks, commit the changes, and deploy the built app to `~/Applications/VG Sentence Mining.app`. Preserve any active capture when deploying; reopening the app clears its rolling buffer.
