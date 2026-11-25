# Pkrypt

![Platform](https://img.shields.io/badge/Platform-Android-3DDC84?style=flat-square&logo=android&logoColor=white)
![Flutter](https://img.shields.io/badge/Built%20with-Flutter-02569B?style=flat-square&logo=flutter&logoColor=white)
![Encryption](https://img.shields.io/badge/Crypto-AES--256--GCM%20%7C%20Argon2id%20%7C%20X25519-0A66C2?style=flat-square)
![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)

**Pkrypt** is a private, zero-knowledge encrypted gallery app for Android built with **Flutter** and **TDLib**, using your own private Telegram channels as encrypted cloud storage.

All photos, videos, and thumbnails are encrypted locally on-device before upload. Cloud storage only ever receives authenticated ciphertext and never has access to your master password, encryption keys, or plaintext media.

---

## Key Features

* **Zero-Knowledge Encryption:** Local **AES-256-GCM** encryption with **Argon2id** key derivation.
* **Locked Background Sync:** Uses **X25519** public-key encryption so background uploads can encrypt media even while the vault is locked.
* **Chunked Video Streaming:** Encrypts and streams large videos in encrypted chunks for lower memory usage and smooth playback.
* **Native Encrypted Video Thumbnails:** Extracts video frames via Android `MediaMetadataRetriever` with zero extra APK overhead and stores previews locally as encrypted `.vthumb` files.
* **Decoy Vault PIN:** Unlock a separate decoy vault directly from the lock screen.
* **100% Offline AI Face Grouping:** Groups people completely on-device without sending photos to external servers.

---

## Security Overview

| Layer | Implementation |
| :--- | :--- |
| **Key Derivation** | Argon2id |
| **Symmetric Media Encryption** | AES-256-GCM (local on-device before upload) |
| **Locked Background Sync** | X25519 public-key encryption |
| **Local Previews** | AES-256-GCM encrypted `.vthumb` files decrypted only in RAM |
| **Video Handling** | Encrypted chunked streaming |
| **Cloud Transport** | Private Telegram channels via TDLib (ciphertext only) |

---

## Download & Installation

Go to the **[Releases](https://github.com/PARTHYADAV014/PKrypt/releases/latest)** page and download the APK matching your phone:

| APK File | Best For |
| :--- | :--- |
| **`Pkrypt-v1.0.0-arm64-v8a-RECOMMENDED.apk`** | Modern 64-bit Android phones (2019+, works on 95%+ devices) |
| **`Pkrypt-v1.0.0-armeabi-v7a-old-phones.apk`** | Older 32-bit Android devices (use if the arm64 APK fails to install) |

SHA-256 checksums are included in every GitHub Release for download verification.

---

## Build From Source

### Prerequisites
* Flutter SDK (3.x)
* Android SDK / Android Studio build tools
* Your own Telegram `api_id` and `api_hash` from [my.telegram.org](https://my.telegram.org)

### Setup Steps
1. Clone the repository:
   ```bash
   git clone [https://github.com/PARTHYADAV014/PKrypt.git](https://github.com/PARTHYADAV014/PKrypt.git)
   cd PKrypt
   ```
2. Create your local Telegram config file:
   * Copy `lib/core/telegram_config.example.dart` to `lib/core/telegram_config.dart`.
   * Replace `apiId` and `apiHash` with your own credentials.
3. Install dependencies and build split release APKs:
   ```bash
   flutter pub get
   flutter build apk --release --split-per-abi
   ```

> **Security Note:** Never commit `lib/core/telegram_config.dart`, `android/key.properties`, or `.jks`/`.keystore` signing files.

---

## License

This project is licensed under the **[MIT License](LICENSE)**.
