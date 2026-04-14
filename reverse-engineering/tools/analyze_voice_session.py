"""Analyze BLE capture of Hey Even voice assistant session."""
import sys
import json
from collections import defaultdict

sys.stdout.reconfigure(encoding='utf-8')

CAPTURE = r"C:\CodeProjects\unofficial-even-g2-local-assistant\reverse-engineering\tools\results\capture_20260412_234826.json"

with open(CAPTURE, 'r', encoding='utf-8') as f:
    data = json.load(f)

packets = data['decoded_packets']

# Helper: get protobuf field value
def get_field(proto, fnum):
    for f in (proto or []):
        if f['field'] == fnum:
            return f
    return None

def get_field_val(proto, fnum):
    f = get_field(proto, fnum)
    if f:
        return f.get('value', f.get('as_string', f.get('raw_hex')))
    return None

def get_nested_string(proto, *path):
    """Walk nested protobuf fields to find a string."""
    current = proto
    for fnum in path:
        f = get_field(current, fnum)
        if not f:
            return None
        if 'as_string' in f:
            return f['as_string']
        if 'as_message' in f:
            current = f['as_message']
        else:
            return f.get('value')
    return None

def describe_07_packet(p):
    """Describe a service 0x07 packet."""
    proto = p.get('protobuf', [])
    f1 = get_field_val(proto, 1)  # type
    f2 = get_field_val(proto, 2)  # seq

    # Text in field 5 (transcription)
    text5 = get_nested_string(proto, 5, 4)
    # Text in field 7 (AI response)
    text7 = get_nested_string(proto, 7, 4)
    # Field 3 sub-message
    f3 = get_field(proto, 3)
    f3_val = None
    if f3 and f3.get('as_message'):
        f3_val = get_field_val(f3['as_message'], 1)
    # Field 10 sub-message
    f10 = get_field(proto, 10)
    f10_val = None
    if f10 and f10.get('as_message'):
        f10_val = get_field_val(f10['as_message'], 1)
    # Field 13 sub-message
    f13 = get_field(proto, 13)
    f13_vals = None
    if f13 and f13.get('as_message'):
        f13_v1 = get_field_val(f13['as_message'], 1)
        f13_v2 = get_field_val(f13['as_message'], 2)
        f13_vals = (f13_v1, f13_v2)

    # Field 5 type
    f5 = get_field(proto, 5)
    f5_type = None
    if f5 and f5.get('as_message'):
        f5_type = get_field_val(f5['as_message'], 1)

    # Field 7 type
    f7 = get_field(proto, 7)
    f7_type = None
    if f7 and f7.get('as_message'):
        f7_type = get_field_val(f7['as_message'], 1)

    return {
        'type': f1, 'seq': f2, 'text5': text5, 'text7': text7,
        'f3_val': f3_val, 'f10_val': f10_val, 'f13_vals': f13_vals,
        'f5_type': f5_type, 'f7_type': f7_type,
    }

# ============================================================
print("=" * 100)
print("SECTION 1: FULL TIMELINE OF SERVICE 0x07 PACKETS")
print("=" * 100)

scroll_count = 0
svc07_packets = [p for p in packets if p['service_id'].startswith('0x07')]

for p in svc07_packets:
    desc = describe_07_packet(p)

    # Count type=9 scroll packets but skip display
    if desc['type'] == 9:
        scroll_count += 1
        continue

    line = f"  pkt={p['pkt_num']:>6}  {p['direction']:<16}  svc={p['service_id']:<8}  seq={p['seq']:<4}  type={desc['type']}"

    extras = []
    if desc['f3_val'] is not None:
        extras.append(f"f3.1={desc['f3_val']}")
    if desc['f10_val'] is not None:
        extras.append(f"f10.1={desc['f10_val']}")
    if desc['f13_vals'] is not None:
        extras.append(f"f13=(f1={desc['f13_vals'][0]}, f2={desc['f13_vals'][1]})")
    if desc['f5_type'] is not None and desc['text5'] is None:
        extras.append(f"f5.1={desc['f5_type']}")
    if desc['f7_type'] is not None and desc['text7'] is None:
        extras.append(f"f7.1={desc['f7_type']}")
    if desc['text5']:
        extras.append(f'TRANSCRIPTION: "{desc["text5"]}"')
    if desc['text7']:
        extras.append(f'AI RESPONSE: "{desc["text7"]}"')

    if extras:
        line += "  | " + "  ".join(extras)

    print(line)

print(f"\n  [Skipped {scroll_count} type=9 scroll packets]")
print(f"  Total 0x07 packets: {len(svc07_packets)} ({len(svc07_packets) - scroll_count} non-scroll + {scroll_count} scroll)")

# ============================================================
print("\n" + "=" * 100)
print("SECTION 2: ALL PHONE->DEVICE PACKETS BETWEEN WAKE EVENT AND FIRST TRANSCRIPTION")
print("=" * 100)

# Find first 0x07-0x01 packet (wake event)
first_wake = None
for p in packets:
    if p['service_id'] == '0x07-0x01':
        first_wake = p['pkt_num']
        break

# Find first transcription text
first_transcription = None
for p in svc07_packets:
    desc = describe_07_packet(p)
    if desc['text5']:
        first_transcription = p['pkt_num']
        break

print(f"\n  Wake event (first 0x07-0x01): pkt {first_wake}")
print(f"  First transcription text: pkt {first_transcription}")
print(f"\n  All Phone->Device packets in range [{first_wake}, {first_transcription}]:\n")

if first_wake and first_transcription:
    for p in packets:
        if p['pkt_num'] < first_wake or p['pkt_num'] > first_transcription:
            continue
        if p['direction'] != 'Phone->Device':
            continue

        proto = p.get('protobuf', [])
        f1_val = get_field_val(proto, 1)
        f2_val = get_field_val(proto, 2)

        detail = f"payload_hex={p['payload_hex']}"
        if len(p['payload_hex']) > 40:
            detail = f"payload_hex={p['payload_hex'][:40]}... (len={p['payload_len']})"

        print(f"  pkt={p['pkt_num']:>6}  svc={p['service_id']:<10}  seq={p['seq']:<4}  f1={f1_val}  f2={f2_val}  {detail}")

# Also show ALL packets (both directions) in a tighter window around wake
print(f"\n  All packets (both directions) in range [{first_wake}, {first_wake + 500}]:\n")
if first_wake:
    for p in packets:
        if p['pkt_num'] < first_wake or p['pkt_num'] > first_wake + 500:
            continue
        proto = p.get('protobuf', [])
        f1_val = get_field_val(proto, 1)
        print(f"  pkt={p['pkt_num']:>6}  {p['direction']:<16}  svc={p['service_id']:<10}  seq={p['seq']:<4}  f1={f1_val}  hex={p['payload_hex'][:60]}")

# ============================================================
print("\n" + "=" * 100)
print("SECTION 3: TEXT CONTENT (TRANSCRIPTION + AI RESPONSE)")
print("=" * 100)

print("\n--- Transcription chunks (field 5) ---")
for p in svc07_packets:
    desc = describe_07_packet(p)
    if desc['text5']:
        print(f"  pkt={p['pkt_num']:>6}  type={desc['type']}  seq={desc['seq']}  \"{desc['text5']}\"")

print("\n--- AI Response chunks (field 7) ---")
for p in svc07_packets:
    desc = describe_07_packet(p)
    if desc['text7']:
        print(f"  pkt={p['pkt_num']:>6}  type={desc['type']}  seq={desc['seq']}  \"{desc['text7']}\"")

# Reconstruct full texts
print("\n--- Full reconstructed transcriptions ---")
sessions = []
current_session_texts = []
current_session_ai = []
last_text = None
for p in svc07_packets:
    desc = describe_07_packet(p)
    if desc['text5']:
        # If this text is shorter than last, it's a new partial sequence reset
        current_session_texts.append((p['pkt_num'], desc['text5']))
        last_text = desc['text5']
    if desc['text7']:
        current_session_ai.append((p['pkt_num'], desc['text7']))

# Group by looking at the final transcription (longest)
# Find transcription "final" versions (type=3 with longest text before AI response)
print("\n  Session transcription chunks:")
for pkt, text in current_session_texts:
    print(f"    pkt={pkt}: \"{text}\"")

print("\n  Session AI response chunks (concatenated):")
full_ai = ""
for pkt, text in current_session_ai:
    full_ai += text
    print(f"    pkt={pkt}: \"{text}\"")
print(f"\n  FULL AI RESPONSE: \"{full_ai}\"")

# ============================================================
print("\n" + "=" * 100)
print("SECTION 4: TIMING ANALYSIS")
print("=" * 100)

# Check packet number gaps for 0x07 packets
print("\n  Inter-packet gaps (by pkt_num, which approximates time):\n")
prev = None
gaps = []
for p in svc07_packets:
    desc = describe_07_packet(p)
    if desc['type'] == 9:
        continue
    if prev is not None:
        gap = p['pkt_num'] - prev['pkt_num']
        gaps.append((prev['pkt_num'], p['pkt_num'], gap))
    prev = p

# Show largest gaps
gaps_sorted = sorted(gaps, key=lambda x: -x[2])
print("  Top 10 largest gaps between 0x07 non-scroll packets:")
for a, b, g in gaps_sorted[:10]:
    print(f"    pkt {a} -> {b}: gap = {g} packets")

print("\n  Regular heartbeat check - gaps between type=10 (config) packets:")
type10_pkts = [p for p in svc07_packets if describe_07_packet(p)['type'] == 10]
for i in range(1, len(type10_pkts)):
    gap = type10_pkts[i]['pkt_num'] - type10_pkts[i-1]['pkt_num']
    print(f"    pkt {type10_pkts[i-1]['pkt_num']} -> {type10_pkts[i]['pkt_num']}: gap = {gap}")

# Check for any periodic patterns on 0x80 service during the voice session
if first_wake:
    print(f"\n  0x80 heartbeat packets during voice session (pkt {first_wake}-{first_wake+5000}):")
    hb_count = 0
    for p in packets:
        if p['pkt_num'] < first_wake or p['pkt_num'] > first_wake + 5000:
            continue
        if p['service_id'].startswith('0x80'):
            hb_count += 1
    print(f"    Count: {hb_count} packets on 0x80 service in that range")

# ============================================================
print("\n" + "=" * 100)
print("SECTION 5: SESSION TIMEOUT - LAST SEQUENCE OF PACKETS")
print("=" * 100)

# Show last 30 0x07 packets
print("\n  Last 30 service 0x07 packets (non-scroll):")
non_scroll_07 = [p for p in svc07_packets if describe_07_packet(p)['type'] != 9]
for p in non_scroll_07[-30:]:
    desc = describe_07_packet(p)
    extras = []
    if desc['f3_val'] is not None:
        extras.append(f"f3.1={desc['f3_val']}")
    if desc['f10_val'] is not None:
        extras.append(f"f10.1={desc['f10_val']}")
    if desc['f13_vals'] is not None:
        extras.append(f"f13=(f1={desc['f13_vals'][0]}, f2={desc['f13_vals'][1]})")
    if desc['text5']:
        extras.append(f'TRANSCRIPTION: "{desc["text5"]}"')
    if desc['text7']:
        extras.append(f'AI: "{desc["text7"]}"')

    extra_str = "  | " + "  ".join(extras) if extras else ""
    print(f"  pkt={p['pkt_num']:>6}  {p['direction']:<16}  svc={p['service_id']:<8}  type={desc['type']}  seq={desc['seq']}{extra_str}")

# Show the very last packets across ALL services
print("\n  Last 40 packets across ALL services:")
for p in packets[-40:]:
    proto = p.get('protobuf', [])
    f1_val = get_field_val(proto, 1)
    print(f"  pkt={p['pkt_num']:>6}  {p['direction']:<16}  svc={p['service_id']:<10}  f1={f1_val}  hex={p['payload_hex'][:60]}")

# ============================================================
print("\n" + "=" * 100)
print("SECTION 6: TYPE DISTRIBUTION FOR 0x07 PACKETS")
print("=" * 100)

type_counts = defaultdict(int)
type_directions = defaultdict(set)
for p in svc07_packets:
    desc = describe_07_packet(p)
    t = desc['type']
    type_counts[t] += 1
    type_directions[t].add(p['direction'])

print("\n  type  count  directions")
for t in sorted(type_counts.keys(), key=lambda x: x if x is not None else -1):
    dirs = ", ".join(sorted(type_directions[t]))
    print(f"  {str(t):>5}  {type_counts[t]:>5}  {dirs}")

# ============================================================
print("\n" + "=" * 100)
print("SECTION 7: 0x07-0x01 NOTIFICATION PATTERNS")
print("=" * 100)

print("\n  All 0x07-0x01 packets (device notifications/events):")
for p in packets:
    if p['service_id'] == '0x07-0x01':
        desc = describe_07_packet(p)
        extras = []
        if desc['f3_val'] is not None:
            extras.append(f"f3.1={desc['f3_val']}")
        if desc['f10_val'] is not None:
            extras.append(f"f10.1={desc['f10_val']}")
        extra_str = "  | " + "  ".join(extras) if extras else ""
        print(f"  pkt={p['pkt_num']:>6}  seq={p['seq']:<4}  type={desc['type']}  seq_f2={desc['seq']}{extra_str}")
        print(f"          payload: {p['payload_hex']}")

# Show what 0x0D-0x01 are (also notifications during voice session)
print("\n  All 0x0D-0x01 packets (possible related notifications):")
for p in packets:
    if p['service_id'] == '0x0D-0x01':
        proto = p.get('protobuf', [])
        f1 = get_field_val(proto, 1)
        f2 = get_field_val(proto, 2)
        print(f"  pkt={p['pkt_num']:>6}  f1={f1}  f2={f2}  hex={p['payload_hex']}")
