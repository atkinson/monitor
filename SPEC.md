# Dell U4025QW — Monitor Control Protocol Implementation Specification

Version 1.0 · 2026-10-16 · derived from live protocol sessions on a Dell U4025QW
(firmware week 29/2024) attached to an Apple M2 Max host over Thunderbolt/USB-C
at 5120×2160@120 Hz, plus VESA MCCS/ddcutil/m1ddc reference material.

**Status legend** — every normative statement carries one of:

| Tag | Meaning |
|---|---|
| ✅ VERIFIED | Observed byte-for-byte on this panel during this investigation |
| 📖 STANDARD | VESA MCCS 2.x / ddcutil documented behavior, not re-verified here |
| ⚠️ INFERRED | Consistent with observations but not directly proven |
| ❓ OPEN | Unknown; a conforming implementation must probe or defend |

---

## 1. Scope and system model

The controllable surface of the monitor is, in layers:

```
┌──────────────────────────────────────────────────────────────┐
│ L5  Policy: HDR lock, write-verify, ramps, presets           │
│ L4  VCP registry (brightness, contrast, volume, input, …)    │
│ L3  DDC/CI commands (get/set VCP, capabilities)              │
│ L2  DDC/CI message framing + checksums                       │
│ L1  I²C transport: Apple IOAVService (DP AUX → I²C bridge)   │
└──────────────────────────────────────────────────────────────┘
```

A conforming implementation provides L1–L4 as a library and L5 as its CLI/policy
layer. Everything below is specified concretely enough to reimplement from
scratch, including behavior the public standards do not describe (reply
misalignment, the HDR lock, stale reply buffers).

---

## 2. Layer 1 — Bus and host transport

### 2.1 I²C addressing

- DDC/CI command channel: 7-bit address `0x37`. ✅ (all working traffic)
- EDID channel: 7-bit address `0x50` (not used by this spec; identify displays
  via IORegistry instead — §8). 📖
- **Mac variant**: on hosts whose external display routes through a MegaChips
  MCDP29xx DP converter (IORegistry class `AppleDCPMCDP29XX`), DDC/CI must be
  addressed at **chip address `0xB7`** instead of `0x37`. 📖 (m1ddc)
  The M2 Max host in this investigation does *not* have such a bridge
  (verified: zero IORegistry matches), and uses `0x37`.

### 2.2 Apple transport API

The host API is the semi-private `IOKit` AVService interface (not in public SDK
headers; resolve at runtime via `dlopen`/`dlsym`):

```c
IOAVServiceRef IOAVServiceCreate(CFAllocatorRef);
IOReturn IOAVServiceWriteI2C(IOAVServiceRef, uint32_t chipAddress,
                             uint32_t dataAddress, const void *buf, uint32_t len);
IOReturn IOAVServiceReadI2C (IOAVServiceRef, uint32_t chipAddress,
                             uint32_t dataAddress, void *buf, uint32_t len);
```

Normative use:

- `chipAddress` = `0x37` (or `0xB7` per §2.1).
- `dataAddress` = **`0x51` for both writes and reads** — this is the DDC/CI
  "source address" first byte, injected by the API ahead of the caller's
  buffer. ✅
- `IOAVServiceCreate` returns the default external display's service. A full
  implementation binds services to displays explicitly (§8).
- Success (`kIOReturnSuccess`) of a write means **the I²C transaction was
  ACKed at the bus level only**. It does *not* mean the monitor accepted or
  executed the command. ✅ (this is the trap that makes the HDR lock and the
  rejected writes look like successes)

### 2.3 Timing and serialization

- Default inter-operation delay: **40 ms** (`usleep` before every bus
  operation). 10 ms (m1ddc's value) works but with more misaligned reads. ✅
- Allow up to **50 ms** read wait on MCDP29xx-routed displays. 📖
- The bus is strictly **half-duplex command/response**: one logical exchange
  (query-write → read(s)) in flight at a time; no concurrent accessors.
  ⚠️ INFERRED (no concurrency test performed; DDC/CI is defined this way 📖)
- Reads may return anywhere from 0 to N useful bytes; see §7 for the parser.

---

## 3. Layer 2 — DDC/CI message framing

### 3.1 Host → monitor message

```
[0x51] [0x80|LEN] [opcode] [operand bytes × (LEN−1)] [CHECKSUM]
  │        │          │            │                      │
  │        │          │            │                      └─ XOR law, §3.3
  │        │          │            └─ payload, LEN−1 bytes
  │        └─ merged flags+length byte (this panel's convention)
  └─ injected by IOAVService as `dataAddress` (not part of the API buffer)
```

- `LEN` = number of bytes after the merged length byte, excluding checksum.
  ✅ (e.g. get-VCP has LEN=2 → `0x82`; set-VCP LEN=4 → `0x84`; caps LEN=3 → `0x83`)
- Merged-framing (`0x80|LEN`) is what this monitor's own replies use, and is
  accepted for host messages. ✅ The VESA-classic two-byte form
  (`[LEN][0x80]` separately) was **also** accepted when tried, but nothing
  gained by it; implementations should send merged form. ⚠️ INFERRED
  (the classic-form test predates a tooling-bug fix; only merged form is
  proven by the volume-write success)
- Maximum message size: keep total ≤ 36 bytes on the wire (read buffer used
  throughout: 36). ⚠️ INFERRED

### 3.2 Monitor → host message (replies)

```
[0x6E] [0x80|LEN] [opcode] [payload × (LEN−1)] [CHECKSUM]
```

Observed replies are 11 bytes for get-VCP (LEN=8) and up to 37 for
capabilities chunks. ✅

### 3.3 Checksums — two different laws, this is not a typo

| Direction | Law | Verified by |
|---|---|---|
| Host → monitor | `CHECKSUM = 0x6E ^ 0x51 ^ XOR(message bytes excl. checksum)` | ✅ volume set `62=20` landed and persisted; brightness sets land post-unlock |
| Monitor → host | `XOR(all bytes incl. 0x6E and checksum) == 0x50` | ✅ every validated reply this session |

The asymmetry is real: the monitor's own frames satisfy XOR-all = 0x50, yet it
*accepts* host frames computed with the m1ddc law (whose XOR-all = 0x6E).
The monitor does **not** validate query checksums strictly (it answers
m1ddc-checksummed queries with either law). ⚠️ INFERRED for the tolerance
claim; both laws above are directly verified where marked ✅.

### 3.4 Canonical byte vectors (all captured live)

```
GET VCP 0x10 (luminance)
  host:  51 | 82 01 10 AC            (write buffer = `82 01 10 AC`)
  reply: 6E 88 02 00 10 00 00 64 00 4B 8B
         └─── XOR of all 11 bytes = 0x50 ✅
         parse: opcode 02, vcp 10, type 00, max 0064, cur 004B (=75)

SET VCP 0x10 = 40 (0x0028)
  host:  51 | 84 03 10 00 28 80

SET VCP 0x62 = 20 (0x0014)   [lands even while HDR-locked]
  host:  51 | 84 03 62 00 14 CE

GET CAPABILITIES @ offset 0
  host:  51 | 83 F3 00 00 4F
  reply: 6E .. E3 "(prot(monitor)type(LCD)mod..(U4025QW)…"
```

---

## 4. Layer 3 — Command set

Opcodes observed in this panel's capabilities string:
`cmds(01 02 03 07 08 E3 F3)` ✅ (string partially mangled/truncated — §5.4)

| Opcode | Name | Request payload | Reply | Status |
|---|---|---|---|---|
| `0x01` | Get VCP Feature | `[01, vcp]` | opcode `0x02` frame, §4.1 | ✅ |
| `0x03` | Set VCP Feature | `[03, vcp, hi, lo]` | none (verify by re-read) | ✅ |
| `0xF3` | Get Capabilities | `[F3, offHi, offLo]` | opcode `0xE3` frames, §4.2 | ✅ |
| `0x02` | Get VCP (alt / timing table) | `[02, vcp]` | — | ❓ listed in caps, never exercised |
| `0x07` | Save settings / commit | `[07]` | — | ⚠️ sent once; no observable effect (writes persist without it) |
| `0x08` | (unknown, in caps) | — | — | ❓ |

Behavior notes:

- **No VCP-change notification.** Sets are fire-and-forget at L3; correctness
  comes from L5 write-verify (§9.3). ✅
- **Unsupported/unreadable VCP codes produce no reply** (read times out) rather
  than a VESA "unsupported code" reply. ⚠️ INFERRED (observed as timeouts on
  some probes; not exhaustively enumerated)

### 4.1 Get VCP reply payload

Payload (LEN−1 = 7 bytes after opcode; stream offsets in brackets):

```
[2] 02 opcode   [3] 00 rsv   [4] vcp   [5] type
[6,7] max  (BE16)   [8,9] current (BE16)
```

✅ Verified for VCPs 10, 12, 62, DC, D6, E7, E8, E9, F0–F2, AC, B6, CA, C6, C8.
`type` read `0x00` on every code this session.

### 4.2 Capabilities reply

Each reply carries a chunk of an ASCII, Postscript-flavored string starting at
the requested byte offset: `(prot(monitor)type(LCD)mod…(U4025QW)…vcp(…)…)`.

- Request offsets advance by `LEN−2` (chunk payload minus opcode byte). ✅
- Terminate on outer-paren closure (track depth), empty chunk, or size cap
  (2048 B). ✅ (early termination on any `)` — the naive rule — truncates
  at the first nested group)
- **This firmware's string is mangled and truncated** — it contains stray
  NUL/0x1C bytes, garbles some code hex (`12`→`@T`), and ends mid-list around
  `60(19 0F 11 )` despite more codes being readable directly. Treat caps as a
  *hint*, never as the source of truth for the VCP registry. ✅

---

## 5. Layer 4 — VCP registry (U4025QW)

Verified read/write behavior at L4 on this unit:

| VCP | Feature | Access on this panel | Max | Observed / notes | Status |
|---|---|---|---|---|---|
| `0x10` | Luminance (brightness) | get ✅ set ✅ (HDR-off only) | 100 | factory 75; HDR-lock victim | ✅ |
| `0x12` | Contrast | get ✅ set ✅ (HDR-off only) | 100 | factory 75; HDR-lock victim | ✅ |
| `0x62` | Volume | get ✅ set ✅ (always) | 100 | landed even while locked | ✅ |
| `0x60` | Input source | get ✅ set ❓ | — | live read `0x1919` → **USB-C = 0x19 (25) on this panel** (matches caps `19 0F 11`); write implemented, deliberately untested (switching away blanks the only display) | ✅/❓ |
| `0xD6` | Power mode | get ✅ (1 = on) | 5 | write deliberately untested | ⚠️ |
| `0xDC` | Color preset | get ✅ set ❌ (HDR), set ✅ (SDR) | 5 | reads `0` while HDR-locked (unmappable preset) | ✅ |
| `0x16/18/1A` | R/G/B gain | in caps; untested | 100? | — | ❓ |
| `0xE7` | KVM (Dell) | get ✅ (read `0xBC00`) | — | m1ddc values: order = `1728`, next/cycle = `65280` 📖; read encoding undocumented; writes untested here (would move the user's USB devices) | ⚠️ |
| `0xE8/E9` | PBP input / mode (Dell) | get ✅ (`11` / `0`) | — | 0xE9 set ✅: `0↔33` cycle verified 2026-10-16 via write + delayed read; 0xE8 set ✅ for `17`; **layout codes go read-silent ~2–4 s after their own write** — the §9.3 1 s verify cannot apply (see §9.3). With 0xE9=0 the 0xE8 value auto-tracks/overrides (write 16 → read 25) — set sub-input only while a mode is active ⚠️ | ✅/⚠️ |
| `0x8D` | Mute | — | — | MCCS: 1=on 2=off 📖; untested | ❓ |
| `0xF0–F2` | Dell private regs | get ✅ | 255/65535 | semantics unknown; log-only | ⚠️ |
| `0xAC,B6,CA,C6,C8` | various | get ✅ | — | values did not map to MCCS semantics; log-only | ⚠️ |

**Input codes** (`0x60`): resolved empirically — **this panel uses 0x19 (25)
for USB-C** (live read 0x1919 ✅), 0x0F DP1 / 0x11 HDMI1 per its caps. The
MCCS-standard 27 was *not* what the firmware reports. Set-side input codes
remain untested (switching the only display's input away blanks the screen —
no safe test with inaccessible OSD controls). Value is read as 16-bit with the
code in the low byte. ⚠️/❓

### 5.4 Registry discovery procedure

Because caps is unreliable here, a conforming implementation builds its
registry as: known-standard table ∪ caps hints ∩ **probed reality** (get every
candidate with the §7 parser; a code that never yields a valid frame is
absent). ✅ (this is how the table above was produced)

---

## 6. L5 policy — The HDR signal lock (the critical behavior)

### 6.1 Statement

**While the host graphics stack sends HDR (macOS "High Dynamic Range" enabled
for the display), the monitor's firmware:**

1. **ACKs every DDC/CI write at the I²C layer** (transport success), and
2. **silently drops writes to `0x10` (luminance), `0x12` (contrast), and
   `0xDC` (preset)** — the VCP never changes; and
3. keeps servicing reads of every code (live values) and writes to every other
   code (volume, input, KVM, …) normally. ✅ all three observed

This mirrors the OSD greying-out of brightness/contrast in the monitor's Smart
HDR modes: the picture mode is being dictated by the incoming signal, so the
mode-adjacent controls are locked. The preset reads `0` (not in the
`0x01–0x05` table) in this state. ✅

### 6.2 Detection heuristic (normative for implementers)

After `set(vcp)` + verify-read mismatch:

```
if set did not stick:
    if getVCP(vcp) is live and bus is otherwise healthy
       and a control VCP outside the lock set (e.g. 0x62) DOES stick:
           report: HDR signal lock suspected → offer hdr-off
```

✅ This discriminator (volume sticks, brightness doesn't) is exactly how the
lock was identified. **Scope: run the probe only for the verified lock set
(0x10/0x12/0xDC).** Layout codes 0xE7–0xE9 mismatch for an unrelated reason
(same-code read silence after their own writes, §9.3) and the probe
false-positived on 0xE8 with HDR off (observed 2026-10-16) — the shipped
`diagnoseLock` refuses codes outside the lock set.

### 6.3 Unlock / lock procedure

macOS HDR state for the display is readable and settable through the private
`MonitorPanel.framework` (same mechanism System Settings uses):

```objc
MPDisplayMgr.sharedMgr.displays          // [MPDisplay]
- (BOOL)hasHDRModes;  - (BOOL)preferHDRModes;
- (void)setPreferHDRModes:(BOOL)b;
```

Procedure: `setPreferHDRModes(false)` → wait ~2 s → DDC brightness writes
land immediately. ✅ Reverse to restore HDR (DDC brightness dies again —
that trade is inherent to the monitor, not the tool). ✅
The reference implementation is `hdr` in this repo.

macOS-side EDR dimming (software brightness while HDR stays on) is explicitly
**out of scope** for this spec (possible future extension). ❓

### 6.4 Brightness energy-confirmation gate above 75 (discovered 2026-10-16)

**Raising VCP 0x10 above 75 (the factory / ENERGY STAR default) makes the
firmware show an on-monitor confirmation — "adjusting to this value will
increase power consumption, press any button to confirm" — and the value
reverts to 75 after ~15 s if no physical button is pressed.**

- Applies to DDC writes exactly like OSD changes: the set frame is ACKed,
  the verify-read even reports the new value, then the firmware reverts on
  the confirmation timeout. ✅ (user-observed; CLI `set` verified ✓ then
  reverted) — i.e. write-verify alone is NOT sufficient proof above 75.
- All writes ≤ 75 in every session were silent. ✅
- No VCP signature of the pending-dialog state was found: 0xF0–0xF2/0xAC/
  0xB6/0xCA/0xC6/0xC8 read identically with and without the dialog. ✅
- A full read-probe of 0x01–0xFF (see `probes/vcp-scan-2026-10-16.txt`)
  found no credible suppressor code; this firmware answers most unreadable
  codes with a degenerate `0 / max 65535 / type 00` frame, so the scan is
  mostly noise — treat non-degenerate rows as the real registry. ✅
- Policy for implementations: keep ≤75 as the default operating range;
  when crossing above 75, tell the user a single press of ANY monitor
  button within ~15 s is required ( OSD buttons otherwise unnecessary),
  then re-read after the window to confirm stick-or-revert. ✅ (shipped in
  MonitorApp; `energyConfirmThreshold`)
- Downward writes and writes within an already-confirmed >75 session are
  not gated (crossing semantics). ⚠️ INFERRED (Dell documentation + user
  report; not systematically re-verified per-adjustment).

---

## 7. L1–L3 reliability model and reply parser (normative)

### 7.1 Observed failure modes

All on this panel, all reproducible ✅:

1. **Misalignment**: the reply appears in the read buffer preceded by 0–8+
   leading `0x00` bytes, varying per read.
2. **Split replies**: one reply can span two consecutive reads (tail of the
   message at the head of the next buffer).
3. **Stale repeats**: the monitor retains its last reply; reads may re-serve
   it (idempotent, harmless once checksum-matched).
4. **Empty reads**: all-zero buffer (no data ready) — must be treated as
   "retry", not "value 0". (This is the exact bug that made m1ddc print
   bogus `0` values.)
5. **Transport errors**: rare; surface the `kern_return_t`.

### 7.2 Parser algorithm

```
readMessage(opcode_expect, vcp_expect?):
    stream = []
    for attempt in 1..N:                      # N = 20, 40 ms apart
        stream += rawRead(36)                 # skip all-zero chunks
        scan i over stream:
            if stream[i] == 0x6E
               and stream[i+1] & 0x80
               and stream[i+2] == opcode_expect:
                 len  = stream[i+1] & 0x7F
                 end  = i + 2 + len           # checksum index
                 msg  = stream[i..end]
                 if XOR(msg) == 0x50                      # §3.3 reply law
                    and (no vcp_expect or msg[4] == vcp_expect):
                        return msg
    return TIMEOUT
```

Constraints: never parse by absolute buffer offsets; never accept a frame
without the XOR-0x50 check; on `vcp_expect` mismatch keep scanning (stale
frame for a different code may sit in the stream). ✅ (the algorithm shipped
in `ddcx` and survived every session read)

### 7.3 Write path

- Send the set frame **twice** (two bus writes, 40 ms apart) — m1ddc practice;
  whether one write suffices on this panel is ❓ OPEN (double-write is
  harmless and retained).
- Verify every user-visible write with a §7.2 read; never trust transport ACK
  as success. ✅

---

## 8. Display enumeration and binding

`IOAVServiceCreate` returns only the default display's service. The
implemented algorithm (✅ shipped in `ddcx`, verified on this system):

1. `CGGetOnlineDisplayList` → per non-builtin display, read
   `CoreDisplay_DisplayCreateInfoDictionary(id)` for `IODisplayLocation` +
   `kCGDisplayUUID` (virtual displays lack these — skip);
2. `IORegistryEntryCopyFromPath(location)` → the display's
   `IOMobileFramebufferShim`; take its registry entry ID;
3. Flat-walk the IOService plane recursively: when an `IOMobileFramebuffer`
   service's entry ID matches, subsequent entries are that display's DCP
   instance — take the `DCPAVServiceProxy` whose `Location` == `External`,
   build the AV service with `IOAVServiceCreateWithService`;
4. Chip address `0xB7` iff the proxy's parent `EPICProviderClass` ==
   `AppleDCPMCDP29XX` (this host: `DCPDP2XService` → `0x37` ✅).

**Implementation gotcha (cost real debugging time):** the on-disk
`CoreDisplay.framework` on modern macOS is a stub — `dlopen(path)` +
`dlsym(handle, …)` returns NULL for its symbols in a compiled binary (it
works under `swift` script execution, which masked it during prototyping).
Resolve via `dlsym(RTLD_DEFAULT /* UnsafeMutableRawPointer(bitPattern: -2) */)`
— CoreDisplay is already in the process via CoreGraphics. ✅

📖 Structure from m1ddc; N-display ordering verified only for N=1 (this
session). ❓ runtime behavior on N>1 unverified.

---

## 9. API and CLI contract

### 9.1 Library surface (Swift; other languages map 1:1)

```swift
struct DisplayTarget { let service: CFTypeRef; let chip: UInt32; let name: String }

func listDisplays() -> [DisplayTarget]
func getVCP(_ t: DisplayTarget, _ code: UInt8) throws -> VCPValue   // cur, max, type
func setVCP(_ t: DisplayTarget, _ code: UInt8, _ value: UInt16) throws  // writes ×2 + verify
func capabilities(_ t: DisplayTarget) -> String                     // §4.2 semantics
func hdrState(_ t: DisplayTarget) -> Bool
func setHDR(_ t: DisplayTarget, _ on: Bool) throws                  // §6.3
```

### 9.2 CLI verbs and exit codes

```
ddcx brightness|contrast|volume [n]     exit 0 ok / 1 failure
ddcx get|set <vcp-hex> [value]
ddcx caps | watch <vcp> <secs> | info
ddcx raw|send <hex…>                     [--ck XX --chip XX]  (diagnostics)
hdr [on|off]
```

Exit codes: `0` success · `1` transport/protocol failure · `2` usage.
`set` prints `read-back: N ✓|✗` — the ✗ line is part of the contract (§6).

### 9.3 Write-verify loop (normative)

```
set → sleep ≥ 1 s (value takes effect on next scaler cycle ⚠️)
    → verified get ×1 → if mismatch and lock-heuristic (§6.2) → emit
      "HDR signal lock suspected; run hdr off" and exit 1.
```

**Exception — layout/USB codes (0xE7/0xE8/0xE9):** the write lands, but the
panel stops answering reads *of the same code* for ~2–4 s afterwards (reads
of other codes are unaffected). ✅ (0xE9 `0↔33` cycle: verify-read timed out
at 1 s and 2 s, delayed read confirmed the value landed). Verify these codes
by writing, waiting ≥3 s, then re-reading; a read timeout right after the
write does NOT mean the write failed. Command-style values (KVM next
`0xFF00`) have no readable target state — treat the write itself as the
operation and the read-back as informational.

---

## 10. Test plan

**T1 · Framing vectors** (unit): every vector in §3.4 — encode/parse/checksum
round-trips; parser rejects bit-flipped frames (checksum), misaligned frames
recovered from `00 00 6E 88 …` streams, split frames stitched from two chunks.
**T2 · Read reliability** (integration): 100 consecutive `get 0x10`; assert
100 valid, identical values; assert zero "0" artifacts.
**T3 · Write-verify** : `set 0x10 40` SDR → sticks; `watch` 10 s stable ✅.
**T4 · Lock matrix** : HDR on → `set 0x10/0x12/0xDC` must report ✗;
`set 0x62 20` must report ✓. HDR off → all four ✓. ✅ (executed this session)
**T5 · Caps**: string contains `prot(`, `U4025QW`; terminates on depth, not
first `)`. ✅
**T6 · Power-cycle persistence**: brightness survives monitor power cycle
(SDR, unsaved) ⚠️ expected, untested.
**T7 · Input switch / KVM / PBP**: per §5 table codes; ❓ to be probed.
**T8 · Multi-display**: enumeration binds correct services ❓.

---

## 11. Open questions

1. Is the double-write (§7.3) actually required?
2. Opcode `0x02` semantics on this firmware (alt get? timing table?).
3. ~~Input-code mapping — resolve `0x19` vs `0x1B` (USB-C) empirically.~~
   **Answered:** live read `0x60` → `0x1919` — this panel reports USB-C as
   `0x19` (§5). Set-side codes still untested.
4. Behavior when the OSD menu is physically open (writes dropped? mangled?) —
   untestable here, controls inaccessible by design.
5. Whether `0xD6` writes work (deliberately never tested: would blank the
   user's screen).
6. Minimum reliable inter-operation delay (10 ms fails sometimes, 40 ms never
   failed here — the true floor is unknown).
7. EDID-over-IOAVService path (`0xA0/0x50`) as an alternative to registry
   identification.
8. Multi-display (`--display N`) runtime behavior for N > 1.

---

## Appendix A — Discovery log (how each ✅ was established)

1. `m1ddc get luminance` → `75`, but reads returned `0`/stale at random →
   suspected read path; built `ddcx` with raw hex dumps.
2. Raw dumps showed replies misaligned by variable leading zeros and split
   across reads → rolling-stream parser; derived reply checksum law
   XOR-all = 0x50 from `6E 88 02 … 8B`.
3. Every checksum-valid read said `75` before/after ACKed sets → writes
   genuinely not taking effect.
4. Checksum/framing sweep (derived-law, classic framing, alternate seeds,
   save-opcode `0x07`) — all still `75`… later found to have run against a
   stale binary (silent build failure) — **invalid experiments**, recorded
   here as methodology warnings, not evidence.
5. Volume `set 0x62 20` → **landed, persisted** → write path and framing
   proven good; lock is code-specific.
6. `0xDC` frozen at `0`, rejects all writes 1–5 → preset dictated by signal.
7. MonitorPanel `preferHDRModes` == true → `hdr off` → `set 0x10 40` lands,
   stable over 6 s watch; DC becomes writable. Root cause closed.

## Appendix B — References

- VESA DDC/CI + MCCS 2.x (opcodes, VCP codes) — via ddcutil docs
  <https://www.ddcutil.com/>
- m1ddc (framing, MCDP29xx `0xB7`, KVM/PBP Dell extras)
  <https://github.com/waydabber/m1ddc>
- alin23/mac-utils ToggleHDR + MonitorPanel headers (MPDisplay)
- Lunar, "Journey to DDC on M1 Macs" (retry philosophy)
  <https://alinpanaitiu.com/blog/journey-to-ddc-on-m1-macs>

## Appendix C — Portability notes (using this implementation on other monitors)

What is generic vs vendor-specific, as implemented:

| Component | Status | Notes |
|---|---|---|
| L1 transport, chip detection (0x37/0xB7) | generic | §2; any Apple-Silicon external display |
| L2 framing + checksums | generic | §3; host law is m1ddc's de-facto standard |
| §7.2 rolling-stream parser | generic | the m1ddc-fixing part — panel-agnostic |
| §8 discovery/binding | generic | per-host; N>1 unverified |
| 0x10 / 0x12 / 0x62 / 0x60 / 0x8D | MCCS standard | max read from each reply; USB-C codes vary per panel (0x19 here, 0x1B standard — offer both) |
| Caps parsing (§4.2) | generic | depth-tracked; treat string as hint (this firmware mangles it — others may not) |
| 0xE7 / 0xE8 / 0xE9 (KVM, PBP) | Dell | gate on probed presence |
| §6 HDR lock, §6.4 energy gate, §9.3 layout read-silence | Dell-observed | detect, don't assume: the shipped code detects all three |

Detection rule used by the GUI (§5.4 probed reality): a control is shown
only when its VCP answers with a *non-degenerate* frame. This firmware's
degenerate reply is `current 0 · max 0xFFFF · type 0x00`; other panels
typically stay silent instead — both count as absent. A silent read right
after a 0xE7–0xE9 write (§9.3) must not be classified as absence — only
the degenerate frame is negative evidence. ✅

Untested on any hardware but the reference U4025QW + M2 Max host.
