- Status: Canonical
- Owner: Engineering
- Last verified: 2026-03-19
- Source of truth: `Sources/ScoutLib/Services/ScoutDropService.swift`, `Sources/ScoutLib/Services/ScoutDropIdentity.swift`

# ScoutDrop — Peer-to-Peer File Transfer

ScoutDrop is Scout's built-in file transfer system for sending files between Macs on the same local network. It works like AirDrop but runs entirely within Scout — no Apple ID, no iCloud, no internet connection required.

## How It Works

When Scout launches, it automatically begins advertising itself on the local network and browsing for other Scout instances. Nearby Macs running Scout appear in the sidebar under a **Nearby** section. To send files, drag them onto a peer in the sidebar.

## Startup

ScoutDrop starts automatically when a `MainWindowController` loads (`startScoutDrop()` is called during window setup). Two things happen:

1. **Advertise** — The app registers a Bonjour service (`_scoutdrop._udp`) with the Mac's nickname and a persistent device ID. It also starts a QUIC listener to accept incoming connections.
2. **Browse** — An `NWBrowser` discovers other Scout instances advertising the same service type.

The nickname defaults to `Host.current().localizedName` (e.g. "Jack's MacBook Pro") and can be changed in settings. The device ID is a UUID generated once and persisted across launches.

## Permissions

ScoutDrop requires **local network access**. On macOS 14+, the system prompts the user to allow local network access the first time a Bonjour service is advertised or browsed. No other permissions are needed — there is no Apple ID, iCloud, or internet requirement.

The app runs **without App Sandbox** (`com.apple.security.app-sandbox = false`). The Info.plist declares `NSLocalNetworkUsageDescription` (prompt string shown to the user) and `NSBonjourServices` (declares the `_scoutdrop._udp` service type).

No Keychain entitlements are needed — `SecKeyCreateRandomKey` and `SecItemAdd` work without sandbox entitlements when the app sandbox is disabled.

## Sidebar Integration

Discovered peers appear in the sidebar under the **Nearby** section (hidden when no peers are found). Each peer shows a laptop icon and the peer's nickname. If two peers share the same name, a 4-character device ID suffix is appended for disambiguation (e.g. "Jack's Mac (A3F2)").

Files are sent by dragging them onto a peer in the sidebar. The sidebar registers as a drop target for file URLs on nearby peer items.

## Transfer Protocol

### Transport

All communication uses **QUIC** (via Network.framework) with TLS encryption. A custom binary framer (`ScoutDropFramer`) handles message framing with a 9-byte header:

```
[1 byte: message type] [4 bytes: metadata length (BE)] [4 bytes: payload length (BE)]
```

### Flow

```
Sender                                     Receiver
  │                                           │
  ├─ startAdvertising (Bonjour + QUIC)        │
  ├─ startBrowsing (NWBrowser)                │
  │                                           ├─ startAdvertising
  │                                           ├─ startBrowsing
  │◄──────── Bonjour discovery ──────────►    │
  │                                           │
  ├─ User drags files onto peer               │
  ├─ connect() → QUIC tunnel + TLS            │
  ├─ Open control stream                      │
  ├─ Send offer (files, sizes, deviceID)      │
  │                                           ├─ Receive offer
  │                                           ├─ Show accept/decline alert
  │                                           ├─ Check for .incomplete files (resume)
  │                                           ├─ Send accept + resume offsets
  ├─ Receive accept                           │
  ├─ Open file streams (up to 4 concurrent)   │
  │   ├─ typeFileStart (fileIndex + chunk)     │
  │   ├─ typeFileData (chunks…)               ├─ Write to .incomplete file
  │   └─ typeFileEnd (SHA-256 checksum)       ├─ Verify checksum
  ├─ Send complete on control stream          ├─ Rename .incomplete → final
  │                                           ├─ Restore POSIX permissions
  └─ Done                                    └─ Done
```

### Message Types

| Type | Hex | Direction | Purpose |
|------|-----|-----------|---------|
| Offer | `0x01` | Sender → Receiver | File list, sizes, sender identity |
| Accept | `0x02` | Receiver → Sender | Confirmation + resume offsets |
| Decline | `0x03` | Receiver → Sender | Rejection |
| Complete | `0x06` | Sender → Receiver | All files sent |
| Error | `0x07` | Either | Transfer-level error |
| FileStart | `0x08` | Sender → Receiver | 2-byte file index + first chunk |
| FileData | `0x09` | Sender → Receiver | Raw file chunk (512 KB) |
| FileEnd | `0x0A` | Sender → Receiver | SHA-256 checksum + final chunk |
| FileError | `0x0B` | Receiver → Sender | Per-file error report |
| Heartbeat | `0x0C` | Sender → Receiver | Keepalive (every 30s) |

### Multiplexing

Each file transfer uses a separate QUIC stream, with up to 4 streams in flight concurrently. The first stream opened on each QUIC tunnel is the **control stream** (offers, accepts, heartbeats, completion). Subsequent streams carry file data.

### Resume Support

If a transfer is interrupted, partially received files are preserved with an `.incomplete` extension. On the next transfer attempt, the receiver reports existing byte counts in the accept message. The sender skips already-transferred bytes but still hashes the entire file for end-to-end checksum verification.

## Security

### Encryption

All data is encrypted via TLS 1.3 (embedded in QUIC). Each Scout instance generates a P-256 elliptic curve key pair on first launch, stored in the macOS Keychain. A self-signed certificate (10-year validity) is created from this key pair and used for TLS.

### Trust On First Use (TOFU)

ScoutDrop uses TOFU certificate pinning:

1. **First transfer** — The sender and receiver exchange public keys during the TLS handshake. Both sides display a 6-digit verification code derived from both keys (SHA-256 of the concatenated key hashes, canonically ordered). Users compare codes out-of-band (verbally, visually) to confirm no man-in-the-middle.
2. **Subsequent transfers** — The peer's public key hash is stored alongside its device ID. Future connections verify the peer presents the same key. If the key changes, the transfer is automatically declined with a security warning.

A peer is marked **trusted** only after a successful transfer completes (not on accept). Trusted peers skip the verification code prompt on future transfers.

### Path Traversal Protection

All received file paths are validated to ensure they stay within the destination directory. Symlink targets are also checked. Paths that would escape the download directory are rejected.

### Integrity

Every file is hashed with SHA-256 during transfer. The sender computes the hash over the entire file (including resumed bytes) and sends it with the final chunk. The receiver independently computes the same hash and rejects the file if they don't match.

## File Layout

| File | Purpose |
|------|---------|
| `Services/ScoutDropService.swift` | Actor-based service: discovery, send/receive, QUIC connections |
| `Services/ScoutDropFramer.swift` | `NWProtocolFramer` implementation for the binary wire protocol |
| `Services/ScoutDropIdentity.swift` | P-256 key generation, self-signed certificates, verification codes |
| `Services/Protocols/ScoutDropServiceProtocol.swift` | Actor protocol for testability |
| `Models/ScoutDropPeer.swift` | Discovered peer model with connection state |
| `Models/ScoutDropOffer.swift` | Incoming transfer offer for the accept/decline UI |
| `Models/ScoutDropMessage.swift` | Wire protocol message structures (Codable) |
| `Tests/ScoutDropTests/` | Frame encoding, DER encoding, verification code tests |

## Received Files

Received files are saved to `~/Downloads/ScoutDrop/`. Directory structure, symlinks, and POSIX permissions from the sender are preserved.
