#!/usr/bin/env python3
"""
Complete analysis of capture_20260414_011807.json
Outputs every packet in detail, auth sequence, init sequence, wake event,
and comparison with our SDK.
"""
import sys
import json

sys.stdout.reconfigure(encoding='utf-8')

CAPTURE = r"c:\CodeProjects\unofficial-even-g2-local-assistant\reverse-engineering\tools\results\capture_20260414_011807.json"

with open(CAPTURE, "r", encoding="utf-8") as f:
    data = json.load(f)

packets = data["decoded_packets"]

# ============================================================================
# Helper: find index of first 0x07-0x01 event packet (the "Hey Even" wake)
# ============================================================================
wake_idx = None
for i, p in enumerate(packets):
    if p["service_id"] == "0x07-0x01":
        wake_idx = i
        break

print("=" * 100)
print("SECTION 1: Every Phone->Device packet from pkt 0 to first 'Hey Even' event")
print("=" * 100)
print(f"\nFirst 0x07-0x01 event at index {wake_idx}, pkt_num={packets[wake_idx]['pkt_num'] if wake_idx else 'NOT FOUND'}\n")

phone_to_device_before_wake = []
for i, p in enumerate(packets):
    if wake_idx is not None and i >= wake_idx:
        break
    if p["direction"] == "Phone->Device":
        phone_to_device_before_wake.append(p)

print(f"Total Phone->Device packets before wake: {len(phone_to_device_before_wake)}\n")
print(f"{'IDX':>4} {'PKT#':>6} {'SEQ':>4} {'SERVICE':>10} {'LEN':>5}  PAYLOAD_HEX")
print("-" * 100)
for idx, p in enumerate(phone_to_device_before_wake):
    print(f"{idx:4d} {p['pkt_num']:6d} {p['seq']:4d} {p['service_id']:>10} {p['payload_len']:5d}  {p['payload_hex']}")

print()

# ============================================================================
# SECTION 2: Auth sequence
# ============================================================================
print("=" * 100)
print("SECTION 2: The auth sequence (service 0x80)")
print("=" * 100)

# Collect all 0x80 packets at the start
auth_packets = []
auth_done = False
for p in packets:
    sid = p["service_id"]
    # Auth is the initial 0x80-* exchange before any other service appears
    if sid.startswith("0x80"):
        auth_packets.append(p)
    elif not sid.startswith("0x80") and len(auth_packets) > 0:
        # Check if we've seen non-0x80 packets yet
        # Auth ends when we see the first non-0x80 service
        # But heartbeats (0x80) can occur later too, so let's gather contiguous 0x80
        break

print(f"\nContiguous 0x80 packets at start of session: {len(auth_packets)}\n")

# Let's also find ALL 0x80 packets before wake to separate auth from heartbeats
all_80_before_wake = []
non_80_before_wake = []
for i, p in enumerate(packets):
    if wake_idx is not None and i >= wake_idx:
        break
    if p["service_id"].startswith("0x80"):
        all_80_before_wake.append(p)
    else:
        non_80_before_wake.append(p)

print(f"Total 0x80 packets before wake: {len(all_80_before_wake)}")
print(f"Total non-0x80 packets before wake: {len(non_80_before_wake)}\n")

print("--- Auth packets (contiguous 0x80 at session start) ---")
print(f"{'IDX':>4} {'PKT#':>6} {'DIR':>16} {'SERVICE':>10} {'SEQ':>4} {'LEN':>5}  PAYLOAD_HEX")
print("-" * 100)
for idx, p in enumerate(auth_packets):
    print(f"{idx:4d} {p['pkt_num']:6d} {p['direction']:>16} {p['service_id']:>10} {p['seq']:4d} {p['payload_len']:5d}  {p['payload_hex']}")

# Now let's also look at all 0x80 packets before wake to identify heartbeats vs auth
print("\n--- ALL 0x80 packets before wake ---")
print(f"{'IDX':>4} {'PKT#':>6} {'DIR':>16} {'SERVICE':>10} {'SEQ':>4} {'LEN':>5}  PAYLOAD_HEX")
print("-" * 100)
for idx, p in enumerate(all_80_before_wake):
    print(f"{idx:4d} {p['pkt_num']:6d} {p['direction']:>16} {p['service_id']:>10} {p['seq']:4d} {p['payload_len']:5d}  {p['payload_hex']}")

# Identify the handshake pattern
print("\n--- Auth handshake analysis ---")
phone_auth = [p for p in auth_packets if p["direction"] == "Phone->Device"]
device_auth = [p for p in auth_packets if p["direction"] == "Device->Phone"]
print(f"Phone->Device auth packets: {len(phone_auth)}")
print(f"Device->Phone auth packets: {len(device_auth)}")
print()

# Show request/response pairs
print("Auth request/response pairs:")
print("-" * 100)
for p in auth_packets:
    arrow = ">>>" if p["direction"] == "Phone->Device" else "<<<"
    print(f"  {arrow} pkt={p['pkt_num']:6d}  seq={p['seq']:4d}  {p['service_id']:>10}  len={p['payload_len']:3d}  {p['payload_hex']}")

# Compare with SDK auth packets
print("\n--- SDK auth.dart expected packets ---")
print("Auth 1: service=0x80-0x00 payload=0804100c1a0408011004  (after header, before CRC)")
print("Auth 2: service=0x80-0x20 payload=0805100e22020801       (before CRC, note: msgId=0x0E)")
print("Auth 3: service=0x80-0x20 payload=08800110{msgId}820811{08+ts+10+tz}")
print("Auth 4: service=0x80-0x00 payload=0804101012040801{10}{04}")
print("Auth 5: service=0x80-0x00 payload=080410111a0408011004")
print("Auth 6: service=0x80-0x20 payload=0805101222020801")
print("Auth 7: service=0x80-0x20 payload=08800110{msgId}820811{08+ts+10+tz}")

print()

# ============================================================================
# SECTION 3: Init sequence
# ============================================================================
print("=" * 100)
print("SECTION 3: Init sequence — every non-0x80-heartbeat Phone->Device after auth")
print("=" * 100)

# Find where auth ends (first non-0x80 packet)
auth_end_idx = None
for i, p in enumerate(packets):
    if not p["service_id"].startswith("0x80"):
        auth_end_idx = i
        break

print(f"\nAuth ends at packet index {auth_end_idx}, pkt_num={packets[auth_end_idx]['pkt_num']}")
print()

# All Phone->Device packets after auth and before wake
init_packets = []
for i in range(auth_end_idx, len(packets)):
    if wake_idx is not None and i >= wake_idx:
        break
    p = packets[i]
    if p["direction"] == "Phone->Device":
        init_packets.append(p)

# Separate true init from heartbeats
# Heartbeats are 0x80-0x00 with payload starting 080e (type=14)
init_non_hb = []
init_hb = []
for p in init_packets:
    if p["service_id"] == "0x80-0x00" and p["payload_hex"].startswith("080e"):
        init_hb.append(p)
    elif p["service_id"] == "0x80-0x01":
        init_hb.append(p)  # 0x80-0x01 = device heartbeat responses
    else:
        init_non_hb.append(p)

# Also include 0x80-0x20 and 0x80-0x00 packets in init that aren't heartbeats
# The second auth handshake after the contiguous block
print(f"Total Phone->Device after auth, before wake: {len(init_packets)}")
print(f"  Non-heartbeat init packets: {len(init_non_hb)}")
print(f"  Heartbeat packets (0x80 type=14): {len(init_hb)}")
print()

print("--- All Phone->Device init packets (non-heartbeat) ---")
print(f"{'IDX':>4} {'PKT#':>6} {'SEQ':>4} {'SERVICE':>10} {'LEN':>5}  PAYLOAD_HEX")
print("-" * 100)
for idx, p in enumerate(init_non_hb):
    print(f"{idx:4d} {p['pkt_num']:6d} {p['seq']:4d} {p['service_id']:>10} {p['payload_len']:5d}  {p['payload_hex']}")

print("\n--- All Phone->Device init packets (INCLUDING heartbeats) ---")
print(f"{'IDX':>4} {'PKT#':>6} {'SEQ':>4} {'SERVICE':>10} {'LEN':>5}  PAYLOAD_HEX")
print("-" * 100)
for idx, p in enumerate(init_packets):
    print(f"{idx:4d} {p['pkt_num']:6d} {p['seq']:4d} {p['service_id']:>10} {p['payload_len']:5d}  {p['payload_hex']}")

# Also show Device->Phone responses in the init window
print("\n--- Device->Phone responses in init window ---")
init_responses = []
for i in range(auth_end_idx, len(packets)):
    if wake_idx is not None and i >= wake_idx:
        break
    p = packets[i]
    if p["direction"] == "Device->Phone":
        init_responses.append(p)

print(f"{'IDX':>4} {'PKT#':>6} {'SEQ':>4} {'SERVICE':>10} {'LEN':>5}  PAYLOAD_HEX")
print("-" * 100)
for idx, p in enumerate(init_responses):
    print(f"{idx:4d} {p['pkt_num']:6d} {p['seq']:4d} {p['service_id']:>10} {p['payload_len']:5d}  {p['payload_hex']}")

print()

# ============================================================================
# SECTION 4: The wake event
# ============================================================================
print("=" * 100)
print("SECTION 4: The wake event (0x07-0x01)")
print("=" * 100)

if wake_idx is not None:
    wake_pkt = packets[wake_idx]
    print(f"\nWake packet:")
    print(f"  pkt_num:     {wake_pkt['pkt_num']}")
    print(f"  direction:   {wake_pkt['direction']}")
    print(f"  service_id:  {wake_pkt['service_id']}")
    print(f"  seq:         {wake_pkt['seq']}")
    print(f"  crc_ok:      {wake_pkt['crc_ok']}")
    print(f"  payload_hex: {wake_pkt['payload_hex']}")
    print(f"  payload_len: {wake_pkt['payload_len']}")
    if wake_pkt.get("protobuf"):
        print(f"  protobuf:    {json.dumps(wake_pkt['protobuf'], indent=4)}")

    # What comes right after the wake?
    print("\n--- Packets immediately after wake (next 20) ---")
    print(f"{'IDX':>4} {'PKT#':>6} {'DIR':>16} {'SERVICE':>10} {'SEQ':>4} {'LEN':>5}  PAYLOAD_HEX")
    print("-" * 120)
    for j in range(wake_idx, min(wake_idx + 20, len(packets))):
        p = packets[j]
        print(f"{j:4d} {p['pkt_num']:6d} {p['direction']:>16} {p['service_id']:>10} {p['seq']:4d} {p['payload_len']:5d}  {p['payload_hex']}")

    # Show all 0x07-0x01 event packets
    print("\n--- All 0x07-0x01 event packets ---")
    print(f"{'IDX':>4} {'PKT#':>6} {'SEQ':>4} {'LEN':>5}  PAYLOAD_HEX")
    print("-" * 100)
    for i, p in enumerate(packets):
        if p["service_id"] == "0x07-0x01":
            print(f"{i:4d} {p['pkt_num']:6d} {p['seq']:4d} {p['payload_len']:5d}  {p['payload_hex']}")

    # Phone responses to wake
    print("\n--- Phone->Device packets AFTER wake (0x07-0x20) ---")
    print(f"{'IDX':>4} {'PKT#':>6} {'SEQ':>4} {'LEN':>5}  PAYLOAD_HEX")
    print("-" * 100)
    for i in range(wake_idx, len(packets)):
        p = packets[i]
        if p["direction"] == "Phone->Device" and p["service_id"] == "0x07-0x20":
            print(f"{i:4d} {p['pkt_num']:6d} {p['seq']:4d} {p['payload_len']:5d}  {p['payload_hex']}")

    # All Phone->Device after wake
    print("\n--- ALL Phone->Device packets after wake ---")
    print(f"{'IDX':>4} {'PKT#':>6} {'SEQ':>4} {'SERVICE':>10} {'LEN':>5}  PAYLOAD_HEX")
    print("-" * 120)
    for i in range(wake_idx, len(packets)):
        p = packets[i]
        if p["direction"] == "Phone->Device":
            print(f"{i:4d} {p['pkt_num']:6d} {p['seq']:4d} {p['service_id']:>10} {p['payload_len']:5d}  {p['payload_hex']}")

print()

# ============================================================================
# SECTION 5: Compare with our SDK
# ============================================================================
print("=" * 100)
print("SECTION 5: SDK comparison")
print("=" * 100)

print("\n--- SDK auth.dart: 7 auth packets ---")
print("""
Auth sends 7 packets with seq 1-7:

Pkt1: seq=1, svc=0x80-0x00
  hdr: AA 21 01 0C 01 01 80 00
  payload: 08 04 10 0C 1A 04 08 01 10 04
  (type=4, msgId=12, field3={f1=1, f2=4})

Pkt2: seq=2, svc=0x80-0x20
  hdr: AA 21 02 0A 01 01 80 20
  payload: 08 05 10 0E 22 02 08 02
  (type=5, msgId=14, field4={f1=2})

Pkt3: seq=3, svc=0x80-0x20
  hdr: AA 21 03 {len} 01 01 80 20
  payload: 08 80 01 10 0F 82 08 11 08 {ts_varint} 10 {tz_varint}
  (type=128, msgId=15, field128={f1=timestamp, f2=tz_quarters})

Pkt4: seq=4, svc=0x80-0x00
  hdr: AA 21 04 0C 01 01 80 00
  payload: 08 04 10 10 1A 04 08 01 10 04
  (type=4, msgId=16, field3={f1=1, f2=4})

Pkt5: seq=5, svc=0x80-0x00
  hdr: AA 21 05 0C 01 01 80 00
  payload: 08 04 10 11 1A 04 08 01 10 04
  (type=4, msgId=17, field3={f1=1, f2=4})

Pkt6: seq=6, svc=0x80-0x20
  hdr: AA 21 06 0A 01 01 80 20
  payload: 08 05 10 12 22 02 08 01
  (type=5, msgId=18, field4={f1=1})

Pkt7: seq=7, svc=0x80-0x20
  hdr: AA 21 07 {len} 01 01 80 20
  payload: 08 80 01 10 13 82 08 {inner_len} 08 {ts_varint} 10 {tz_varint}
  (type=128, msgId=19, field128={f1=timestamp, f2=tz_quarters})
""")

print("\n--- SDK _initServices: packets after auth ---")
print("""
After auth (seq starts at 8), _initServices sends:

 1. 0x80-0x00 type=4  (second auth handshake) payload: 08 04 10 {msgId} 1A 04 08 01 10 04
 2. 0x80-0x20 type=5  (capability)            payload: 08 05 10 {msgId} 22 02 08 01
 3. 0x80-0x20 type=128 (time sync)            payload: 08 80 01 10 {msgId} 82 08 {len} 08 {ts} 10 {tz}
 4. 0x09-0x20 type=1  (settings init)         payload: 08 01 10 {msgId} 1A 0C 4A 0A 08 00 10 00 18 00 20 02 28 01
 5. 0x0D-0x20 type=0  (display state)         payload: 08 00 10 {msgId}
 6. 0x07-0x20 type=10 (dashboard/AI config)   payload: 08 0A 10 {msgId} 6A {len} 08 00 10 50
 7. 0x09-0x20 type=2  (settings query)        payload: 08 02 10 {msgId} 22 02 08 01
 8. 0x01-0x20 type=2  (display config/lens)   payload: 08 02 10 {msgId} 22 17 12 15 08 04 10 03 1A 03 01 02 03 20 04 2A 04 01 03 02 02 30 00 38 01
 9. 0x81-0x20 type=1  (legacy hub init)       payload: 08 01 10 {msgId} 1A 00
10. 0x20-0x20 type=0  (unknown svc, cmd0)     payload: 08 00 10 {msgId} 1A 02 08 00
11. 0x20-0x20 type=1  (unknown svc, cmd1)     payload: 08 01 10 {msgId} 22 00
12. 0x09-0x20 type=1  (equalizer config)      payload: 08 01 10 {msgId} 1A 1A 52 18 0A 06 08 00 10 00 18 00 0A 06 08 00 10 01 18 00 0A 06 08 00 10 02 18 00
13. 0x04-0x20 type=1  (audio config)          payload: 08 01 10 {msgId} 1A 08 08 01 10 01 18 05 28 01
""")

# ============================================================================
# Packet-by-packet comparison
# ============================================================================
print("\n--- PACKET-BY-PACKET comparison: Capture vs SDK ---")
print()

# Capture auth packets (Phone->Device only)
capture_auth_p2d = [p for p in auth_packets if p["direction"] == "Phone->Device"]

# SDK auth expected payloads (without timestamp/tz which are dynamic)
sdk_auth = [
    {"seq": 1, "svc": "0x80-0x00", "payload_prefix": "0804100c1a0408011004",  "desc": "Capability query"},
    {"seq": 2, "svc": "0x80-0x20", "payload_prefix": "0805100e22020802",      "desc": "Capability response req (f4.f1=2)"},
    {"seq": 3, "svc": "0x80-0x20", "payload_prefix": "0880011",               "desc": "Time sync 1"},
    {"seq": 4, "svc": "0x80-0x00", "payload_prefix": "080410101a0408011004",  "desc": "Capability exchange 2"},
    {"seq": 5, "svc": "0x80-0x00", "payload_prefix": "080410111a0408011004",  "desc": "Capability exchange 3"},
    {"seq": 6, "svc": "0x80-0x20", "payload_prefix": "0805101222020801",      "desc": "Final capability"},
    {"seq": 7, "svc": "0x80-0x20", "payload_prefix": "0880011",               "desc": "Time sync 2"},
]

print(f"Capture has {len(capture_auth_p2d)} Phone->Device auth packets")
print(f"SDK expects {len(sdk_auth)} auth packets\n")

for i, sdk_pkt in enumerate(sdk_auth):
    print(f"Auth Packet {i+1}: SDK expects seq={sdk_pkt['seq']}, svc={sdk_pkt['svc']}")
    print(f"  SDK desc:     {sdk_pkt['desc']}")
    print(f"  SDK payload:  {sdk_pkt['payload_prefix']}...")
    if i < len(capture_auth_p2d):
        cap = capture_auth_p2d[i]
        svc_match = "MATCH" if cap["service_id"] == sdk_pkt["svc"] else f"MISMATCH (capture={cap['service_id']})"
        seq_match = "MATCH" if cap["seq"] == sdk_pkt["seq"] else f"MISMATCH (capture={cap['seq']})"
        payload_match = "MATCH" if cap["payload_hex"].startswith(sdk_pkt["payload_prefix"]) else "DIFFERENT"
        print(f"  Capture pkt:  {cap['pkt_num']}")
        print(f"  Capture seq:  {cap['seq']} [{seq_match}]")
        print(f"  Capture svc:  {cap['service_id']} [{svc_match}]")
        print(f"  Capture pay:  {cap['payload_hex']} [{payload_match}]")
    else:
        print(f"  Capture: NO MATCHING PACKET (fewer packets in capture)")
    print()

# Now compare init packets
print("=" * 80)
print("Init comparison: Capture vs SDK _initServices")
print("=" * 80)

# SDK init expected services (in order)
sdk_init = [
    {"svc": "0x80-0x00", "type": 4,   "desc": "Second auth handshake"},
    {"svc": "0x80-0x20", "type": 5,   "desc": "Capability mode"},
    {"svc": "0x80-0x20", "type": 128, "desc": "Time sync"},
    {"svc": "0x09-0x20", "type": 1,   "desc": "Settings init"},
    {"svc": "0x0D-0x20", "type": 0,   "desc": "Display state"},
    {"svc": "0x07-0x20", "type": 10,  "desc": "Dashboard/AI config"},
    {"svc": "0x09-0x20", "type": 2,   "desc": "Settings query"},
    {"svc": "0x01-0x20", "type": 2,   "desc": "Display config/lens layout"},
    {"svc": "0x81-0x20", "type": 1,   "desc": "Legacy hub init"},
    {"svc": "0x20-0x20", "type": 0,   "desc": "Unknown svc cmd0"},
    {"svc": "0x20-0x20", "type": 1,   "desc": "Unknown svc cmd1"},
    {"svc": "0x09-0x20", "type": 1,   "desc": "Equalizer config"},
    {"svc": "0x04-0x20", "type": 1,   "desc": "Audio config"},
]

# Extract proto type from payload (first varint after 0x08)
def get_proto_type(payload_hex):
    """Extract the protobuf field 1 value (type) from hex payload."""
    b = bytes.fromhex(payload_hex)
    if len(b) < 2 or b[0] != 0x08:
        return None
    # Decode varint
    val = 0
    shift = 0
    idx = 1
    while idx < len(b):
        byte = b[idx]
        val |= (byte & 0x7F) << shift
        shift += 7
        idx += 1
        if not (byte & 0x80):
            break
    return val

print(f"\nCapture non-heartbeat init packets: {len(init_non_hb)}")
print(f"SDK _initServices expects: {len(sdk_init)} packets\n")

for i, sdk_pkt in enumerate(sdk_init):
    print(f"Init Packet {i+1}: SDK expects svc={sdk_pkt['svc']}, type={sdk_pkt['type']}")
    print(f"  SDK desc: {sdk_pkt['desc']}")
    # SMART MATCH: find capture packet with matching service+type
    found = None
    for cap in init_non_hb:
        cap_type = get_proto_type(cap["payload_hex"])
        if cap["service_id"] == sdk_pkt["svc"] and cap_type == sdk_pkt["type"]:
            # For services that appear multiple times with same type, find first unused
            found = cap
            break
    if found:
        print(f"  Capture pkt:  {found['pkt_num']}, seq={found['seq']}")
        print(f"  Capture svc:  {found['service_id']} [MATCH]")
        print(f"  Capture type: {get_proto_type(found['payload_hex'])} [MATCH]")
        print(f"  Capture pay:  {found['payload_hex']}")
    else:
        # Try partial match (service only)
        partial = [p for p in init_non_hb if p["service_id"] == sdk_pkt["svc"]]
        if partial:
            print(f"  Capture: SERVICE MATCH but TYPE MISMATCH. Candidates:")
            for p in partial:
                print(f"    pkt={p['pkt_num']} seq={p['seq']} type={get_proto_type(p['payload_hex'])} payload={p['payload_hex']}")
        else:
            print(f"  Capture: NO MATCHING PACKET (service {sdk_pkt['svc']} not found)")
    print()

# Show ALL capture init packets NOT in SDK
print(f"\n--- ALL capture init packets with service/type matching status ---")
sdk_pairs = set((s["svc"], s["type"]) for s in sdk_init)
for p in init_non_hb:
    cap_type = get_proto_type(p["payload_hex"])
    in_sdk = (p["service_id"], cap_type) in sdk_pairs
    status = "IN_SDK" if in_sdk else "EXTRA"
    print(f"  [{status:6s}] pkt={p['pkt_num']:6d} seq={p['seq']:3d} svc={p['service_id']:>10} type={str(cap_type):>4s} payload={p['payload_hex'][:80]}{'...' if len(p['payload_hex'])>80 else ''}")

# Services in capture but not in SDK init
capture_init_svcs = set(p["service_id"] for p in init_non_hb)
sdk_init_svcs = set(s["svc"] for s in sdk_init)
missing_from_sdk = capture_init_svcs - sdk_init_svcs
extra_in_sdk = sdk_init_svcs - capture_init_svcs

print(f"\n--- Service comparison ---")
print(f"  Services in capture init: {sorted(capture_init_svcs)}")
print(f"  Services in SDK init:     {sorted(sdk_init_svcs)}")
if missing_from_sdk:
    print(f"  In capture but NOT in SDK: {sorted(missing_from_sdk)}")
if extra_in_sdk:
    print(f"  In SDK but NOT in capture: {sorted(extra_in_sdk)}")

# ============================================================================
# Summary of differences
# ============================================================================
print("\n" + "=" * 100)
print("SUMMARY OF DIFFERENCES")
print("=" * 100)

# Count unique services in entire pre-wake capture
all_svcs_before_wake = set()
for i, p in enumerate(packets):
    if wake_idx is not None and i >= wake_idx:
        break
    if p["direction"] == "Phone->Device":
        all_svcs_before_wake.add(p["service_id"])

print(f"\nAll Phone->Device services before wake: {sorted(all_svcs_before_wake)}")

# Show the full flow timeline
print("\n--- Full pre-wake timeline (all directions) ---")
print(f"{'IDX':>4} {'PKT#':>6} {'DIR':>16} {'SERVICE':>10} {'SEQ':>4} {'LEN':>5}  PAYLOAD_HEX")
print("-" * 130)
for i, p in enumerate(packets):
    if wake_idx is not None and i >= wake_idx:
        break
    arrow = ">>>" if p["direction"] == "Phone->Device" else "<<<"
    print(f"{i:4d} {p['pkt_num']:6d} {arrow} {p['direction']:>16} {p['service_id']:>10} {p['seq']:4d} {p['payload_len']:5d}  {p['payload_hex']}")

print(f"\n\nTotal decoded packets in capture: {len(packets)}")
print(f"Packets before wake: {wake_idx}")
print(f"Packets after wake: {len(packets) - wake_idx}")
print("\nDone.")
