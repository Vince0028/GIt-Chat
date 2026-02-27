# GitChat — Fully Offline Mesh Chat & Video Call App

**No internet. No servers. No Wi-Fi router. Just phones talking to each other.**

GitChat is a Flutter Android app that lets nearby phones chat and video call each other with zero internet.
It uses Bluetooth, BLE, Wi-Fi Direct (P2P), and WebRTC — all running device-to-device.

---

## Table of Contents

1. [What It Does](#what-it-does)
2. [How It Works (Big Picture)](#how-it-works-big-picture)
3. [Technology Stack](#technology-stack)
4. [Network Layers Explained](#network-layers-explained)
   - [Layer 1: Nearby Connections (Mesh)](#layer-1-nearby-connections-mesh)
   - [Layer 2: Wi-Fi Direct (P2P)](#layer-2-wi-fi-direct-p2p)
   - [Layer 3: WebRTC + UDP Relay](#layer-3-webrtc--udp-relay)
5.  [The Three-Phase Call Flow](#the-three-phase-call-flow)
6.  [Mesh Protocol](#mesh-protocol)
7.  [Message System](#message-system)
8.  [Group System](#group-system)
9.  [Image Sharing](#image-sharing)
10. [Storage](#storage)
11. [Permissions](#permissions)
12. [Project Structure](#project-structure)
13. [Algorithms & Key Decisions](#algorithms--key-decisions)
14. [Limitations](#limitations)
15. [How to Build & Run](#how-to-build--run)

---

## What It Does

- **Offline text chat** — send messages to nearby phones over Bluetooth/BLE mesh
- **Offline video & audio calls** — real-time video call over Wi-Fi Direct (3-4 meter range, works without any router)
- **Group chats** — create groups, invite nearby peers, optional password protection
- **Image sharing** — send photos over the mesh (chunked or file-based transfer)
- **Message relay** — messages hop through intermediate phones (TTL-based flooding)
- **Edit & delete messages** — changes propagate to all connected peers
- **No server, no internet, no cloud** — everything is peer-to-peer on-device

---

## How It Works (Big Picture)

```
Phone A <──Bluetooth/BLE/WiFi──> Phone B <──Bluetooth/BLE/WiFi──> Phone C
         (Nearby Connections)              (Nearby Connections)
```

For **chat**: Phones form a mesh using Google's Nearby Connections API.
Every phone advertises AND discovers simultaneously (dual-loop).
Messages are JSON packets sent as byte payloads over the mesh.

For **video calls**: The app switches from Bluetooth mesh to Wi-Fi Direct.
One phone creates a Wi-Fi Direct group (becomes the access point at 192.168.49.1).
The other phone discovers and connects. Then WebRTC handles the actual audio/video.

```
CHAT MODE:     Phone A ←—BLE/BT—→ Phone B    (low bandwidth, text + small data)
                         ↓
CALL MODE:     Phone A ←—WiFi Direct—→ Phone B  (high bandwidth, video stream)
                  │                        │
                  └── WebRTC (via UDP relay on loopback) ──┘
```

---

## Technology Stack

| Component | Technology | Purpose |
|-----------|-----------|---------|
| **Framework** | Flutter (Dart) | Cross-platform UI |
| **Mesh networking** | `nearby_connections` (Google Nearby Connections API) | BLE + Bluetooth + Wi-Fi peer discovery & data transfer |
| **Video/Audio calls** | `flutter_webrtc` (WebRTC) | Real-time media streaming |
| **Wi-Fi Direct** | Android `WifiP2pManager` (native Kotlin via MethodChannel) | High-bandwidth P2P link for calls |
| **Local storage** | `hive` + `hive_flutter` | Fast NoSQL on-device database |
| **Permissions** | `permission_handler` | Runtime permission management |
| **Image picker** | `image_picker` | Camera/gallery image selection |
| **Encryption keys** | `encrypt` | Symmetric key generation for groups |
| **Unique IDs** | `uuid` | Message and user identity |
| **Fonts** | `google_fonts` (Fira Code) | Terminal/hacker-style UI |
| **File paths** | `path_provider` + `path` | App document directory access |
| **Links** | `url_launcher` | Opening URLs from chat |

---

## Network Layers Explained

### Layer 1: Nearby Connections (Mesh)

**What:** Google's Nearby Connections API (`nearby_connections` package).

**How it connects:**
- Uses `Strategy.P2P_CLUSTER` — multiple devices form a cluster, any device can talk to any other.
- Under the hood, Google's API automatically uses **Bluetooth Classic**, **BLE (Bluetooth Low Energy)**, and **Wi-Fi hotspot** to find and connect peers.
- You don't pick which radio to use — the API picks the best one automatically.

**How GitChat uses it:**
1. On app launch, the `MeshController` starts a **dual loop**:
   - `Nearby().startAdvertising()` — phone becomes visible ("I'm here")
   - `Nearby().startDiscovery()` — phone scans for others ("Who's out there?")
2. When a peer is found, `requestConnection()` is called.
3. On connection, `acceptConnection()` is called — both sides agree.
4. Now they can send `Uint8List` byte payloads (JSON-encoded packets) or file payloads.

**Anti-collision algorithm:**
When two phones discover each other at the exact same millisecond, both try to `requestConnection()` simultaneously, which causes a collision in P2P_CLUSTER mode. To fix this:
```
Random jitter: 500ms + random(0-1500ms) delay before requesting connection
```
This ensures one phone requests slightly before the other, avoiding the race condition.

**Service ID:** `com.gitchat.mesh` — only GitChat devices find each other.

**Range:** ~10-30 meters (Bluetooth), up to ~100m line-of-sight (Wi-Fi).

---

### Layer 2: Wi-Fi Direct (P2P)

**What:** Android's `WifiP2pManager` — creates a direct Wi-Fi link between two phones without any router or access point.

**Why it's needed:** Bluetooth is too slow for video. Wi-Fi Direct gives high-bandwidth, low-latency connection perfect for real-time video/audio.

**How it works:**
1. **Caller** creates a Wi-Fi Direct group → becomes the **Group Owner** at IP `192.168.49.1`
2. **Callee** discovers the group via `discoverPeers()` → connects to it
3. Now both phones are on the same local Wi-Fi network (192.168.49.x subnet)
4. They can open TCP/UDP sockets directly to each other

**Native implementation (Kotlin):**
- `MainActivity.kt` registers a `MethodChannel("com.gitchat/wifi_direct")`
- Flutter calls native Android methods: `createGroup`, `discoverAndConnect`, `getConnectionInfo`, `removeGroup`, `bindToP2pNetwork`, `unbindNetwork`
- The native code handles `WifiP2pManager` API calls, peer discovery with retry logic (up to 5 attempts with increasing delays), and process network binding

**Key IPs:**
- Group Owner (Caller): `192.168.49.1` (always this IP)
- Client (Callee): `192.168.49.x` (assigned by DHCP, detected from `p2p0` network interface)

**Range:** ~3-4 meters reliably, up to ~50m line-of-sight depending on device hardware.

---

### Layer 3: WebRTC + UDP Relay

**What:** WebRTC (`flutter_webrtc`) handles the actual audio/video encoding, decoding, and streaming. But there's a problem — and here's the clever fix.

**The Problem:**
On Android, the Wi-Fi Direct interface (`p2p0`) is NOT registered in Android's `ConnectivityManager`. WebRTC's native ICE candidate gathering only finds `127.0.0.1` (loopback) because it can't see the `p2p0` interface. So WebRTC thinks it has no way to reach the other phone.

**The Solution: UDP Relay Bridge**

GitChat runs a custom UDP relay on each phone that bridges between loopback (where WebRTC lives) and the p2p0 interface (where the other phone actually is):

```
Phone A:                                              Phone B:
┌──────────────────┐                                  ┌──────────────────┐
│ WebRTC Engine    │                                  │ WebRTC Engine    │
│ (sees 127.0.0.1) │                                  │ (sees 127.0.0.1) │
│       ↕          │                                  │       ↕          │
│ UDP Relay        │                                  │ UDP Relay        │
│ (0.0.0.0:59876)  │──── p2p0 Wi-Fi Direct ──────────│ (0.0.0.0:59876)  │
│       ↕          │   192.168.49.x ↔ 192.168.49.1   │       ↕          │
│ loopback:59876   │                                  │ loopback:59876   │
└──────────────────┘                                  └──────────────────┘
```

**How the relay works:**
1. Relay binds to `0.0.0.0:59876` (listens on ALL interfaces, including p2p0)
2. When WebRTC sends a UDP packet to `127.0.0.1:59876` (loopback), the relay catches it
3. Relay forwards that packet to the remote phone's p2p0 IP (e.g., `192.168.49.x:59876`)
4. When a packet arrives from the remote phone on p2p0, the relay forwards it to WebRTC on loopback
5. WebRTC thinks it's talking to `127.0.0.1` but actually the data goes over Wi-Fi Direct

**Synthetic ICE Candidates:**
- Real ICE candidates are **suppressed** (filtered out in `onIceCandidate`)
- Real `a=candidate:` lines are **stripped from SDP** before sending
- A **synthetic** candidate is injected: `candidate:relay 1 udp 2130706431 127.0.0.1 59876 typ host`
- This tells the remote WebRTC to send media to `127.0.0.1:59876` — which is our relay
- The relay transparently handles the rest

**WebRTC Configuration:**
```dart
{
  'iceServers': [],           // No STUN/TURN — we're offline
  'sdpSemantics': 'unified-plan',
  'iceCandidatePoolSize': 0,  // No need to pre-gather
}
```

**Media constraints:**
- Audio: echo cancellation, noise suppression, auto gain control (all ON)
- Video: 640x480 @ 24fps (max 30fps), front-facing camera

---

## The Three-Phase Call Flow

This is the core algorithm that makes offline video calls work.

### Phase 1: Call Invite (over Bluetooth mesh)

```
Caller                              Callee
  │                                   │
  │── callOffer (via NC mesh) ───────→│  "Hey, want a video call?"
  │                                   │
  │←── callAnswer (via NC mesh) ──────│  "Yes, accepted!"
  │                                   │
  │── iceCandidate/ready (mesh) ─────→│  "OK, switching to Wi-Fi Direct..."
  │                                   │
```

- Call invite and acceptance happen over the existing Bluetooth/BLE mesh (Nearby Connections)
- This works at any mesh range (10-30m)
- Once both agree, they move to Phase 2

### Phase 2: Wi-Fi Direct + TCP Signaling

```
Caller                              Callee
  │                                   │
  │ stopMesh()                        │ (waits 4 seconds)
  │ removeGroup() (cleanup)           │ stopMesh()
  │ createGroup()                     │ removeGroup() (cleanup)
  │ (becomes 192.168.49.1)            │ discoverAndConnect()
  │                                   │ (gets 192.168.49.x)
  │ TCP server on :29876              │
  │←── TCP connect ──────────────────│
  │                                   │
  │── p2pInfo {ip: 192.168.49.1} ───→│
  │←── p2pInfo {ip: 192.168.49.x} ───│
  │                                   │
```

1. **Both phones stop the mesh** — this releases the Wi-Fi adapter so Wi-Fi Direct can use it
2. **Caller creates a Wi-Fi Direct group** — becomes group owner at 192.168.49.1
3. **Callee discovers and connects** to the group (up to 3 retries, plus 20-poll fallback)
4. **Both detect their p2p0 IP** by scanning network interfaces for `p2p` in the name or `192.168.49.x` addresses
5. **Caller starts a TCP server** on port 29876 (bound to p2p0 IP)
6. **Callee connects** TCP to 192.168.49.1:29876 (source-bound to their p2p0 IP for correct routing)
7. **They exchange p2p0 IPs** over TCP — now both know each other's real Wi-Fi Direct addresses

### Phase 3: UDP Relay + WebRTC

```
Caller                              Callee
  │                                   │
  │ startRelay()                      │ startRelay() (started earlier)
  │ createPeerConnection()            │
  │ getUserMedia(cam+mic)             │
  │ createOffer()                     │
  │── SDP offer (via TCP) ──────────→│
  │── synthetic ICE candidate ──────→│ setRemoteDescription()
  │                                   │ getUserMedia(cam+mic)
  │                                   │ createAnswer()
  │←── SDP answer (via TCP) ─────────│
  │←── synthetic ICE candidate ──────│
  │                                   │
  │ setRemoteDescription()            │
  │                                   │
  │    *** ICE CONNECTED ***          │
  │    *** MEDIA FLOWING ***          │
  │                                   │
  │←═══ UDP relay (p2p0) ═══════════→│  Audio/Video stream
  │                                   │
```

1. **UDP relay starts** on both phones (port 59876, bound to 0.0.0.0)
2. **Caller creates WebRTC offer**, strips all real ICE candidates from SDP
3. **SDP offer sent over TCP** to callee
4. **Both send synthetic ICE candidates** pointing to `127.0.0.1:59876` (their local relay)
5. **Callee creates answer**, strips candidates, sends back over TCP
6. **WebRTC connects** — sends media to `127.0.0.1:59876`
7. **Relay bridges** loopback ↔ p2p0 — video and audio flow between phones

### After Call Ends:
1. WebRTC peer connection closed
2. Media streams stopped
3. TCP socket closed
4. UDP relay stopped
5. Wi-Fi Direct group removed
6. **Mesh restarts** automatically (2-second delay, then `startMesh()` again)

---

## Mesh Protocol

All data sent over the Nearby Connections mesh uses a packet format:

```json
{
  "type": 0,
  "payload": { ... }
}
```

### Packet Types

| Type Index | Name | Purpose |
|-----------|------|---------|
| 0 | `message` | Chat text message |
| 1 | `groupInvite` | Invite peers to join a group |
| 2 | `groupJoinAck` | Acknowledge joining a group |
| 3 | `messageEdit` | Edit an existing message |
| 4 | `messageDelete` | Delete a message |
| 5 | `imageMetadata` | Metadata for a large image file transfer |
| 6 | `imageChunk` | One chunk of a base64-encoded image |
| 7 | `callOffer` | "I want to call you" |
| 8 | `callAnswer` | "I accept/reject the call" |
| 9 | `iceCandidate` | WebRTC ICE candidate or "ready" signal |
| 10 | `callEnd` | End the call |

### Packet Routing Algorithm

```
Receive packet from Peer X
  │
  ├── Is it a message?
  │     ├── Already seen this ID? → DROP (deduplication)
  │     ├── Is it for me? (my username, my group, or broadcast) → SAVE + DISPLAY
  │     └── TTL > 0? → RELAY to all peers EXCEPT Peer X (TTL - 1)
  │
  ├── Is it a group invite?
  │     ├── Already a member? → IGNORE
  │     ├── Has password? → SHOW PASSWORD PROMPT
  │     └── No password? → AUTO-JOIN + SAVE
  │
  ├── Is it a call signal?
  │     └── Forward to CallService via stream
  │
  └── Is it an edit/delete?
        └── Update local storage + notify UI
```

### Deduplication

Every message has a UUID (`uuid` package). A `Set<String> _seenMessageIds` tracks all IDs ever received. If a message ID was already seen, it's dropped. This prevents infinite loops when messages relay through the mesh.

### TTL (Time To Live)

Default TTL = 3. Each relay hop decrements by 1. When TTL hits 0, the message stops relaying. This limits how far a message can travel:

```
Phone A → Phone B → Phone C → Phone D   (3 hops max)
TTL=3     TTL=2     TTL=1     TTL=0 (stop)
```

---

## Message System

### Message Model (`ChatMessage`)

```dart
{
  id: "uuid-string",        // Unique message ID
  from: "username",          // Sender's username
  to: "username|broadcast",  // Recipient or "broadcast" for everyone
  body: "message text",      // Message content (or base64 image, or file path)
  timestamp: 1234567890,     // Unix timestamp in milliseconds
  ttl: 3,                    // Relay hops remaining
  groupId: "MESH_ABC123",   // null for broadcast, group ID for group messages
  isRelayed: false,          // Was this relayed by another peer?
  isEdited: false,           // Has this been edited?
  isDeleted: false,          // Has this been soft-deleted?
  messageType: "text"        // "text" | "image" | "image_file" | "link"
}
```

### Message Types

| Type | Body Contains |
|------|--------------|
| `text` | Plain text string |
| `image` | Base64-encoded image data |
| `image_file` | File path to saved image on disk |
| `link` | URL string (auto-detected) |

---

## Group System

### Group Model (`MeshGroup`)

```dart
{
  id: "MESH_XXXXXX",          // Random 6-char alphanumeric ID prefixed with "MESH_"
  name: "APC_HACKERS",        // Display name
  createdBy: "username",      // Creator
  createdAt: 1234567890,      // Unix timestamp
  members: ["user1", "user2"], // List of member usernames
  symmetricKey: "base64...",   // 256-bit symmetric key (for future encryption)
  password: "optional"         // Optional join password
}
```

### Group Creation Flow

1. User enters group name (optional password)
2. Random group ID generated: `MESH_` + 6 random chars from `A-Z0-9`
3. 256-bit symmetric key generated: 32 random bytes → base64
4. Group saved locally to Hive
5. Group invite broadcasted to all connected mesh peers

### Group Join Flow

**No password:**
1. Peer receives `groupInvite` packet
2. Checks if already a member → skip
3. Auto-saves group locally
4. Shows snackbar notification

**With password:**
1. Peer receives `groupInvite` packet
2. Detects `password` field is set
3. Shows password dialog
4. If correct → joins. If wrong → rejected.

---

## Image Sharing

Two methods, used based on image size:

### Method 1: Chunked Base64 (Small-Medium Images)

1. Image converted to base64 string
2. Split into chunks of 28,000 bytes each
3. Each chunk sent as a `imageChunk` packet with metadata:
   ```json
   {
     "messageId": "uuid",
     "chunkIndex": 0,
     "totalChunks": 5,
     "data": "base64chunk...",
     "meta": { "from": "user", "to": "broadcast", "groupId": "..." }
   }
   ```
4. Receiver collects all chunks in a `Map<int, String>`
5. When all chunks arrive → concatenate in order → save as ChatMessage

### Method 2: File Payload (Large Images)

1. Image saved to temp file
2. `Nearby().sendFilePayload()` used (uses Wi-Fi Direct under the hood for large files)
3. Separate `imageMetadata` packet sent with `payloadId` linking to the file
4. Receiver gets file via `onPayLoadRecieved` (FILE type)
5. When both file AND metadata arrive → copy to `mesh_images/` directory → emit as message

### Progress Tracking

File transfers report progress via `onPayloadTransferUpdate`:
```
bytesTransferred / totalBytes = progress (0.0 to 1.0)
```
This is exposed in the UI as a download progress indicator.

---

## Storage

**Technology:** Hive (lightweight NoSQL, pure Dart, fast, no native dependencies)

### Hive Boxes

| Box Name | Type | Contents |
|----------|------|----------|
| `messages` | `Box<ChatMessage>` | All chat messages (keyed by message ID) |
| `groups` | `Box<MeshGroup>` | All groups user is part of |
| `profile` | `Box` (dynamic) | Username + user ID |

### Storage Operations

- `saveMessage()` / `editMessage()` / `deleteMessage()` — CRUD for messages
- `saveGroup()` / `deleteGroup()` / `addMemberToGroup()` — CRUD for groups
- `getMessages(groupId)` — filter messages by group
- `getMessages(peerId)` — filter messages by DM peer
- `isGroupMember(groupId)` — check membership
- `getLastGroupMessage(groupId)` — for home screen preview

Messages support **soft delete** — `isDeleted` flag is set to true, message remains in storage.
Edits update the `body` field in-place and set `isEdited = true`.

---

## Permissions

GitChat needs these Android permissions to function:

| Permission | Why |
|-----------|-----|
| `Bluetooth Scan` | Discover nearby devices via BLE |
| `Bluetooth Connect` | Connect to discovered peers |
| `Bluetooth Advertise` | Make this phone visible to others |
| `Location` | Required by Android for BLE scanning (Android < 12) and Wi-Fi Direct |
| `Nearby Wi-Fi Devices` | Required for Wi-Fi Direct on Android 13+ |
| `Camera` | Video calls |
| `Microphone` | Audio/video calls |

**Location Services (GPS toggle)** must also be ON — Android blocks BLE scanning if it's off.

The app shows a permission modal on first launch that explains what's needed and requests everything at once.

---

## Project Structure

```
lib/
├── main.dart                         # App entry point, MeshController init
├── models/
│   ├── message.dart                  # ChatMessage model (Hive-persisted)
│   ├── message.g.dart                # Hive TypeAdapter (generated)
│   ├── group.dart                    # MeshGroup model (Hive-persisted)
│   └── group.g.dart                  # Hive TypeAdapter (generated)
├── screens/
│   ├── home_screen.dart              # Group list, peer status, navigation
│   ├── chat_screen.dart              # Chat UI, message input, call button
│   ├── call_screen.dart              # Video/audio call UI with debug log
│   ├── create_group_screen.dart      # Group creation form
│   ├── onboarding_screen.dart        # First-launch username setup
│   └── permission_modal.dart         # Permission request bottom sheet
├── services/
│   ├── mesh_controller.dart          # Core mesh logic (826 lines)
│   ├── call_service.dart             # WebRTC + Wi-Fi Direct call logic (988 lines)
│   ├── wifi_direct_service.dart      # Flutter ↔ native Wi-Fi Direct bridge
│   ├── storage_service.dart          # Hive database wrapper
│   └── permission_service.dart       # Android permission handling
└── theme/
    └── app_theme.dart                # Dark terminal-style theme (Fira Code)

android/app/src/main/kotlin/.../
└── MainActivity.kt                   # Native Wi-Fi Direct implementation (332 lines)
```

---

## Algorithms & Key Decisions

### 1. Dual-Loop Mesh (Advertise + Discover)

Every phone runs BOTH advertising and discovery at the same time. This means any phone can connect to any other phone regardless of who was turned on first. The `P2P_CLUSTER` strategy supports this — unlike `P2P_STAR` which requires a fixed host.

### 2. Random Jitter Anti-Collision

When Phone A discovers Phone B, AND Phone B discovers Phone A at the same time, both call `requestConnection()` simultaneously. Google's Nearby Connections can't handle this and drops both. Fix:

```dart
await Future.delayed(Duration(milliseconds: 500 + Random().nextInt(1500)));
```

Random delay of 500-2000ms before requesting. One phone always wins the race.

### 3. Mesh Teardown → Wi-Fi Direct → Mesh Restart

The Bluetooth mesh and Wi-Fi Direct can't run at the same time on most Android devices (they share the Wi-Fi adapter). So for calls:
1. Stop the mesh
2. Start Wi-Fi Direct
3. Do the call
4. Remove Wi-Fi Direct group
5. Restart the mesh

This means **during a call, no mesh chat is possible** — the mesh resumes after.

### 4. UDP Relay Trick (the clever bit)

Android's `p2p0` interface is invisible to `ConnectivityManager`, so WebRTC's ICE can't gather candidates on it. Solutions considered:

- `bindProcessToNetwork(p2pNetwork)` — implemented in native code but unreliable (p2p0 often not in ConnectivityManager)
- Custom STUN/TURN server — defeats the purpose of being offline
- **UDP relay on loopback** — WebRTC talks to `127.0.0.1`, relay forwards to real p2p0 IP ← CHOSEN

This is transparent to WebRTC. It thinks it's doing a normal local connection. The relay handles all the routing.

### 5. Synthetic ICE Candidates

Instead of letting WebRTC discover candidates (which would be 127.0.0.1 only), we:
1. **Suppress** all real `onIceCandidate` callbacks (don't send them)
2. **Strip** all `a=candidate:` lines from SDP offers/answers
3. **Inject** a fake high-priority candidate: `candidate:relay 1 udp 2130706431 127.0.0.1 59876 typ host`

This candidate has priority `2130706431` (maximum for host type), so WebRTC uses it immediately.

### 6. TCP Signaling Channel

WebRTC needs to exchange SDP offers/answers. Normally this goes through a signaling server on the internet. We use a TCP socket over Wi-Fi Direct instead:

- Caller opens TCP server on port 29876 (bound to p2p0 IP)
- Callee connects to 192.168.49.1:29876 (source-bound to their p2p0 IP)
- Both send JSON-per-line signals: `{"signalType": "offer", "sdp": "..."}\n`
- This replaces the entire signaling server

### 7. SDP Candidate Stripping

```dart
String _stripCandidatesFromSdp(String sdp) {
  final lines = sdp.split('\n');
  final filtered = lines.where((l) => !l.trimLeft().startsWith('a=candidate:')).toList();
  return filtered.join('\n');
}
```

Removes all `a=candidate:` lines from SDP. Only synthetic candidates are used.

### 8. p2p0 Interface Detection

Scans all network interfaces up to 30 times (500ms apart = 15 second timeout):
```dart
for (final iface in interfaces) {
  if (iface.name.contains('p2p') || addr.address.startsWith('192.168.49')) {
    _localP2pIp = addr.address;
  }
}
```

Looks for interface named "p2p*" or IP starting with "192.168.49".

### 9. Callee TCP Source Binding

```dart
Socket.connect(groupOwnerIp, port, sourceAddress: InternetAddress(localP2pIp));
```

Forces the TCP connection to go through the p2p0 interface. Without this, Android might route it through the wrong interface (mobile data, regular Wi-Fi, etc).

### 10. Discovery Retry with Increasing Delay

Callee retries Wi-Fi Direct discovery up to 3 times. If that fails, polls `getConnectionInfo()` every 2 seconds for up to 20 attempts (40 seconds). The native Kotlin code also retries peer discovery 5 times with increasing delays (3s, 5s, 7s, 9s, 11s).

### 11. Message Flooding with TTL

Classic flooding algorithm:
1. Receive message
2. Check dedup set (seen before? drop)
3. Process locally if addressed to me
4. If TTL > 0: relay to all peers EXCEPT source, with TTL-1
5. Add to dedup set

This ensures every reachable node gets the message within TTL hops.

### 12. Image Chunking

Large base64 strings can't fit in a single Nearby Connections byte payload. Solution:
- Chunk size: 28,000 bytes per chunk (leaves room for JSON wrapper overhead)
- Metadata attached to chunk 0 (sender, recipient, group info)
- Receiver assembles chunks in order by index
- If any chunk is missing, image is dropped

---

## Limitations

| Limitation | Reason |
|-----------|--------|
| **Android only** | Wi-Fi Direct and Nearby Connections don't work on iOS the same way |
| **~3-4m for video calls** | Wi-Fi Direct range depends on hardware; works reliably at close range |
| **No chat during calls** | Mesh stops when Wi-Fi Direct takes over the adapter |
| **1-on-1 calls only** | WebRTC peer connection is between exactly 2 phones |
| **No offline message queue** | If a peer is unreachable, the message is lost (no store-and-forward) |
| **No end-to-end encryption yet** | Symmetric keys are generated but encryption isn't applied to message bodies yet |
| **Image quality limited** | Base64 chunking over BLE is slow for large images |

---

## How to Build & Run

### Prerequisites
- Flutter SDK 3.10.1+
- Android Studio / VS Code
- Physical Android device (NOT emulator — Bluetooth and Wi-Fi Direct need real hardware)
- Two Android phones to test

### Steps

```bash
# Clone the repo
git clone <repo-url>
cd git_chat

# Get dependencies
flutter pub get

# Generate Hive type adapters (if needed)
flutter pub run build_runner build

# Run on device
flutter run
```

### First Launch
1. App shows permission modal → tap "Grant Permissions"
2. Enter your username → tap enter
3. Mesh starts automatically (advertising + discovering)
4. Do the same on the second phone
5. Both phones should connect within ~10 seconds
6. Create a group or use the broadcast chat
7. For video call: open a chat → tap the video/phone icon

### Testing Video Calls
1. Phone A: Open chat → tap video call button
2. Phone B: Incoming call dialog appears → tap "Accept"
3. Both phones: Debug log shows the three-phase process
4. Wait ~30-60 seconds for Wi-Fi Direct to form and WebRTC to connect
5. Video/audio should start flowing

---

## Ports Used

| Port | Protocol | Purpose |
|------|----------|---------|
| 29876 | TCP | WebRTC signaling (SDP exchange) over Wi-Fi Direct |
| 59876 | UDP | Media relay (bridges loopback ↔ p2p0 for WebRTC) |

---

## Summary

GitChat is a **zero-infrastructure** chat and video call app. Here's what makes it work:

1. **Nearby Connections** (Bluetooth + BLE + Wi-Fi) → mesh network for chat
2. **Wi-Fi Direct** → high-bandwidth P2P link for video calls
3. **WebRTC** → real-time audio/video encoding and streaming
4. **UDP Relay** → bridges WebRTC's loopback to Wi-Fi Direct's p2p0 interface
5. **TCP Signaling** → replaces internet-based signaling servers
6. **Synthetic ICE** → tricks WebRTC into using the relay instead of real (broken) candidates
7. **Hive** → fast local storage for messages, groups, and user profile
8. **TTL Flooding** → messages hop through intermediate phones

No servers. No internet. No cloud. Just two phones, some radio waves, and a lot of clever engineering.
