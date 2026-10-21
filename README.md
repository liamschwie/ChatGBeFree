# ChatGBeFree

ChatGBeFree is a jailbreak tweak that restores current ChatGPT functionality in the legacy iOS app without requiring a patched IPA. Version 2.4.0 includes the production-refactored realtime voice, model picker, model persistence, Markdown copying, and generated-image compatibility bridges in one package.

## Features

- Bypasses the forced “This version of ChatGPT has been sunset” screen.
- Restores realtime voice on the legacy app using its bundled LiveKit WebRTC engine.
- Preserves the simple r7 voice UI with the green center orb and Mute, Retry, and End controls.
- Hooks the legacy app's exact SwiftUI Voice presentation modifier, covers its first frame with the replacement UI, and dismisses the underlying presentation by setting its captured binding to `nil` when Voice ends.
- Acknowledges accepted voice starts immediately with haptics and a connecting animation, while WebRTC construction, audio-session activation, logging, retry cleanup, and call teardown run away from the UI thread.
- Allows a genuinely new voice session to start immediately after ending the previous one while still suppressing delayed duplicate requests from the session that just ended.
- Starts signaling early when ICE has already produced multiple usable candidates and remembers a successful legacy App-Attest status fallback for later starts in the same app run.
- Replaces duplicate generic model rows with concise choices such as `GPT-5.6 Sol (Instant)`, `GPT-5.6 Sol (Medium)`, and `GPT-5.6 Sol (High)` when those combinations are advertised to the signed-in account.
- Keeps distinct model families separate, removes an unqualified row when it duplicates the model's explicit default effort, and orders current models before legacy choices.
- Reads model and intelligence choices from the live account catalog rather than freezing a list in the tweak, so newer server-advertised choices can appear without another UI rewrite.
- Persists a model/intelligence choice as soon as its picker row is selected and restores it after relaunch only while that exact choice remains advertised to the signed-in account.
- Repairs long-press copying in the legacy Markdown view by removing renderer-only attachment placeholders while preserving ordinary text, Unicode, emoji, code, line breaks, and intentional spacing.
- Detects current asynchronous image turns, waits for their completed tool result, converts that result to the legacy assistant multimodal shape, and hands its opaque asset locator to the old app's authenticated `file-service` loader.
- Rewrites generated-image messages across conversation detail, list-refresh, and legacy repository bootstrap history routes. Modern and historical DALL·E tool results are exposed through the legacy assistant renderer, have the new client's separate-card-only hidden flag cleared, omit internal `Model caption` text, and route both `sediment:` and `file-service:` asset requests through the authenticated native file loader.
- Uses the signed-in app's existing authenticated requests; no API key or separate account setup is required.
- Writes redacted connection diagnostics to `Library/Caches/LegacyVoiceBridge.log` inside the ChatGPT app container.

The model picker does not unlock models or bypass account entitlements; it only exposes choices already returned for the signed-in account. The package does not contain ChatGPT, an IPA, OpenAI frameworks, credentials, or copyrighted app assets. Users must already have a compatible copy of the official app installed.

## Compatibility

The combined sunset bypass and voice bridge is confirmed with:

- ChatGPT `1.2024.200`
- iOS 16.1 and iOS 16.2
- arm64, Substrate-compatible rootless or rootful jailbreaks

The sunset bypass may work on other legacy app versions. Realtime voice additionally requires the app version to contain `LiveKitWebRTC.framework` and the compatible legacy voice request flow, so untested versions are not guaranteed.

## Installation

1. Install the rootless or rootful `.deb` appropriate for the jailbreak.
2. Fully close and reopen ChatGPT after installation.
3. Open Voice in ChatGPT normally.

This package keeps the existing `com.liam.chatgbefree` identifier, so installing version 2.4.0 upgrades an earlier ChatGBeFree package in place. Do not install a separate LegacyVoiceBridge dylib or a patched r7 IPA at the same time.

## Building

[Theos](https://theos.dev/docs/installation) is required.

Rootless package (the default):

```bash
make clean package
```

Rootful package:

```bash
make clean package THEOS_PACKAGE_SCHEME=
```

Packages are written to `packages/`. The WebRTC Objective-C classes are resolved at runtime, so building does not require extracting or linking OpenAI's private framework.

## How it works

ChatGBeFree reports the known-compatible app identity `1.2026.202` (`30140022279`) for the ChatGPT main bundle. It observes the app's authenticated legacy voice status/token flow and, when needed, creates the realtime connection directly with the WebRTC engine already shipped in the app.

The app's original voice button still initiates the authenticated request. The tweak hooks the verified `VoiceViewPresentationModifier` body in the supported legacy framework and copies its `Binding<A?>` before SwiftUI commits the original overlay. That same callback displays the opaque replacement window on the first frame. When the user ends Voice, the tweak writes `nil` through the captured binding—the native SwiftUI presentation teardown—while retaining the cover for the short dismissal transition.

For model selection, the tweak translates the current `models`, `versions`, and intelligence-preset response into the flat category format understood by the 2024 client. A non-default effort is carried through the old picker as a reversible local slug, then translated back to the real `model`, `thinking_effort`, and (when applicable) `service_tier` fields before the authenticated request is sent. The same model/effort translation is applied when Voice starts.

The legacy client normally keeps that picker choice only in memory and initializes every launch from the server catalog default. ChatGBeFree observes the verified `ModelContext.select(...)` path and records the updated navigation selection immediately; request-time resolution remains a fallback. On the next launch it publishes that exact currently advertised row as the legacy default. Stale, unavailable, and hand-crafted choices are not restored.

For generated images, the tweak recognizes modern image turns whose main response finishes before the image does. It holds only that turn's final stream marker, polls the authenticated conversation record for up to three minutes, and injects the completed image-tool message in the assistant multimodal shape understood by the 2024 renderer. History responses are repaired too, including the `dalle.text2im` format and modern results marked visually hidden because a newer app would create a separate image card. Internal model-caption parts are removed. Both modern `sediment:` locators and already translated `file-service:` locators are claimed by the bridge and explicitly handed to the old app's native file-service protocol, retaining its existing account selection, authentication, download-link exchange, MIME handling, and image cache behavior.

The r7 transport reproduces the working newer-client signaling contract: Unified Plan with max-bundle, audio and video transceivers, negotiated data channel ID 0, Opus NACK SDP compatibility, `dcid=0`, and multipart `sdp` plus `session` fields. It retries raw `application/sdp` only when the server explicitly reports that content-type mismatch.

## Troubleshooting

If Voice reports a connection error, a model choice is missing, or a generated image stays blank, retrieve `LegacyVoiceBridge.log` from the ChatGPT app container's `Library/Caches` directory. The log records the published model choices, selected model/effort, request shape, route, image-event structure, asset scheme, download status, SDP structure, and WebRTC state without deliberately recording prompts, file IDs, signed URL values, authorization credentials, or full server payloads.

Make sure only one copy of ChatGBeFree/LegacyVoiceBridge is installed and that ChatGPT is not a previously patched IPA containing the same dylib.

## License

This project is available under the [GNU GPLv3](LICENSE).
