# ChatGBeFree

A jailbreak tweak to bypass the forced upgrade screen "This version of ChatGPT has been sunset" in the ChatGPT app on older iOS versions.

## How It Works

When ChatGPT launches, it sends its current app version to OpenAI's backend. The response contains a status field — if the app version is too old, the server replies with hard_deprecation, which locks the app behind a "This version of ChatGPT has been sunset" screen.

ChatGBeFree intercepts this API response and rewrites "status" to "supported", meaning the sunset screen will never trigger. It also hooks NSBundle to spoof CFBundleShortVersionString and CFBundleVersion to a future build (1.2099.999), preventing the deprecation flag from being returned by the server in the first place.

## Compatible Versions

HBOMaxBypass has been tested with the last app version that supports iOS 16.2. Simply install the latest version of the ChatGPT app that is supported for your device.

The tweak should work with any older version of the app that can launch on your iOS version but is blocked by the force upgrade screen.

## Installation

### From a .deb (Releases)

1. Download the latest `.deb` from [Releases](../../releases)
2. Transfer to your device and install with Filza or your package manager
3. Respring

### Building from source

Requires [Theos](https://theos.dev/docs/installation).

```bash
git clone https://github.com/liamschwie/ChatGBeFree.git
cd ChatGBeFree
make package
```

The `.deb` will be in the `packages/` directory. The default build targets **rootless** jailbreaks (Dopamine, palera1n). For rootful jailbreaks, remove the `THEOS_PACKAGE_SCHEME = rootless` line from the Makefile.

## Technical Details

The tweak hooks two things:

1. **`NSBundle infoDictionary`** — Returns spoofed `CFBundleShortVersionString` (`1.2099.999`) and `CFBundleVersion` (`99999999999`) for the `com.openai.chat` bundle, tricking the app into reporting a future build to the server.

2. **`NSURLSession dataTaskWithRequest:completionHandler:`** — Intercepts network responses from `openai.com` and `chatgpt.com`. When the response contains `"status":"hard_deprecation"` or `"status":"soft_deprecation"`, it uses a regex to replace the value with `"status":"supported"` before the app processes it.

## Requirements

- Jailbroken iOS device
- A compatible version of the ChatGPT app installed via `ideviceinstaller` or the App Store

## License

This project is made available under the [GNU GPLv3](LICENSE).
