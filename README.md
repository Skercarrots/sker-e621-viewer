# Sker e621 Viewer

A feature-rich Flutter client for browsing, exploring, and organizing media from [e621](https://e621.net).

---

## ✨ Features

- **Media Gallery**:
  - Smooth grid browsing with infinite scrolling and lazy loading.
  - Tag-based search with autocomplete support.
  - Video and animated GIF/WebM preview and playback.
- **Detailed Post Viewer**:
  - High-resolution image viewer with pinch-to-zoom.
  - Seamless swipe navigation between posts.
  - Comprehensive tag inspection grouped by category (Artists, Characters, Copyrights, Species, General, Meta).
  - Score, favorites count, source links, and post metadata.
- **Custom Boards**:
  - Create custom boards to save and organize your favorite posts.
  - User-specific and guest-mode board management.
- **Collections (Pools & Sets)**:
  - Browse pools and sets directly from e621 with detailed multi-post gallery views.
- **User Authentication & Follows**:
  - Secure login with e621 username and API key using encrypted device storage.
  - Guest mode for quick, anonymous browsing.
  - Follow favorite artists and tags.
- **Cross-Platform**:
  - Supports Android, iOS, Windows, macOS, Linux, and Web.

---

## 🚀 Getting Started

### Prerequisites

- [Flutter SDK](https://flutter.dev/docs/get-started/install) (Dart SDK `^3.10.4` or later)
- An e621 account and API Key (optional, required only for authenticated features)

### Running the App

1. Clone the repository:
   ```bash
   git clone https://github.com/Skercarrots/sker-e621-viewer.git
   cd sker-e621-viewer
   ```

2. Install dependencies:
   ```bash
   flutter pub get
   ```

3. Run on your connected device or emulator:
   ```bash
   flutter run
   ```

### Running Tests

```bash
flutter test
```

---

## 🔒 Security & Privacy

Your credentials and API keys are stored securely on your local device using `flutter_secure_storage` (Keychain on iOS/macOS, EncryptedSharedPreferences on Android, and DPAPI on Windows). They are never shared with any third-party services other than direct API calls to e621.net.

---

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.
