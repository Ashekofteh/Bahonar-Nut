# Security Policy

## Supported Versions

Only the latest release of **Selfiyar (سِلفیار)** receives security updates.

| Version | Supported          |
| ------- | ------------------ |
| 1.0.0-beta.x | :white_check_mark: |
| < 1.0.0-beta.5 | :x:                |

## Security & Privacy Architecture

Selfiyar is designed with a strict **Privacy-First & Zero-Knowledge Architecture**:

1. **Local Credential Storage:** Student portal credentials (passwords, session cookies) and bank card information are **never** transmitted to any third-party server, analytics service, or external cloud.
2. **Hardware-Backed & Sandboxed Encryption:** On Android, sensitive credentials are encrypted using **AES-256-GCM** via the Android Keystore and `EncryptedSharedPreferences`. On desktop and iOS, stores reside strictly within protected OS sandbox directories (`Application Support / AppData`).
3. **On-Device CAPTCHA Processing:** CAPTCHA recognition is executed entirely locally on the device (under 1 millisecond per image) via nearest-template pixel analysis. No images or tokens leave the device.
4. **Isolated Cookie Jars:** Each registered account maintains its own isolated session jar, preventing session bleeding or cross-account leakage.
5. **Direct Traffic Only:** All network requests are routed exclusively between the user's device and official university dining endpoints (`https://nut.uk.ac.ir`).

## Reporting a Vulnerability

If you discover a security vulnerability within this project, please report it privately:

- **GitHub Security Advisory:** Submit a private security advisory through the repository's Security tab or open a confidential issue.
- Please provide a detailed description of the issue, steps to reproduce, and any proof-of-concept code.
- We will acknowledge receipt of your report within 48 hours and work with you on a resolution before any public disclosure.
