# TeleDrive Gallery - Implementation Plan

## Goal Description
Build a Flutter gallery app that uses a private Telegram Channel as unlimited cloud storage ("TeleDrive"). It functions as a "Headless Telegram Client" (Userbot) to store encrypted media.

## Architecture: "The Two-Brain System"
1.  **The Brain (Local)**: Hive Database (NoSQL). Stores metadata (thumbnails, filenames, albums, Telegram Message IDs).
2.  **The Vault (Cloud)**: Telegram Private Channel. Stores encrypted binary data.

## Tech Stack
-   **Framework**: Flutter (Dart)
-   **Telegram Client**: `telegram_client` (Pure Dart MTProto)
-   **Local DB**: `hive` + `hive_flutter`
-   **Encryption**: `encrypt` (AES-256)
-   **Secure Storage**: `flutter_secure_storage` (for encryption keys)
-   **State Management**: `riverpod` (Recommended for this complexity)

## Proposed Changes / Components

### 1. Authentication & Session Management
-   **`TelegramAuthService`**: Wraps `telegram_client`.
    -   Methods: `sendCode`, `signIn`.
    -   Persists session keys locally.

### 2. Database Schema (Hive)
-   **`CloudMediaItem`** (TypeAdapter)
    -   `id` (String, UUID)
    -   `localThumbnailPath` (String)
    -   `telegramMessageId` (int)
    -   `telegramFileId` (String)
    -   `encryptionIV` (String)
    -   `createdAt` (DateTime)
    -   `originalFileName` (String)

### 3. Encryption Strategy
-   **`CryptoHelper`**
    -   Algorithm: AES-256 (CBC or GCM).
    -   Key Storage: Generated once using `SecureRandom`, stored in `flutter_secure_storage`.
    -   Process: Encrypt before upload, decrypt after download.

### 4. Upload Pipeline ("Anti-Ban" Queue)
-   **`UploadQueueService`**
    -   FIFO Queue.
    -   Concurrency: 1 upload at a time.
    -   Rate Limiting: Minimum 3 seconds between uploads.
    -   Error Handling: Respect `FLOOD_WAIT` from Telegram API.

### 5. Gallery & Retrieval
-   **UI**: `GridView` powered by `ValueListenableBuilder` on Hive box.
-   **Retrieval**:
    -   User taps thumbnail.
    -   App requests file from Telegram using `message_id`.
    -   App decrypts file using stored key.
    -   Image displayed.

## Verification Plan
### Automated Tests
-   Unit tests for `CryptoHelper` (encrypt -> decrypt = original).
-   Unit tests for `UploadQueueService` logic (queue order, delays).

### Manual Verification
-   **Auth**: Login with real phone number.
-   **Channel**: Verify "TeleDrive_Storage" is created.
-   **Upload**: Upload image, verify it appears in Telegram channel (encrypted garbage) and app gallery (clear thumbnail).
-   **Download**: Tap image, verify it loads full resolution.
