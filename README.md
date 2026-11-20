# JESI Downloader

Flutter Android app for inspecting URLs and downloading **directly accessible media files**.

## Features
- URL inspection using HTTP headers and content type.
- Direct HTTP/HTTPS file downloads with progress, speed and retry while the app process remains active (not a guaranteed persistent background service).
- Publishes images/videos to the Android gallery. Audio is saved in the app's JESI folder (not the public Music folder in this initial build).
- Optional OpenAI-compatible chat endpoint for link explanations.
- API key stored with Android encrypted preferences (`flutter_secure_storage`).
- No ads or analytics SDKs.

## Important platform limitation
Instagram, YouTube, Telegram private links and many social-media pages are not direct media URLs. This app does not bypass logins, DRM, private access controls, or platform restrictions. It reports these as pages/unsupported when it cannot access a direct media stream. Use official export/download features or content you own/have permission to save.

## Build APK with GitHub Actions
1. Upload the project contents to the root of a GitHub repository (keep `.github/workflows/android.yml`).
2. Open **Actions** and enable workflows if GitHub asks.
3. Select **Build Android APK** → **Run workflow**.
4. Wait for the green check, open the run, then download the `jesi-debug-apk` artifact.
5. The APK is a debug build for testing. A signed release APK requires your own Android signing keystore and GitHub Secrets.

## Local build
Install Flutter stable, then:
```bash
flutter create --platforms=android --org com.jesi --project-name jesi_downloader .
flutter pub get
flutter build apk --debug
```

## API configuration
The AI screen accepts an OpenAI-compatible chat-completions endpoint, model name and API key. The app sends the URL and basic inspection metadata to that provider when you ask a question. Do not submit private or sensitive links.
