#!/usr/bin/env python3
"""
Even G2 BLE Capture Assistant
==============================
Interactive step-by-step tool to capture and decode BLE traffic
from Even G2 glasses and R1 ring.

Automates: ADB snoop log management, btsnoop parsing, packet extraction,
           protobuf decoding, service ID discovery, and result tracking.

Manual steps: Physical actions (tap glasses, say "Hey Even", etc.) are
              prompted with clear instructions and wait for user confirmation.

Usage:
    python capture_assistant.py                  # Start from beginning
    python capture_assistant.py --phase 2        # Jump to phase 2
    python capture_assistant.py --analyze FILE   # Analyze a btsnoop log
    python capture_assistant.py --status         # Show discovery progress

Requirements:
    pip install -r requirements.txt
    ADB installed and phone connected via USB
"""

import argparse
import json
import mmap
import os
import struct
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

# =============================================================================
# Configuration
# =============================================================================

BASE_DIR = Path(__file__).parent
CAPTURES_DIR = BASE_DIR / "captures"
RESULTS_DIR = BASE_DIR / "results"
PROGRESS_FILE = RESULTS_DIR / "progress.json"

CAPTURES_DIR.mkdir(exist_ok=True)
RESULTS_DIR.mkdir(exist_ok=True)

# Known G2 BLE characteristic UUIDs (last 4 hex digits)
CHAR_WRITE = 0x5401       # Phone → Glasses (commands)
CHAR_NOTIFY = 0x5402      # Glasses → Phone (responses)
CHAR_DISPLAY_W = 0x6401   # Phone → Glasses (display data)
CHAR_DISPLAY_N = 0x6402   # Glasses → Phone (display responses)
CHAR_THIRD_W = 0x7401     # Phone → Glasses (third channel)
CHAR_THIRD_N = 0x7402     # Glasses → Phone (mic audio stream - LC3)

# Known ATT handle mapping (confirmed 2026-04-03)
# 0x0842 = Write (5401) main commands
# 0x0844 = Notify (5402) main responses
# 0x0864 = Notify (7402) mic audio stream - raw LC3 frames, NOT G2 transport
# 0x0882 = Write (6401) secondary/display commands
# 0x0884 = Notify (6402) secondary/display responses

# Known service IDs (confirmed from BLE captures 2026-04-03)
# Sub-service pattern: 0x00=response, 0x01=event/notification, 0x20=command
KNOWN_SERVICES = {
    # Auth & Sync
    (0x80, 0x00): "Sync",
    (0x80, 0x01): "Sync Response",
    (0x80, 0x20): "Auth",
    # AI / Text / Gestures (CONFIRMED)
    (0x01, 0x00): "AI/Text Response",
    (0x01, 0x01): "Gesture Events",       # single tap, double tap, scroll, long press, both-hold
    (0x01, 0x20): "AI/Text Content",       # news, AI replies sent to glasses
    # Notification
    (0x02, 0x20): "Notification",
    # Transcribe (inferred from code)
    (0x03, 0x00): "Transcribe Response",
    (0x03, 0x20): "Transcribe",
    # Display
    (0x04, 0x00): "Display Wake Response",
    (0x04, 0x20): "Display Wake",
    # Teleprompter (CONFIRMED - working script)
    (0x06, 0x20): "Teleprompter",
    # Dashboard
    (0x07, 0x00): "Dashboard Response",
    (0x07, 0x01): "Dashboard Event",
    (0x07, 0x20): "Dashboard",
    # Device Info (CONFIRMED - firmware, battery)
    (0x09, 0x00): "Device Info",
    (0x09, 0x01): "Device Info Event",     # firmware 2.0.9.20, battery=field12
    (0x09, 0x20): "Device Info Request",
    # Conversate (CONFIRMED - full protobuf decoded)
    (0x0B, 0x00): "Conversate Response",
    (0x0B, 0x20): "Conversate",           # field1=type(1/6/0xFF), field8={text, is_final}
    # Tasks / Quick List (from g2_transport.proto)
    (0x0C, 0x00): "Tasks Response",
    (0x0C, 0x20): "Tasks",
    # Config (CONFIRMED - display state events)
    (0x0D, 0x00): "Device Config",
    (0x0D, 0x01): "Config Event",          # display on/off: field3.1=1 on, empty=off
    (0x0D, 0x20): "Config",
    # Display Config (CONFIRMED - also carries R1 health insights)
    (0x0E, 0x00): "Display Config Response",
    (0x0E, 0x20): "Display Config",
    # Unknown - possibly Translate
    (0x10, 0x00): "Unknown-10 Response",
    (0x10, 0x20): "Unknown-10",
    # Commit (from g2_transport.proto)
    (0x20, 0x00): "Commit Response",
    (0x20, 0x20): "Commit",
    # EvenHub
    (0x81, 0x00): "EvenHub Response",
    (0x81, 0x20): "EvenHub",
    # Unknown-91
    (0x91, 0x00): "Unknown-91 Response",
    (0x91, 0x20): "Unknown-91",
    # File Transfer (CONFIRMED - sends notify_whitelist.json, NOT audio control)
    (0xC4, 0x00): "File Transfer",
    # AI/Display Session Control
    (0xC5, 0x00): "Session Control",
}

# Services still to discover/confirm
UNKNOWN_SERVICES = [
    "Translate", "Navigation",
    "Audio Control (start/stop mic)",
    "Ring Settings", "Ring Health Raw Data",
    "Glasses Case", "OTA",
]

# Terminal colors
class C:
    BOLD = "\033[1m"
    DIM = "\033[2m"
    GREEN = "\033[92m"
    YELLOW = "\033[93m"
    RED = "\033[91m"
    CYAN = "\033[96m"
    MAGENTA = "\033[95m"
    BLUE = "\033[94m"
    RESET = "\033[0m"


# =============================================================================
# Progress Tracking
# =============================================================================

def load_progress() -> dict:
    default = {
        "discovered_services": {},
        "completed_phases": [],
        "completed_steps": [],
        "captures": [],
        "notes": [],
    }
    if PROGRESS_FILE.exists():
        try:
            data = json.loads(PROGRESS_FILE.read_text())
            # Ensure all expected keys exist (forward-compat)
            for key, val in default.items():
                data.setdefault(key, val)
            return data
        except (json.JSONDecodeError, ValueError):
            print(f"  {C.YELLOW}Warning: progress.json is corrupted, starting fresh.{C.RESET}")
    return default


def save_progress(progress: dict):
    PROGRESS_FILE.write_text(json.dumps(progress, indent=2))


def mark_phase_done(progress: dict, phase: int):
    key = f"phase_{phase}"
    if key not in progress["completed_phases"]:
        progress["completed_phases"].append(key)
    save_progress(progress)


def register_service(progress: dict, svc_hi: int, svc_lo: int, name: str):
    key = f"0x{svc_hi:02X}-0x{svc_lo:02X}"
    progress["discovered_services"][key] = name
    save_progress(progress)
    print(f"  {C.GREEN}Registered: {name} = {key}{C.RESET}")


def print_service_table(progress: dict):
    print(f"\n{C.BOLD}=== Service Discovery Status ==={C.RESET}\n")
    print(f"  {'Service':<20} {'ID':<12} {'Status'}")
    print(f"  {'─' * 20} {'─' * 12} {'─' * 12}")

    # Build set of known keys for dedup
    known_keys = {f"0x{hi:02X}-0x{lo:02X}" for hi, lo in KNOWN_SERVICES}

    # Known services
    for (hi, lo), name in sorted(KNOWN_SERVICES.items(), key=lambda x: x[1]):
        key = f"0x{hi:02X}-0x{lo:02X}"
        print(f"  {name:<20} {key:<12} {C.GREEN}CONFIRMED{C.RESET}")

    # Discovered services (skip those already in KNOWN_SERVICES by key)
    discovered = progress.get("discovered_services", {})
    discovered_names = set()
    for key, name in discovered.items():
        if key not in known_keys:
            print(f"  {name:<20} {key:<12} {C.CYAN}CAPTURED{C.RESET}")
            discovered_names.add(name)

    # Still unknown
    for name in UNKNOWN_SERVICES:
        if name not in discovered_names:
            print(f"  {name:<20} {'???':<12} {C.RED}UNKNOWN{C.RESET}")

    new_discovered = {k for k in discovered if k not in known_keys}
    total_known = len(KNOWN_SERVICES) + len(new_discovered)
    total_target = len(KNOWN_SERVICES) + len(UNKNOWN_SERVICES)
    print(f"\n  {C.BOLD}Progress: {total_known}/{total_target} services mapped{C.RESET}\n")


# =============================================================================
# btsnoop HCI Log Parser
# =============================================================================

BTSNOOP_MAGIC = b"btsnoop\x00"

# HCI packet types
HCI_CMD = 0x01
HCI_ACL = 0x02
HCI_SCO = 0x03
HCI_EVT = 0x04

# ATT opcodes we care about
ATT_WRITE_CMD = 0x52        # Write Command (no response)
ATT_WRITE_REQ = 0x12        # Write Request
ATT_HANDLE_NOTIFY = 0x1B    # Handle Value Notification
ATT_HANDLE_IND = 0x1D       # Handle Value Indication

# L2CAP CID for ATT
L2CAP_ATT_CID = 0x0004


def parse_btsnoop(filepath: str) -> list:
    """Parse a btsnoop_hci.log file and return ATT packets.
    Supports datalink types: 1001 (H1), 1002 (H4/UART), and others.
    Falls back to raw scan if btsnoop parsing yields no results."""
    packets = []

    with open(filepath, "rb") as f:
        magic = f.read(8)
        if magic != BTSNOOP_MAGIC:
            print(f"  {C.YELLOW}Not a btsnoop file — trying raw scan...{C.RESET}")
            return raw_scan_for_g2_packets(filepath)

        version = struct.unpack(">I", f.read(4))[0]
        datalink = struct.unpack(">I", f.read(4))[0]
        print(f"  {C.DIM}btsnoop v{version}, datalink={datalink}{C.RESET}")

        # Datalink types: 1002=H4/UART (Android standard, has 1-byte type indicator)
        # 1001=H1 (no type indicator, type inferred from flags)
        # Other values (e.g., 768) = vendor-specific
        use_h4 = datalink == 1002

        reassembler = L2CAPReassembler()
        pkt_num = 0
        truncated_records = 0
        while True:
            rec_hdr = f.read(24)
            if len(rec_hdr) < 24:
                break

            orig_len, incl_len, flags, drops, ts_us = struct.unpack(">IIIIq", rec_hdr)

            # Sanity check: BLE packets should be < 64KB
            if incl_len > 65536 or incl_len == 0:
                # Don't try to resync by seeking 1-byte forward — that corrupts
                # all subsequent record boundaries and produces ghost packets.
                # Just stop structured parsing and let raw_scan handle it.
                print(f"  {C.YELLOW}Bad btsnoop record at packet {pkt_num + 1} "
                      f"(incl_len={incl_len}) — stopping structured parse.{C.RESET}")
                break

            data = f.read(incl_len)
            if len(data) < incl_len:
                break

            if orig_len > incl_len:
                truncated_records += 1

            pkt_num += 1

            if use_h4:
                # H4/UART: first byte is HCI packet type indicator
                if len(data) < 1:
                    continue
                pkt_type = data[0]
                hci_data = data[1:]
            elif datalink == 1001:
                # H1: no type indicator byte, type inferred from flags
                # flags bit 0: 0=sent, 1=received
                # flags bit 1: 0=data (ACL/SCO), 1=command/event — skip those
                if (flags >> 1) & 1:
                    continue
                pkt_type = HCI_ACL
                hci_data = data
            else:
                # Non-standard: try with H4 indicator, fall back to raw ACL
                if len(data) >= 1 and data[0] in (HCI_CMD, HCI_ACL, HCI_SCO, HCI_EVT):
                    pkt_type = data[0]
                    hci_data = data[1:]
                else:
                    pkt_type = HCI_ACL
                    hci_data = data

            if pkt_type != HCI_ACL:
                continue

            is_sent = (flags & 0x01) == 0

            att_pkt = reassembler.process_acl(hci_data, is_sent, ts_us, pkt_num)
            if att_pkt:
                packets.append(att_pkt)

    if truncated_records:
        print(f"  {C.YELLOW}Warning: {truncated_records} btsnoop records were truncated "
              f"(orig_len > incl_len) — some packets may have been silently dropped.{C.RESET}")

    # If btsnoop parsing found nothing, try raw scan
    if not packets:
        print(f"  {C.YELLOW}btsnoop parsing found 0 ATT packets — trying raw scan...{C.RESET}")
        return raw_scan_for_g2_packets(filepath)

    return packets


def raw_scan_for_g2_packets(filepath: str) -> list:
    """Fallback: scan a binary file for G2 transport packets (0xAA headers).
    Works regardless of btsnoop format — just looks for known byte patterns."""
    packets = []

    file_size = os.path.getsize(filepath)
    if file_size == 0:
        return []

    print(f"  {C.DIM}Raw scanning {file_size} bytes for 0xAA headers...{C.RESET}")
    pkt_num = 0
    magic_byte = bytes([G2_MAGIC])

    with open(filepath, "rb") as f, \
         mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as data:

        pos = 0
        data_len = len(data)
        while pos < data_len - 9:
            # mmap.find() runs in C — orders of magnitude faster than Python byte loop
            pos = data.find(magic_byte, pos)
            if pos == -1 or pos >= data_len - 9:
                break

            pkt_type = data[pos + 1]
            if pkt_type not in (0x21, 0x12):
                pos += 1
                continue

            payload_len = data[pos + 3]
            if payload_len < 2 or payload_len > 240:
                pos += 1
                continue

            total_pkt_len = 8 + payload_len  # header(8) + payload_with_crc
            if pos + total_pkt_len > data_len:
                break

            # Verify CRC — copy to bytes first (mmap slices return bytes on Py3)
            raw_pkt = bytes(data[pos:pos + total_pkt_len])
            payload = raw_pkt[8:-2]
            crc_actual = struct.unpack("<H", raw_pkt[-2:])[0]
            crc_expected = crc16_ccitt(payload)

            if crc_actual == crc_expected:
                pkt_num += 1
                direction = "TX" if pkt_type == 0x21 else "RX"
                packets.append({
                    "pkt_num": pkt_num,
                    "timestamp": 0,
                    "direction": direction,
                    "att_handle": 0,
                    "att_opcode": ATT_WRITE_CMD if direction == "TX" else ATT_HANDLE_NOTIFY,
                    "value": raw_pkt,
                    "_raw_offset": pos,
                })

            pos += 1

    if packets:
        print(f"  {C.GREEN}Raw scan found {len(packets)} G2 packets!{C.RESET}")
    else:
        print(f"  {C.DIM}Raw scan found no G2 packets in raw data.{C.RESET}")
        # Try tshark as last resort
        packets = try_tshark_parse(filepath)

    return packets


def try_tshark_parse(filepath: str) -> list:
    """Try to extract ATT data using tshark (Wireshark CLI) if available."""
    packets = []

    # Check for tshark
    tshark_paths = [
        "tshark",
        "/Applications/Wireshark.app/Contents/MacOS/tshark",
        "/usr/local/bin/tshark",
        "/opt/homebrew/bin/tshark",
    ]
    tshark = None
    for path in tshark_paths:
        try:
            result = subprocess.run([path, "--version"], capture_output=True, timeout=5)
            if result.returncode == 0:
                tshark = path
                break
        except (FileNotFoundError, subprocess.TimeoutExpired):
            continue

    if not tshark:
        print(f"  {C.YELLOW}tshark not found. Install Wireshark for non-standard btsnoop support.{C.RESET}")
        print(f"  {C.DIM}  brew install --cask wireshark{C.RESET}")
        print(f"  {C.DIM}Or use Wireshark GUI to export packets as JSON.{C.RESET}")
        return []

    print(f"  {C.CYAN}Using tshark to parse non-standard btsnoop...{C.RESET}")
    try:
        # Extract ATT Write Commands and Notifications with their data
        cmd = [
            tshark, "-r", filepath,
            "-Y", "btatt.opcode == 0x52 || btatt.opcode == 0x12 || btatt.opcode == 0x1b || btatt.opcode == 0x1d",
            "-T", "fields",
            "-e", "frame.number",
            "-e", "frame.time_relative",
            "-e", "btatt.opcode",
            "-e", "btatt.handle",
            "-e", "btatt.value",
            "-E", "separator=|",
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if result.returncode != 0:
            print(f"  {C.RED}tshark failed: {result.stderr[:200]}{C.RESET}")
            return []

        pkt_num = 0
        for line in result.stdout.strip().split("\n"):
            if not line.strip():
                continue
            parts = line.split("|")
            if len(parts) < 5:
                continue
            try:
                # tshark outputs BASE_HEX fields (opcode, handle) as hex without 0x prefix
                opcode_raw = parts[2].strip().removeprefix("0x").removeprefix("0X") if parts[2] else "0"
                opcode = int(opcode_raw, 16)
                handle_raw = parts[3].strip().removeprefix("0x").removeprefix("0X") if parts[3] else "0"
                handle = int(handle_raw, 16)
                value_hex = parts[4].replace(":", "")
                value = bytes.fromhex(value_hex) if value_hex else b""
            except (ValueError, IndexError):
                continue

            pkt_num += 1
            direction = "TX" if opcode in (ATT_WRITE_CMD, ATT_WRITE_REQ) else "RX"
            packets.append({
                "pkt_num": pkt_num,
                "timestamp": 0,
                "direction": direction,
                "att_handle": handle,
                "att_opcode": opcode,
                "value": value,
            })

        if packets:
            print(f"  {C.GREEN}tshark extracted {len(packets)} ATT packets!{C.RESET}")

    except subprocess.TimeoutExpired:
        print(f"  {C.RED}tshark timed out.{C.RESET}")

    return packets


class L2CAPReassembler:
    """Reassembles fragmented L2CAP PDUs from HCI ACL packets.

    BLE ACL packets are fragmented at the HCI layer when the L2CAP PDU
    exceeds the controller's ACL data packet length. Without reassembly,
    continuation fragments (pb_flag=0x01) are silently dropped because
    they lack L2CAP headers — causing truncated ATT payloads for any
    transfer larger than one ACL packet.
    """

    def __init__(self):
        self._buffers = {}  # acl_handle → {expected_len, data, is_sent, timestamp, pkt_num}

    def process_acl(self, hci_data: bytes, is_sent: bool, timestamp: int, pkt_num: int) -> dict | None:
        """Process an ACL packet. Returns a complete ATT packet when ready, or None."""
        if len(hci_data) < 4:
            return None

        handle_flags = struct.unpack("<H", hci_data[0:2])[0]
        acl_handle = handle_flags & 0x0FFF
        pb_flag = (handle_flags >> 12) & 0x03
        acl_len = struct.unpack("<H", hci_data[2:4])[0]
        acl_payload = hci_data[4:4 + acl_len]

        if pb_flag in (0x00, 0x02):
            # First fragment (0x02) or complete PDU (0x00)
            if len(acl_payload) < 4:
                return None

            l2cap_len = struct.unpack("<H", acl_payload[0:2])[0]
            l2cap_cid = struct.unpack("<H", acl_payload[2:4])[0]
            l2cap_data = acl_payload[4:]

            if l2cap_cid != L2CAP_ATT_CID:
                self._buffers.pop(acl_handle, None)
                return None

            if len(l2cap_data) >= l2cap_len:
                # Complete PDU in single ACL packet — no fragmentation
                self._buffers.pop(acl_handle, None)
                return _extract_att(l2cap_data[:l2cap_len], is_sent, timestamp, pkt_num)
            else:
                # First fragment of a multi-ACL PDU — start buffering
                self._buffers[acl_handle] = {
                    "expected_len": l2cap_len,
                    "data": bytearray(l2cap_data),
                    "is_sent": is_sent,
                    "timestamp": timestamp,
                    "pkt_num": pkt_num,
                }
                return None

        elif pb_flag == 0x01:
            # Continuation fragment — append to pending reassembly
            buf = self._buffers.get(acl_handle)
            if buf is None:
                return None

            buf["data"].extend(acl_payload)

            if len(buf["data"]) >= buf["expected_len"]:
                complete = bytes(buf["data"][:buf["expected_len"]])
                pkt = _extract_att(complete, buf["is_sent"], buf["timestamp"], buf["pkt_num"])
                del self._buffers[acl_handle]
                return pkt
            return None

        return None


def _extract_att(l2cap_payload: bytes, is_sent: bool, timestamp: int, pkt_num: int) -> dict | None:
    """Extract ATT write/notification from a complete L2CAP ATT payload."""
    if len(l2cap_payload) < 1:
        return None

    att_opcode = l2cap_payload[0]

    if att_opcode in (ATT_WRITE_CMD, ATT_WRITE_REQ):
        if len(l2cap_payload) < 3:
            return None
        att_handle = struct.unpack("<H", l2cap_payload[1:3])[0]
        att_value = l2cap_payload[3:]
    elif att_opcode in (ATT_HANDLE_NOTIFY, ATT_HANDLE_IND):
        if len(l2cap_payload) < 3:
            return None
        att_handle = struct.unpack("<H", l2cap_payload[1:3])[0]
        att_value = l2cap_payload[3:]
    else:
        return None

    # Use btsnoop is_sent flag as authoritative direction source rather than
    # inferring from ATT opcode — is_sent comes from the HCI transport layer
    # and is always correct, while opcode-based inference breaks if the phone
    # ever acts as GATT server (e.g., for ring bridging)
    direction = "TX" if is_sent else "RX"

    return {
        "pkt_num": pkt_num,
        "timestamp": timestamp,
        "direction": direction,
        "att_handle": att_handle,
        "att_opcode": att_opcode,
        "value": att_value,
    }


# =============================================================================
# G2 Transport Header Parser
# =============================================================================

G2_MAGIC = 0xAA

def parse_g2_packet(raw: bytes) -> dict | None:
    """Parse a G2 transport packet (0xAA header)."""
    if len(raw) < 10 or raw[0] != G2_MAGIC:
        return None

    pkt_type = raw[1]       # 0x21 = phone→glasses, 0x12 = glasses→phone
    seq = raw[2]
    payload_len = raw[3]    # Includes protobuf payload + 2 bytes CRC
    pkt_total = raw[4]
    pkt_serial = raw[5]
    svc_hi = raw[6]
    svc_lo = raw[7]

    # Total packet = 8 (header) + payload_len (payload + CRC)
    # payload_len includes the 2-byte CRC, so protobuf is payload_len - 2 bytes
    total_pkt_len = 8 + payload_len
    if payload_len < 2 or len(raw) < total_pkt_len:
        return None

    # Validate fragment fields — pkt_serial must be <= pkt_total (1-indexed), and
    # pkt_total == 0 is invalid (means "no fragments" but serial exists)
    if pkt_total == 0 or pkt_serial == 0 or pkt_serial > pkt_total:
        return None

    # Use payload_len to determine exact boundaries (don't trust len(raw))
    payload = raw[8:total_pkt_len - 2]
    crc_bytes = raw[total_pkt_len - 2:total_pkt_len]
    crc = struct.unpack("<H", crc_bytes)[0]

    # Verify CRC (calculated over protobuf payload only)
    expected_crc = crc16_ccitt(payload)
    crc_ok = (crc == expected_crc)

    direction_str = "Phone→Glasses" if pkt_type == 0x21 else "Glasses→Phone" if pkt_type == 0x12 else f"Unknown(0x{pkt_type:02X})"

    service_name = KNOWN_SERVICES.get((svc_hi, svc_lo), None)

    return {
        "magic": G2_MAGIC,
        "type": pkt_type,
        "direction": direction_str,
        "seq": seq,
        "payload_len": payload_len,
        "pkt_total": pkt_total,
        "pkt_serial": pkt_serial,
        "svc_hi": svc_hi,
        "svc_lo": svc_lo,
        "service_id": f"0x{svc_hi:02X}-0x{svc_lo:02X}",
        "service_name": service_name or "UNKNOWN",
        "payload": payload,
        "crc": crc,
        "crc_ok": crc_ok,
    }


def crc16_ccitt(data: bytes, init: int = 0xFFFF) -> int:
    crc = init
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else (crc << 1)
            crc &= 0xFFFF
    return crc


def reassemble_g2_fragments(g2_packets: list) -> list:
    """Reassemble multi-fragment G2 packets into complete messages.

    G2 protocol splits large protobuf payloads across multiple BLE writes
    using pkt_total/pkt_serial fields. Without reassembly, protobuf decoding
    of individual fragments produces garbage — field boundaries don't align
    with fragment boundaries.

    Fragments sharing the same (service_id, seq) are concatenated in
    pkt_serial order. Incomplete groups are kept as individual fragments
    with a warning marker.
    """
    single_packets = []
    fragment_groups = {}  # (service_id, seq) → [fragments]

    for p in g2_packets:
        if p["pkt_total"] <= 1:
            single_packets.append(p)
        else:
            # Include direction in key to prevent cross-direction fragment merging
            # (a TX and RX with same service+seq are independent messages)
            key = (p["service_id"], p["seq"], p["direction"])
            if key not in fragment_groups:
                fragment_groups[key] = []
            fragment_groups[key].append(p)

    reassembled = []
    for key, fragments in fragment_groups.items():
        fragments.sort(key=lambda p: p["pkt_serial"])

        # Detect duplicate serial numbers (corrupted capture or collision)
        serials = [f["pkt_serial"] for f in fragments]
        if len(set(serials)) != len(serials):
            for f in fragments:
                f["_reassembly"] = "corrupt_duplicate_serial"
            single_packets.extend(fragments)
            continue

        expected_total = fragments[0]["pkt_total"]
        if len(fragments) != expected_total:
            for f in fragments:
                f["_reassembly"] = "incomplete"
            single_packets.extend(fragments)
            continue

        # Concatenate protobuf payloads across fragments
        combined_payload = b"".join(f["payload"] for f in fragments)

        reassembled_pkt = dict(fragments[0])
        reassembled_pkt["payload"] = combined_payload
        reassembled_pkt["pkt_total"] = 1  # Now a single logical packet
        reassembled_pkt["crc_ok"] = all(f["crc_ok"] for f in fragments)
        reassembled_pkt["_reassembly"] = "complete"
        reassembled_pkt["_fragment_count"] = len(fragments)
        reassembled.append(reassembled_pkt)

    all_packets = single_packets + reassembled
    all_packets.sort(key=lambda p: p["pkt_num"])
    return all_packets


# =============================================================================
# Raw Protobuf Decoder
# =============================================================================

WIRE_VARINT = 0
WIRE_64BIT = 1
WIRE_LENGTH_DELIMITED = 2
WIRE_32BIT = 5

WIRE_TYPE_NAMES = {0: "varint", 1: "64-bit", 2: "bytes", 5: "32-bit"}


def decode_varint(data: bytes, pos: int) -> tuple:
    """Decode a protobuf varint, return (value, new_position)."""
    result = 0
    shift = 0
    while pos < len(data):
        b = data[pos]
        result |= (b & 0x7F) << shift
        pos += 1
        if not (b & 0x80):
            break
        shift += 7
        if shift >= 64:  # Protobuf varints are at most 10 bytes
            break
    return result, pos


def _is_valid_protobuf(data: bytes) -> bool:
    """Check if data can be fully consumed as protobuf with reasonable field numbers.

    Unlike decode_protobuf_raw (which silently stops on bad data and returns
    whatever it parsed so far), this requires the entire buffer to parse cleanly.
    Prevents false-positive nested message detection on random binary data.
    """
    if len(data) < 2:
        return False
    pos = 0
    field_count = 0
    while pos < len(data):
        try:
            tag, pos = decode_varint(data, pos)
        except (IndexError, ValueError):
            return False
        field_num = tag >> 3
        wire_type = tag & 0x07
        if field_num == 0 or field_num > 1000:
            return False
        if wire_type == WIRE_VARINT:
            try:
                _, pos = decode_varint(data, pos)
            except (IndexError, ValueError):
                return False
        elif wire_type == WIRE_64BIT:
            pos += 8
        elif wire_type == WIRE_LENGTH_DELIMITED:
            try:
                length, pos = decode_varint(data, pos)
            except (IndexError, ValueError):
                return False
            pos += length
        elif wire_type == WIRE_32BIT:
            pos += 4
        else:
            return False
        if pos > len(data):
            return False
        field_count += 1
    return field_count > 0 and pos == len(data)


def decode_protobuf_raw(data: bytes, indent: int = 0) -> list:
    """Decode raw protobuf bytes into a list of fields (no schema needed)."""
    fields = []
    pos = 0

    while pos < len(data):
        try:
            tag, pos = decode_varint(data, pos)
        except (IndexError, ValueError):
            break

        field_num = tag >> 3
        wire_type = tag & 0x07

        if field_num == 0 or field_num > 536870911:
            break  # Invalid or exceeds protobuf spec max (2^29 - 1)

        field = {"field": field_num, "wire_type": wire_type, "wire_type_name": WIRE_TYPE_NAMES.get(wire_type, "?")}

        if wire_type == WIRE_VARINT:
            value, pos = decode_varint(data, pos)
            field["value"] = value
            # Also show as signed (zigzag)
            field["signed"] = (value >> 1) ^ -(value & 1)

        elif wire_type == WIRE_64BIT:
            if pos + 8 > len(data):
                break
            raw = data[pos:pos + 8]
            field["value_hex"] = raw.hex()
            field["as_double"] = struct.unpack("<d", raw)[0]
            field["as_int64"] = struct.unpack("<q", raw)[0]
            pos += 8

        elif wire_type == WIRE_LENGTH_DELIMITED:
            length, pos = decode_varint(data, pos)
            if pos + length > len(data):
                break
            raw = data[pos:pos + length]
            field["length"] = length
            field["raw_hex"] = raw.hex()

            # Try to interpret as string
            try:
                text = raw.decode("utf-8")
                if all(c.isprintable() or c in "\n\r\t" for c in text):
                    field["as_string"] = text
            except (UnicodeDecodeError, ValueError):
                pass

            # Try to interpret as nested protobuf (only if it fully parses)
            try:
                if _is_valid_protobuf(raw):
                    nested = decode_protobuf_raw(raw, indent + 1)
                    if nested:
                        field["as_message"] = nested
            except Exception:
                pass

            pos += length

        elif wire_type == WIRE_32BIT:
            if pos + 4 > len(data):
                break
            raw = data[pos:pos + 4]
            field["value_hex"] = raw.hex()
            field["as_float"] = struct.unpack("<f", raw)[0]
            field["as_int32"] = struct.unpack("<i", raw)[0]
            pos += 4

        else:
            break  # Unknown wire type

        fields.append(field)

    return fields


def format_protobuf(fields: list, indent: int = 0) -> str:
    """Pretty-print decoded protobuf fields."""
    lines = []
    prefix = "    " * indent

    for f in fields:
        wt = f["wire_type_name"]
        fn = f["field"]

        if f["wire_type"] == WIRE_VARINT:
            val = f["value"]
            extra = ""
            if val != f["signed"] and f["signed"] < 0:
                extra = f" (signed: {f['signed']})"
            if val < 256:
                extra += f" (0x{val:02X})"
            lines.append(f"{prefix}field {fn:>2} [{wt:>6}]: {val}{extra}")

        elif f["wire_type"] == WIRE_64BIT:
            lines.append(f"{prefix}field {fn:>2} [64-bit]: 0x{f['value_hex']}  (int64={f['as_int64']})")

        elif f["wire_type"] == WIRE_LENGTH_DELIMITED:
            length = f["length"]
            if "as_string" in f and length > 0:
                s = f["as_string"]
                if len(s) > 80:
                    s = s[:77] + "..."
                lines.append(f"{prefix}field {fn:>2} [ bytes]: \"{s}\" ({length}B)")
            elif "as_message" in f:
                lines.append(f"{prefix}field {fn:>2} [ bytes]: <message> ({length}B)")
                lines.append(format_protobuf(f["as_message"], indent + 1))
            else:
                hex_str = f["raw_hex"]
                if len(hex_str) > 60:
                    hex_str = hex_str[:57] + "..."
                lines.append(f"{prefix}field {fn:>2} [ bytes]: {hex_str} ({length}B)")

        elif f["wire_type"] == WIRE_32BIT:
            lines.append(f"{prefix}field {fn:>2} [32-bit]: 0x{f['value_hex']}  (float={f['as_float']:.4f}, int32={f['as_int32']})")

    return "\n".join(lines)


# =============================================================================
# ADB Helpers
# =============================================================================

def adb_run(cmd: list, check: bool = True, timeout: int = 30) -> subprocess.CompletedProcess:
    """Run an ADB command."""
    full_cmd = ["adb"] + cmd
    try:
        result = subprocess.run(full_cmd, capture_output=True, text=True, timeout=timeout)
        if check and result.returncode != 0:
            print(f"  {C.RED}ADB error: {result.stderr.strip()}{C.RESET}")
        return result
    except FileNotFoundError:
        print(f"  {C.RED}ADB not found! Install Android SDK platform-tools.{C.RESET}")
        sys.exit(1)
    except subprocess.TimeoutExpired:
        print(f"  {C.RED}ADB command timed out.{C.RESET}")
        return subprocess.CompletedProcess(full_cmd, 1, "", "timeout")


def adb_check_connected() -> bool:
    """Check if an Android device is connected and authorized via ADB."""
    result = adb_run(["devices"], check=False)
    # Match lines like "SERIAL\tdevice" (not "offline", "unauthorized", etc.)
    lines = [l for l in result.stdout.strip().split("\n")[1:]
             if l.strip() and l.strip().endswith("\tdevice")]
    return len(lines) > 0


def adb_enable_snoop():
    """Enable Bluetooth HCI snoop log on the connected device."""
    print(f"\n  {C.CYAN}Enabling Bluetooth HCI snoop log...{C.RESET}")
    adb_run(["shell", "settings", "put", "secure", "bluetooth_hci_snoop_log_mode", "full"])
    print(f"  {C.YELLOW}Restarting Bluetooth to apply...{C.RESET}")
    adb_run(["shell", "svc", "bluetooth", "disable"])
    time.sleep(2)
    adb_run(["shell", "svc", "bluetooth", "enable"])
    time.sleep(3)
    print(f"  {C.GREEN}HCI snoop log enabled. Bluetooth restarted.{C.RESET}")


def adb_pull_snoop(label: str) -> str | None:
    """Pull the btsnoop_hci.log from the device."""
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    filename = f"{label}_{timestamp}.log"
    dest = CAPTURES_DIR / filename

    # Try standard path first
    print(f"\n  {C.CYAN}Pulling snoop log...{C.RESET}")
    result = adb_run(["pull", "/data/misc/bluetooth/logs/btsnoop_hci.log", str(dest)], check=False)

    if result.returncode == 0 and dest.exists() and dest.stat().st_size > 16:
        print(f"  {C.GREEN}Saved: {dest}{C.RESET}")
        return str(dest)

    # Try via bugreport
    print(f"  {C.YELLOW}Standard path failed. Trying bugreport method...{C.RESET}")
    bugreport_zip = CAPTURES_DIR / f"bugreport_{timestamp}.zip"
    result = adb_run(["bugreport", str(bugreport_zip)], check=False, timeout=300)

    if result.returncode == 0 and bugreport_zip.exists():
        # Extract btsnoop from bugreport
        import zipfile
        try:
            with zipfile.ZipFile(str(bugreport_zip), "r") as zf:
                for name in zf.namelist():
                    if "btsnoop" in name.lower() or "bluetooth" in name.lower():
                        extracted = zf.extract(name, str(CAPTURES_DIR))
                        final = CAPTURES_DIR / filename
                        os.rename(extracted, str(final))
                        print(f"  {C.GREEN}Extracted from bugreport: {final}{C.RESET}")
                        return str(final)
        except Exception as e:
            print(f"  {C.RED}Bugreport extraction failed: {e}{C.RESET}")

    # Try alternative paths
    alt_paths = [
        "/sdcard/btsnoop_hci.log",
        "/data/log/bt/btsnoop_hci.log",
        "/data/misc/bluedroid/btsnoop_hci.log",
    ]
    for path in alt_paths:
        result = adb_run(["pull", path, str(dest)], check=False)
        if result.returncode == 0 and dest.exists() and dest.stat().st_size > 16:
            print(f"  {C.GREEN}Saved (alt path): {dest}{C.RESET}")
            return str(dest)

    print(f"  {C.RED}Could not pull snoop log. You may need to pull it manually.{C.RESET}")
    print(f"  {C.DIM}Place the file in: {CAPTURES_DIR}/{C.RESET}")
    manual = input(f"  Enter path to log file (or press Enter to skip): ").strip()
    if manual and os.path.exists(manual):
        return manual
    return None


def adb_restart_bluetooth():
    """Restart Bluetooth for a fresh capture."""
    print(f"  {C.CYAN}Restarting Bluetooth for fresh capture...{C.RESET}")
    adb_run(["shell", "svc", "bluetooth", "disable"])
    time.sleep(2)
    adb_run(["shell", "svc", "bluetooth", "enable"])
    time.sleep(3)
    print(f"  {C.GREEN}Bluetooth restarted.{C.RESET}")


# =============================================================================
# Analysis Engine
# =============================================================================

def analyze_capture(filepath: str, verbose: bool = False) -> dict:
    """Analyze a btsnoop capture file and extract G2 protocol packets."""
    print(f"\n{C.BOLD}Analyzing: {os.path.basename(filepath)}{C.RESET}")
    print(f"{'─' * 60}")

    att_packets = parse_btsnoop(filepath)
    print(f"  ATT packets found: {len(att_packets)}")

    g2_packets_raw = []
    handle_map = {}  # ATT handle → direction

    for att in att_packets:
        val = att["value"]
        if len(val) >= 10 and val[0] == G2_MAGIC:
            g2 = parse_g2_packet(val)
            if g2:
                g2["att_handle"] = att["att_handle"]
                g2["att_direction"] = att["direction"]
                g2["pkt_num"] = att["pkt_num"]
                g2["timestamp"] = att["timestamp"]
                g2_packets_raw.append(g2)
                handle_map[att["att_handle"]] = att["direction"]

    # Reassemble multi-fragment G2 packets before protobuf decoding
    g2_packets = reassemble_g2_fragments(g2_packets_raw)

    # Build service stats after reassembly (counts reflect logical messages, not fragments)
    service_ids_seen = {}
    for g2 in g2_packets:
        sid = g2["service_id"]
        if sid not in service_ids_seen:
            service_ids_seen[sid] = {
                "name": g2["service_name"],
                "count": 0,
                "first_pkt": g2["pkt_num"],
                "directions": [],
            }
        service_ids_seen[sid]["count"] += 1
        d = g2["direction"]
        if d not in service_ids_seen[sid]["directions"]:
            service_ids_seen[sid]["directions"].append(d)

    reassembled_count = sum(1 for p in g2_packets if p.get("_reassembly") == "complete")
    crc_failures = sum(1 for p in g2_packets if not p.get("crc_ok", True))
    print(f"  G2 protocol packets: {len(g2_packets_raw)} raw, {len(g2_packets)} after reassembly"
          + (f" ({reassembled_count} multi-fragment)" if reassembled_count else ""))
    if crc_failures:
        print(f"  {C.RED}CRC failures: {crc_failures} packets have bad checksums — data may be corrupt{C.RESET}")
    print(f"  Unique service IDs: {len(service_ids_seen)}")

    # Print service summary
    if service_ids_seen:
        print(f"\n  {C.BOLD}Service IDs found:{C.RESET}")
        for sid, info in sorted(service_ids_seen.items()):
            name = info["name"]
            count = info["count"]
            dirs = ", ".join(sorted(info["directions"]))
            status = C.GREEN + "KNOWN" + C.RESET if name != "UNKNOWN" else C.YELLOW + "NEW!" + C.RESET
            print(f"    {sid:<12} {name:<20} {count:>4} pkts  [{dirs}]  {status}")

    # Print handle mapping
    if handle_map:
        print(f"\n  {C.BOLD}ATT Handle mapping:{C.RESET}")
        for handle, direction in sorted(handle_map.items()):
            print(f"    Handle 0x{handle:04X} → {direction}")

    # Decode packets if verbose
    if verbose:
        print(f"\n{C.BOLD}Packet Details:{C.RESET}")
        for g2 in g2_packets:
            print(f"\n  {C.CYAN}── Packet #{g2['pkt_num']} ──{C.RESET}")
            if g2.get("_reassembly") == "complete":
                print(f"  {C.GREEN}[reassembled from {g2['_fragment_count']} fragments]{C.RESET}")
            elif g2.get("_reassembly") == "incomplete":
                print(f"  {C.RED}[incomplete fragment — missing parts]{C.RESET}")
            print(f"  Direction: {g2['direction']}")
            print(f"  Service:   {g2['service_id']} ({g2['service_name']})")
            print(f"  Seq:       {g2['seq']}")
            print(f"  CRC:       {'OK' if g2['crc_ok'] else 'FAIL'}")
            if g2["payload"]:
                print(f"  Payload ({len(g2['payload'])}B): {g2['payload'].hex()}")
                fields = decode_protobuf_raw(g2["payload"])
                if fields:
                    print(f"  {C.MAGENTA}Protobuf decode:{C.RESET}")
                    print(format_protobuf(fields, indent=2))

    return {
        "filepath": filepath,
        "total_att_packets": len(att_packets),
        "g2_packets": g2_packets,
        "service_ids": service_ids_seen,
        "handle_map": handle_map,
        "_att_packets": att_packets,
    }


def analyze_and_show_new_services(filepath: str, progress: dict, context: str = "") -> dict:
    """Analyze a capture and highlight newly discovered service IDs."""
    result = analyze_capture(filepath, verbose=True)

    new_services = {}
    for sid, info in result["service_ids"].items():
        if info["name"] == "UNKNOWN" and sid not in progress.get("discovered_services", {}):
            new_services[sid] = info
            print(f"\n  {C.YELLOW}>>> NEW SERVICE ID: {sid} ({info['count']} packets) <<<{C.RESET}")

    if new_services:
        print(f"\n  {C.BOLD}New service IDs found! Let's label them.{C.RESET}")
        for sid in new_services:
            if context:
                print(f"  Context: you just performed '{context}'")
            label = input(f"  What service is {sid}? [{context or 'unknown'}]: ").strip()
            if not label and context:
                label = context
            if label:
                hi = int(sid.split("-")[0], 16)
                lo = int(sid.split("-")[1], 16)
                register_service(progress, hi, lo, label)
    elif not result["service_ids"]:
        print(f"\n  {C.RED}No G2 protocol packets found in this capture.{C.RESET}")
        print(f"  Make sure the glasses were connected during capture.")
    else:
        print(f"\n  {C.DIM}No new service IDs (all packets match known services).{C.RESET}")

    return result


# =============================================================================
# Interactive Helpers
# =============================================================================

def banner(text: str):
    width = max(60, len(text) + 4)
    print(f"\n{C.BOLD}{'═' * width}")
    print(f"  {text}")
    print(f"{'═' * width}{C.RESET}")


def step(phase: int, step_num: int, title: str):
    print(f"\n{C.BOLD}{C.BLUE}Step {phase}.{step_num} — {title}{C.RESET}")
    print(f"{'─' * 50}")


def instruct(text: str):
    print(f"  {C.YELLOW}→ {text}{C.RESET}")


def wait_for_user(prompt: str = "Press Enter when ready..."):
    input(f"\n  {C.CYAN}{prompt}{C.RESET}")


def ask_yes_no(prompt: str) -> bool:
    resp = input(f"  {prompt} [y/N]: ").strip().lower()
    return resp in ("y", "yes")


def _find_text_fields(fields: list, service_id: str, prefix: str = "", depth: int = 0):
    """Recursively search protobuf fields for text strings (any nesting depth)."""
    if depth > 8:
        return
    for f in fields:
        field_path = f"{prefix}.{f['field']}" if prefix else str(f["field"])
        if f["wire_type"] == WIRE_LENGTH_DELIMITED:
            if "as_string" in f and f.get("length", 0) > 0:
                text = f["as_string"]
                if len(text) > 2:  # Skip trivially short strings
                    print(f"\n  {C.GREEN}Found text in {service_id} field {field_path}:{C.RESET}")
                    print(f"    \"{text[:200]}\"")
            if "as_message" in f:
                _find_text_fields(f["as_message"], service_id, field_path, depth + 1)


def _get_capture_expectations(context: str) -> dict | None:
    """Return validation expectations for a given capture context.

    Returns a dict with:
      - description: what we expect to find (shown to user on failure)
      - check: callable(result) -> (bool, str) — True + detail if OK, False + reason if not
    Returns None for contexts where any G2 traffic is acceptable.
    """

    def _has_g2_packets(result, min_count=1):
        """Basic check: at least min_count G2 packets."""
        pkts = result.get("g2_packets", [])
        if len(pkts) < min_count:
            return False, f"only {len(pkts)} G2 packets (expected at least {min_count})"
        return True, f"{len(pkts)} G2 packets"

    def _has_service(result, svc_hi, svc_name, min_count=1):
        """Check for packets from a specific service by svc_hi byte."""
        pkts = [p for p in result.get("g2_packets", []) if p["svc_hi"] == svc_hi]
        if len(pkts) < min_count:
            return False, f"no {svc_name} packets (svc 0x{svc_hi:02X}) — expected at least {min_count}"
        return True, f"{len(pkts)} {svc_name} packets"

    def _has_text_in_packets(result, min_length=3):
        """Check if any G2 packet contains a text string."""
        for p in result.get("g2_packets", []):
            if not p.get("payload"):
                continue
            fields = decode_protobuf_raw(p["payload"])
            if _fields_contain_text(fields, min_length):
                return True, "text content found in packets"
        return False, "no text strings found in any packet payload"

    def _fields_contain_text(fields, min_length, depth=0):
        if depth > 8:
            return False
        for f in fields:
            if f["wire_type"] == WIRE_LENGTH_DELIMITED:
                if "as_string" in f and f.get("length", 0) > 0 and len(f["as_string"]) >= min_length:
                    return True
                if "as_message" in f:
                    if _fields_contain_text(f["as_message"], min_length, depth + 1):
                        return True
        return False

    def _has_audio_burst(result, min_burst=10):
        """Check for rapid packet bursts (~10ms spacing) indicating audio."""
        by_service = {}
        for p in result.get("g2_packets", []):
            sid = p["service_id"]
            if sid not in by_service:
                by_service[sid] = []
            by_service[sid].append(p)
        for sid, pkts in by_service.items():
            if len(pkts) < min_burst:
                continue
            burst = 0
            for i in range(1, len(pkts)):
                delta_ms = (pkts[i]["timestamp"] - pkts[i - 1]["timestamp"]) / 1000
                if 5 <= delta_ms <= 25:
                    burst += 1
            if burst >= min_burst:
                return True, f"{burst} audio-rate packets on {sid}"
        return False, f"no rapid packet bursts found (need {min_burst}+ packets at ~10ms intervals)"

    def _has_display_data(result):
        """Check for display-related data: large payloads, multi-fragment, or BMP headers."""
        g2 = result.get("g2_packets", [])
        att = result.get("_att_packets", [])
        # Check for large G2 payloads
        large = [p for p in g2 if len(p.get("payload", b"")) > 100]
        # Check for multi-fragment
        multi = [p for p in g2 if p.get("pkt_total", 1) > 1]
        # Check for BMP in raw ATT
        bmp = sum(1 for a in att if len(a["value"]) >= 2 and b"\x42\x4D" in a["value"])
        if large or multi or bmp:
            parts = []
            if large:
                parts.append(f"{len(large)} large payloads")
            if multi:
                parts.append(f"{len(multi)} multi-fragment")
            if bmp:
                parts.append(f"{bmp} BMP headers")
            return True, ", ".join(parts)
        return False, "no large payloads, multi-fragment transfers, or BMP headers found"

    def _has_new_or_known_services(result, min_services=2):
        """Check that we found at least min_services distinct service IDs."""
        sids = result.get("service_ids", {})
        if len(sids) < min_services:
            return False, f"only {len(sids)} service IDs (expected at least {min_services})"
        return True, f"{len(sids)} service IDs"

    def _has_non_auth_packets(result, min_count=1):
        """Check for packets beyond just auth/sync (svc_hi != 0x80)."""
        pkts = [p for p in result.get("g2_packets", []) if p["svc_hi"] != 0x80]
        if len(pkts) < min_count:
            return False, f"only auth/sync packets found — no application data"
        return True, f"{len(pkts)} application packets (non-auth)"

    # --- Expectation definitions per context ---
    expectations = {
        # Phase 1: Pairing
        "Glasses Reconnect Auth": {
            "description": "Auth handshake packets (service 0x80)",
            "check": lambda r: _has_service(r, 0x80, "Auth/Sync", min_count=2),
        },
        "Glasses Unpair": {
            "description": "Auth/disconnect packets",
            "check": lambda r: _has_g2_packets(r, min_count=1),
        },
        "Glasses First Pair": {
            "description": "Full pairing handshake (service 0x80, 5+ packets)",
            "check": lambda r: _has_service(r, 0x80, "Auth/Sync", min_count=5),
        },
        "Glasses Disconnect": {
            "description": "Disconnect sequence packets",
            "check": lambda r: _has_g2_packets(r, min_count=1),
        },
        "Ring Unpair": {
            "description": "Ring ATT packets (BAE80001 service)",
            "check": lambda r: _has_g2_packets(r, min_count=0) if r.get("total_att_packets", 0) > 0 else (False, "no ATT packets at all"),
        },
        "Ring First Pair": {
            "description": "Ring pairing ATT packets",
            "check": lambda r: (True, f"{r['total_att_packets']} ATT packets") if r.get("total_att_packets", 0) > 5 else (False, f"only {r.get('total_att_packets', 0)} ATT packets"),
        },
        "Ring Reconnect": {
            "description": "Ring reconnection ATT packets",
            "check": lambda r: (True, f"{r['total_att_packets']} ATT packets") if r.get("total_att_packets", 0) > 0 else (False, "no ATT packets"),
        },

        # Phase 2: Service Discovery
        "baseline": {
            "description": "Idle heartbeat packets (auth/sync + possibly config)",
            "check": lambda r: _has_g2_packets(r, min_count=2),
        },

        # Phase 3: Even AI
        "Even AI": {
            "description": "AI wake + response packets (multiple services, text content)",
            "check": lambda r: _check_all([
                _has_non_auth_packets(r, min_count=3),
                _has_new_or_known_services(r, min_services=2),
            ]),
        },

        # Phase 4: Audio
        "Audio/Conversate": {
            "description": "Audio frame bursts (~10ms spacing, 10+ packets)",
            "check": lambda r: _has_audio_burst(r, min_burst=10),
        },
        "Audio/Wake Word": {
            "description": "Audio frame bursts after wake word",
            "check": lambda r: _has_audio_burst(r, min_burst=10),
        },

        # Phase 5: Conversate
        "Conversate": {
            "description": "Conversate service packets (svc 0x0B) with text",
            "check": lambda r: _has_service(r, 0x0B, "Conversate", min_count=1),
        },

        # Phase 6: Translate/Transcribe
        "Translate": {
            "description": "Translation packets with text content",
            "check": lambda r: _has_non_auth_packets(r, min_count=2),
        },
        "Transcribe": {
            "description": "Transcription packets with text content",
            "check": lambda r: _has_non_auth_packets(r, min_count=2),
        },

        # Phase 7: Display
        "Teleprompter": {
            "description": "Teleprompter text packets (svc 0x06) with text content",
            "check": lambda r: _check_all([
                _has_service(r, 0x06, "Teleprompter", min_count=1),
                _has_text_in_packets(r),
            ]),
        },
        "Notification": {
            "description": "Notification display packets (text or display data)",
            "check": lambda r: _has_non_auth_packets(r, min_count=2),
        },
        "Dashboard": {
            "description": "Dashboard display packets (display data or page lifecycle)",
            "check": lambda r: _has_non_auth_packets(r, min_count=2),
        },
        "Navigation": {
            "description": "Navigation packets (large payloads or bitmap data)",
            "check": lambda r: _check_any([
                _has_display_data(r),
                _has_non_auth_packets(r, min_count=5),
            ]),
        },
        "Even AI Display": {
            "description": "AI response display packets with text",
            "check": lambda r: _check_all([
                _has_non_auth_packets(r, min_count=2),
                _has_text_in_packets(r),
            ]),
        },

        # Phase 8: Gestures
        "EvenHub/Gestures": {
            "description": "EvenHub gesture events (svc 0x81)",
            "check": lambda r: _has_service(r, 0x81, "EvenHub", min_count=1),
        },
        "EvenHub/Touch": {
            "description": "EvenHub touch events (svc 0x81)",
            "check": lambda r: _has_service(r, 0x81, "EvenHub", min_count=1),
        },
        "Ring Input": {
            "description": "Ring input events bridged to glasses",
            "check": lambda r: _has_non_auth_packets(r, min_count=1),
        },

        # Phase 9: Ring
        "Ring": {
            "description": "Ring connection ATT packets",
            "check": lambda r: (True, f"{r['total_att_packets']} ATT packets") if r.get("total_att_packets", 0) > 3 else (False, "very few ATT packets"),
        },
        "Ring Gestures": {
            "description": "Ring gesture ATT packets",
            "check": lambda r: (True, f"{r['total_att_packets']} ATT packets") if r.get("total_att_packets", 0) > 3 else (False, "very few ATT packets"),
        },
        "Health": {
            "description": "Health data sync packets",
            "check": lambda r: _has_non_auth_packets(r, min_count=1),
        },
        "Ring Battery": {
            "description": "Ring battery status packets",
            "check": lambda r: _has_g2_packets(r, min_count=1),
        },
        "Ring Charging": {
            "description": "Ring charging state change packets",
            "check": lambda r: _has_g2_packets(r, min_count=1),
        },

        # Phase 10: Minor
        "G2 Settings": {
            "description": "Settings change packets (config services)",
            "check": lambda r: _has_non_auth_packets(r, min_count=1),
        },
        "Glasses Battery": {
            "description": "Battery status packets",
            "check": lambda r: _has_g2_packets(r, min_count=1),
        },
        "Glasses Charging": {
            "description": "Charging state change packets",
            "check": lambda r: _has_g2_packets(r, min_count=1),
        },
        "Quick List": {
            "description": "Quick List display packets with text",
            "check": lambda r: _has_non_auth_packets(r, min_count=1),
        },
    }

    return expectations.get(context)


def _check_all(results: list[tuple[bool, str]]) -> tuple[bool, str]:
    """All checks must pass. Returns first failure or combined success."""
    for ok, reason in results:
        if not ok:
            return False, reason
    return True, "; ".join(r for _, r in results)


def _check_any(results: list[tuple[bool, str]]) -> tuple[bool, str]:
    """At least one check must pass. Returns first success or combined failures."""
    reasons = []
    for ok, reason in results:
        if ok:
            return True, reason
        reasons.append(reason)
    return False, "; ".join(reasons)


def capture_cycle(label: str, instructions: list[str], progress: dict, context: str = "") -> dict | None:
    """Run a full capture cycle: restart BT → instruct user → pull log → analyze.

    Validates that the capture contains expected data for the given context.
    Offers retry if validation fails.
    """
    MAX_RETRIES = 3
    expectations = _get_capture_expectations(context)

    for attempt in range(1, MAX_RETRIES + 1):
        if attempt > 1:
            print(f"\n  {C.YELLOW}── Retry {attempt}/{MAX_RETRIES} for '{label}' ──{C.RESET}")

        print(f"\n  {C.BOLD}Capture: {label}{C.RESET}")

        if ask_yes_no("Restart Bluetooth for fresh capture?"):
            adb_restart_bluetooth()

        print()
        for i, inst in enumerate(instructions, 1):
            instruct(f"{i}. {inst}")

        wait_for_user("Press Enter when done with the above steps...")

        filepath = adb_pull_snoop(label if attempt == 1 else f"{label}_retry{attempt}")
        if not filepath:
            if attempt < MAX_RETRIES and ask_yes_no("File pull failed. Retry this capture?"):
                continue
            return None

        capture_entry = {
            "label": label,
            "file": filepath,
            "time": datetime.now().isoformat(),
            "context": context,
            "attempt": attempt,
        }

        result = analyze_and_show_new_services(filepath, progress, context)

        # --- Validate the capture ---
        if not result:
            capture_entry["validation"] = {"passed": False, "reason": "analysis returned no data"}
            progress["captures"].append(capture_entry)
            save_progress(progress)
            if attempt < MAX_RETRIES and ask_yes_no("Analysis returned no data. Retry?"):
                continue
            return None

        g2_count = len(result.get("g2_packets", []))
        att_count = result.get("total_att_packets", 0)
        service_ids = list(result.get("service_ids", {}).keys())

        if expectations:
            ok, detail = expectations["check"](result)
            capture_entry["validation"] = {
                "passed": ok,
                "expected": expectations["description"],
                "detail": detail,
                "g2_packets": g2_count,
                "att_packets": att_count,
                "service_ids": service_ids,
            }
            progress["captures"].append(capture_entry)
            save_progress(progress)

            if ok:
                print(f"\n  {C.GREEN}✓ Capture validated: {detail}{C.RESET}")
            else:
                print(f"\n  {C.RED}✗ Capture validation FAILED for '{context}'{C.RESET}")
                print(f"    Expected: {expectations['description']}")
                print(f"    Problem:  {detail}")
                if attempt < MAX_RETRIES:
                    print(f"\n  {C.YELLOW}Troubleshooting tips:{C.RESET}")
                    print(f"    - Were the glasses connected during the capture?")
                    print(f"    - Did you see the expected behavior on the glasses?")
                    print(f"    - Try waiting longer before pressing Enter")
                    if ask_yes_no(f"Retry this capture? ({MAX_RETRIES - attempt} attempts remaining)"):
                        continue
                    else:
                        print(f"  {C.DIM}Proceeding with incomplete capture.{C.RESET}")
                else:
                    print(f"  {C.YELLOW}Max retries reached — proceeding with best capture.{C.RESET}")
        else:
            # No specific expectations — just confirm we got something
            capture_entry["validation"] = {
                "passed": g2_count > 0 or att_count > 0,
                "detail": f"{g2_count} G2 packets, {att_count} ATT packets",
                "g2_packets": g2_count,
                "att_packets": att_count,
                "service_ids": service_ids,
            }
            progress["captures"].append(capture_entry)
            save_progress(progress)

            if g2_count > 0:
                print(f"\n  {C.GREEN}✓ Capture OK: {g2_count} G2 packets, {att_count} total ATT{C.RESET}")
            elif att_count > 0:
                print(f"\n  {C.GREEN}✓ Capture OK: {att_count} ATT packets (no G2 framing){C.RESET}")

        return result

    return None


def print_validation_summary(progress: dict):
    """Print a summary of all capture validation results."""
    captures = progress.get("captures", [])
    if not captures:
        print(f"\n  {C.DIM}No captures recorded yet.{C.RESET}")
        return

    validated = [c for c in captures if "validation" in c]
    if not validated:
        print(f"\n  {C.DIM}No validated captures (older captures lack validation data).{C.RESET}")
        return

    passed = [c for c in validated if c["validation"].get("passed")]
    failed = [c for c in validated if not c["validation"].get("passed")]

    print(f"\n{C.BOLD}{'═' * 60}")
    print(f"  Capture Validation Summary")
    print(f"{'═' * 60}{C.RESET}")
    print(f"  Total: {len(validated)}  |  {C.GREEN}Passed: {len(passed)}{C.RESET}  |  {C.RED}Failed: {len(failed)}{C.RESET}\n")

    for c in validated:
        v = c["validation"]
        status = f"{C.GREEN}✓ PASS{C.RESET}" if v.get("passed") else f"{C.RED}✗ FAIL{C.RESET}"
        ctx = c.get("context", c["label"])
        attempt_info = f" (attempt {c['attempt']})" if c.get("attempt", 1) > 1 else ""
        detail = v.get("detail", "")
        print(f"  {status}  {ctx:<25}{attempt_info}")
        if detail:
            print(f"         {C.DIM}{detail}{C.RESET}")
        if not v.get("passed") and v.get("expected"):
            print(f"         {C.YELLOW}Expected: {v['expected']}{C.RESET}")

    if failed:
        print(f"\n  {C.YELLOW}Failed captures may need to be re-run for complete data.{C.RESET}")
        print(f"  Re-run specific phases with: --phase <number>\n")


# =============================================================================
# Phase Implementations
# =============================================================================

def phase_0_setup(progress: dict):
    """Phase 0: Prerequisites & Setup"""
    banner("PHASE 0: Prerequisites & Setup")

    print(f"""
  {C.BOLD}Required hardware:{C.RESET}
    - Android phone with Even app installed
    - G2 glasses paired to the phone
    - USB cable (for ADB)
    - Optional: R1 ring paired

  {C.BOLD}Required software:{C.RESET}
    - ADB (Android Debug Bridge)
    - Python 3 (you're running it now!)
    """)

    # Check ADB
    step(0, 1, "Check ADB Connection")
    if adb_check_connected():
        print(f"  {C.GREEN}ADB device connected!{C.RESET}")
        result = adb_run(["shell", "getprop", "ro.product.model"], check=False)
        if result.stdout.strip():
            print(f"  Device: {result.stdout.strip()}")
    else:
        print(f"  {C.RED}No ADB device found.{C.RESET}")
        instruct("Connect your Android phone via USB")
        instruct("Enable USB debugging in Developer Options")
        instruct("Accept the debugging prompt on your phone")
        wait_for_user("Press Enter after connecting...")

        if not adb_check_connected():
            print(f"  {C.RED}Still no device. Please fix ADB connection and re-run.{C.RESET}")
            return False

    # Enable HCI snoop
    step(0, 2, "Enable HCI Snoop Log")
    print(f"""
  This captures ALL Bluetooth traffic at the HCI level.
  Two options:
    A) Automatic via ADB (recommended)
    B) Manual: Settings → Developer Options → Enable Bluetooth HCI snoop log
    """)

    if ask_yes_no("Enable HCI snoop log via ADB?"):
        adb_enable_snoop()
    else:
        instruct("Go to Developer Options on your phone")
        instruct("Enable 'Bluetooth HCI snoop log'")
        instruct("Toggle Bluetooth OFF then ON")
        wait_for_user()

    # Quick test capture
    step(0, 3, "Test Capture")
    instruct("Open the Even app and connect to your G2 glasses")
    instruct("Wait 10 seconds for the connection to complete")
    wait_for_user("Press Enter after glasses are connected...")

    filepath = adb_pull_snoop("test_capture")
    if filepath:
        result = analyze_capture(filepath)
        if result["g2_packets"]:
            print(f"\n  {C.GREEN}Setup complete! G2 packets detected.{C.RESET}")
            mark_phase_done(progress, 0)
            return True
        else:
            print(f"\n  {C.YELLOW}No G2 packets found yet. This is normal if the")
            print(f"  glasses just connected. Continue to Phase 1.{C.RESET}")
            return True
    else:
        print(f"\n  {C.YELLOW}Could not pull log, but we can continue.{C.RESET}")
        return True


def _analyze_auth_packets(result: dict):
    """Detailed analysis of authentication/pairing packets."""
    if not result or not result.get("g2_packets"):
        return

    g2_packets = result["g2_packets"]

    # Filter auth packets (service 0x80)
    auth_pkts = [p for p in g2_packets if p["svc_hi"] == 0x80]
    other_pkts = [p for p in g2_packets if p["svc_hi"] != 0x80]

    print(f"\n  {C.BOLD}Authentication Packet Analysis:{C.RESET}")
    print(f"  Auth packets (0x80-xx): {len(auth_pkts)}")
    print(f"  Other packets: {len(other_pkts)}")

    if not auth_pkts:
        print(f"  {C.RED}No auth packets found!{C.RESET}")
        return

    # Show each auth packet in detail
    print(f"\n  {C.BOLD}Auth Sequence (in order):{C.RESET}")
    for i, p in enumerate(auth_pkts):
        direction = "APP→GLASSES" if "Phone" in p["direction"] else "GLASSES→APP"
        svc_lo = f"0x{p['svc_lo']:02X}"
        raw_hex = p["payload"].hex() if p["payload"] else ""

        print(f"\n  {C.CYAN}── Auth Packet {i+1} ──{C.RESET}")
        print(f"  Direction: {direction}")
        print(f"  Service:   0x80-{svc_lo}  ({'session mgmt' if p['svc_lo'] == 0x00 else 'auth' if p['svc_lo'] == 0x20 else 'unknown'})")
        print(f"  Seq:       {p['seq']}")
        print(f"  Raw ({len(p['payload'])}B): {raw_hex}")

        if p["payload"]:
            fields = decode_protobuf_raw(p["payload"])
            if fields:
                print(f"  {C.MAGENTA}Protobuf:{C.RESET}")
                print(format_protobuf(fields, indent=2))

                # Identify specific auth message types
                type_field = next((f for f in fields if f["field"] == 1 and f["wire_type"] == WIRE_VARINT), None)
                if type_field:
                    val = type_field["value"]
                    type_labels = {
                        0x04: "CAPABILITY_EXCHANGE",
                        0x05: "CAPABILITY_RESPONSE",
                        0x80: "TIME_SYNC",
                        0x0E: "SYNC_TRIGGER",
                    }
                    label = type_labels.get(val, f"UNKNOWN_TYPE_0x{val:02X}")
                    print(f"  {C.GREEN}→ Message type: {label}{C.RESET}")

    # Show timing between auth packets
    if len(auth_pkts) >= 2:
        print(f"\n  {C.BOLD}Auth Timing:{C.RESET}")
        for i in range(1, len(auth_pkts)):
            prev_ts = auth_pkts[i-1].get("timestamp", 0)
            curr_ts = auth_pkts[i].get("timestamp", 0)
            if prev_ts and curr_ts:
                delta_ms = (curr_ts - prev_ts) / 1000
                print(f"    Packet {i} → {i+1}: {delta_ms:.1f}ms")

    # Show non-auth packets that appeared during pairing (interesting context)
    if other_pkts:
        print(f"\n  {C.BOLD}Non-auth packets during pairing:{C.RESET}")
        for p in other_pkts[:10]:
            print(f"    #{p['pkt_num']:>5}  {p['direction']:<16}  {p['service_id']}  ({p['service_name']})")


def phase_1_pairing(progress: dict):
    """Phase 1: Pairing & Authentication Capture"""
    banner("PHASE 1: Pairing & Authentication (30-45 min)")
    print(f"""
  Goal: Capture the full pairing handshake for both G2 glasses and R1 ring.

  {C.BOLD}G2 Glasses Auth (known from decompiled code):{C.RESET}
    - 7-packet handshake: capability exchange → time sync
    - Service IDs: 0x80-00 (session mgmt) and 0x80-20 (auth)
    - We have phone→glasses packets; need glasses→phone RESPONSES

  {C.BOLD}R1 Ring Pairing (unknown — binary protocol):{C.RESET}
    - Service UUID: BAE80001-4F05-4503-8E65-3AF1F7329D1F
    - Write: BAE80012, Notify: BAE80013
    - NOT protobuf — custom binary format, completely undocumented
    """)

    # Step 1.1 — Capture glasses reconnection (non-destructive)
    step(1, 1, "Capture Glasses Reconnection Auth")
    print(f"  {C.DIM}This captures the re-auth that happens when already-paired glasses reconnect.{C.RESET}")
    print(f"  {C.DIM}Non-destructive — no need to unpair.{C.RESET}\n")
    result = capture_cycle(
        "glasses_reconnect_auth",
        [
            "Make sure glasses are DISCONNECTED (close Even app or turn off glasses)",
            "Restart Bluetooth on phone (script will do this automatically)",
            "Open Even app",
            "Wait for glasses to connect (watch for the connected indicator)",
            "Wait 15 seconds after connection is established",
        ],
        progress,
        context="Glasses Reconnect Auth",
    )
    if result:
        _analyze_auth_packets(result)

    # Step 1.2 — Capture glasses first-time pairing
    step(1, 2, "Capture Glasses First-Time Pairing")
    print(f"""
  {C.YELLOW}WARNING: This step requires unpairing your glasses from the Even app.
  You will need to re-pair them afterward. This is safe but takes a few minutes.{C.RESET}

  This captures the FULL first-time pairing handshake, which may include
  additional negotiation packets not seen during reconnection.
    """)

    if ask_yes_no("Capture first-time pairing? (requires unpair + re-pair)"):
        # First capture: unpair
        result_unpair = capture_cycle(
            "glasses_unpair",
            [
                "Open Even app → Device Settings",
                "Tap 'Unpair' or 'Forget device'",
                "Confirm the unpair",
                "Wait 10 seconds",
            ],
            progress,
            context="Glasses Unpair",
        )
        if result_unpair:
            print(f"\n  {C.BOLD}Unpair packets:{C.RESET}")
            _analyze_auth_packets(result_unpair)

        # Now capture the fresh pairing
        print(f"\n  {C.CYAN}Now let's capture the fresh pairing...{C.RESET}")
        if ask_yes_no("Restart Bluetooth for clean capture?"):
            adb_restart_bluetooth()

        result_pair = capture_cycle(
            "glasses_first_pair",
            [
                "Open Even app",
                "Go to 'Add Device' or scan for new glasses",
                "Put G2 glasses into pairing mode (hold power button if needed)",
                "Select your glasses from the scan list",
                "Wait for pairing to complete (including any on-screen prompts)",
                "Wait 15 seconds after fully connected",
            ],
            progress,
            context="Glasses First Pair",
        )
        if result_pair:
            print(f"\n  {C.BOLD}First-time pairing analysis:{C.RESET}")
            _analyze_auth_packets(result_pair)

            # Compare with reconnect
            if result:
                reconnect_auth = len([p for p in result["g2_packets"] if p["svc_hi"] == 0x80])
                firstpair_auth = len([p for p in result_pair["g2_packets"] if p["svc_hi"] == 0x80])
                print(f"\n  {C.BOLD}Comparison:{C.RESET}")
                print(f"    Reconnect auth packets: {reconnect_auth}")
                print(f"    First-pair auth packets: {firstpair_auth}")
                if firstpair_auth > reconnect_auth:
                    print(f"    {C.GREEN}→ First-time pairing has {firstpair_auth - reconnect_auth} extra packets!{C.RESET}")
    else:
        print(f"  {C.DIM}Skipped. You can re-run this phase later with --phase 1{C.RESET}")

    # Step 1.3 — Capture glasses disconnect
    step(1, 3, "Capture Graceful Disconnect")
    if ask_yes_no("Capture a graceful disconnect?"):
        capture_cycle(
            "glasses_disconnect",
            [
                "Make sure glasses are connected",
                "In Even app, tap disconnect (or close the app)",
                "Wait 10 seconds",
            ],
            progress,
            context="Glasses Disconnect",
        )

    # Step 1.4 — Capture R1 ring first-time pairing
    step(1, 4, "Capture R1 Ring First-Time Pairing")
    print(f"""
  {C.BOLD}R1 Ring uses a completely different BLE protocol:{C.RESET}
    - Service: BAE80001-4F05-4503-8E65-3AF1F7329D1F
    - Binary protocol (NOT protobuf like the G2)
    - Write to BAE80012, notifications on BAE80013

  {C.YELLOW}The btsnoop log captures ALL BLE traffic, so the ring's
  BAE80001 packets will be in the same capture file.
  However, the G2 packet parser won't decode them —
  look for raw ATT writes to handles matching BAE80012.{C.RESET}
    """)

    if ask_yes_no("Capture ring pairing? (need R1 ring, requires unpair + re-pair)"):
        # Unpair ring
        capture_cycle(
            "ring_unpair",
            [
                "Open Even app → Ring Settings",
                "Tap 'Unpair' or 'Forget ring'",
                "Confirm the unpair",
                "Wait 10 seconds",
            ],
            progress,
            context="Ring Unpair",
        )

        # Fresh ring pairing
        if ask_yes_no("Restart Bluetooth for clean ring capture?"):
            adb_restart_bluetooth()

        result_ring_pair = capture_cycle(
            "ring_first_pair",
            [
                "Open Even app",
                "Go to 'Add Ring' or ring pairing screen",
                "Put R1 ring into pairing mode (place on finger or hold button)",
                "Select the ring from scan list (EVEN R1_xxx)",
                "Wait for pairing to complete",
                "Wait 15 seconds after fully connected",
            ],
            progress,
            context="Ring First Pair",
        )

        if result_ring_pair:
            # Ring packets won't parse as G2 (different protocol), but we can
            # look at raw ATT packets for non-G2 traffic
            att_packets = result_ring_pair.get("_att_packets", [])
            non_g2_att = [a for a in att_packets
                         if len(a["value"]) > 0 and (len(a["value"]) < 10 or a["value"][0] != G2_MAGIC)]
            print(f"\n  {C.BOLD}Ring Protocol Analysis:{C.RESET}")
            print(f"  Total ATT packets: {len(att_packets)}")
            print(f"  Non-G2 ATT packets (likely ring): {len(non_g2_att)}")

            if non_g2_att:
                print(f"\n  {C.BOLD}Non-G2 packets (ring protocol candidates):{C.RESET}")
                for a in non_g2_att[:20]:
                    direction = a["direction"]
                    handle = a["att_handle"]
                    val = a["value"]
                    print(f"    #{a['pkt_num']:>5}  {direction:<4}  handle=0x{handle:04X}  {len(val):>4}B  {val[:20].hex()}")

                # Group by handle to identify ring characteristics
                ring_handles = {}
                for a in non_g2_att:
                    h = a["att_handle"]
                    if h not in ring_handles:
                        ring_handles[h] = {"TX": 0, "RX": 0, "total_bytes": 0}
                    ring_handles[h][a["direction"]] += 1
                    ring_handles[h]["total_bytes"] += len(a["value"])

                print(f"\n  {C.BOLD}Handle summary (non-G2):{C.RESET}")
                for h, info in sorted(ring_handles.items()):
                    print(f"    0x{h:04X}: TX={info['TX']}, RX={info['RX']}, {info['total_bytes']}B total")
            else:
                print(f"  {C.YELLOW}No non-G2 ATT packets found. Ring traffic might use a different")
                print(f"  L2CAP channel or need tshark for proper decoding.{C.RESET}")

    # Step 1.5 — Capture R1 ring reconnection
    step(1, 5, "Capture R1 Ring Reconnection")
    if ask_yes_no("Capture ring reconnection?"):
        capture_cycle(
            "ring_reconnect",
            [
                "Make sure ring is disconnected (take off finger or turn off)",
                "Restart Bluetooth on phone",
                "Put ring back on (or turn on)",
                "Open Even app, wait for ring to reconnect",
                "Wait 15 seconds after connected",
            ],
            progress,
            context="Ring Reconnect",
        )

    # Step 1.6 — Summary
    step(1, 6, "Pairing Capture Summary")
    print(f"""
  {C.BOLD}What we captured:{C.RESET}
    - Glasses reconnection auth (phone→glasses AND glasses→phone)
    - Glasses first-time pairing (full capability exchange)
    - Glasses graceful disconnect
    - R1 Ring first-time pairing (binary protocol on BAE80001)
    - R1 Ring reconnection

  {C.BOLD}Next steps for analysis:{C.RESET}
    - Compare reconnect vs first-pair auth packets
    - Identify glasses→phone response fields (not in working code)
    - Map ring ATT handles to BAE80012/BAE80013
    - Decode ring binary command format
    """)

    wait_for_user()
    mark_phase_done(progress, 1)


def phase_2_service_discovery(progress: dict):
    """Phase 2: Service ID Discovery"""
    banner("PHASE 2: Service ID Discovery (30 min)")
    print(f"  Goal: Map every service to its 2-byte service ID.\n")

    # Step 1.1 — Baseline
    step(2, 1, "Baseline Capture (idle connection)")
    capture_cycle(
        "baseline_idle",
        [
            "Open the Even app",
            "Connect to G2 glasses (let it complete auth + sync)",
            "DO NOTHING for 30 seconds — let idle heartbeats flow",
        ],
        progress,
        context="baseline",
    )

    # Step 1.2 — Already done above (analysis identifies known services)
    step(2, 2, "Review Known Services")
    print_service_table(progress)
    wait_for_user()

    # Step 1.3 — Trigger each service one at a time
    step(2, 3, "Trigger Unknown Services (one at a time)")

    service_triggers = [
        ("even_ai", "Even AI", [
            "Make sure glasses are connected",
            "Say 'Hey Even' clearly toward the glasses",
            "Wait for the AI prompt to appear",
            "Say 'What time is it?'",
            "Wait for the AI response",
            "Wait 10 more seconds",
        ]),
        ("translate", "Translate", [
            "Open the Translate feature in Even app",
            "Set a language pair (e.g., English → French)",
            "Speak a few sentences",
            "Wait for translation to appear",
            "Stop the session",
        ]),
        ("transcribe", "Transcribe", [
            "Open the Transcribe feature in Even app",
            "Speak a few sentences",
            "Wait for transcription to appear",
            "Stop the session",
        ]),
        ("navigation", "Navigation", [
            "Start navigation in the app (Google Maps → Even bridge)",
            "If possible, follow at least 1-2 turns",
            "Wait 15 seconds",
        ]),
        ("quick_list", "Quick List", [
            "Open Quick List in Even app",
            "Create a list with 3 items if none exists",
            "Send the list to glasses",
        ]),
        ("health", "Health", [
            "Make sure R1 ring is connected",
            "Open the Health tab in Even app",
            "Wait for data to sync",
        ]),
        ("ring_gesture", "Ring", [
            "Make sure R1 ring is connected",
            "Single tap the ring",
            "Wait 5 seconds",
            "Double tap the ring",
        ]),
        ("settings", "G2 Settings", [
            "Open glasses settings in Even app",
            "Change the display brightness",
            "Change another setting (e.g., head-up angle)",
        ]),
        ("glasses_case", "Glasses Case", [
            "Put the glasses in the charging case briefly",
            "Take them back out",
            "Wait for reconnection",
        ]),
    ]

    for label, service_name, instructions in service_triggers:
        key = f"trigger_{label}"
        if key in progress.get("completed_steps", []):
            print(f"\n  {C.DIM}Skipping {service_name} (already captured){C.RESET}")
            continue

        print(f"\n  {C.BOLD}Next: Trigger {service_name}{C.RESET}")
        if not ask_yes_no(f"Capture {service_name}? (skip if not available)"):
            print(f"  {C.DIM}Skipped.{C.RESET}")
            continue

        result = capture_cycle(label, instructions, progress, context=service_name)
        progress["completed_steps"].append(key)
        save_progress(progress)

    # Step 1.4 — Summary
    step(2, 4, "Service Discovery Summary")
    print_service_table(progress)

    mark_phase_done(progress, 2)


def phase_3_even_ai(progress: dict):
    """Phase 2: Even AI Protocol — HIGHEST PRIORITY"""
    banner("PHASE 3: Even AI Protocol (1-2 hours)")
    print(f"  Goal: Fully decode the Even AI wake → audio → reply cycle.\n")

    # Step 2.1 — Capture wake word
    step(3, 1, "Capture Wake Word + AI Response")
    result = capture_cycle(
        "even_ai_full",
        [
            "Connect glasses via Even app",
            "Wait for idle (10 seconds)",
            "Say 'Hey Even' clearly",
            "Wait for the AI prompt on glasses",
            "Say a simple question: 'What time is it?'",
            "Wait for the AI response to display",
            "Wait 10 more seconds",
        ],
        progress,
        context="Even AI",
    )

    if result and result["g2_packets"]:
        # Detailed analysis
        step(3, 2, "Decode Wake-Up Sequence")
        print(f"\n  Looking for glasses→phone packets right after idle...")
        print(f"  These should be on characteristic 5402 with a new service ID.")
        print(f"  The service ID bytes identify the Even AI service.\n")

        # Find RX packets (glasses → phone) that might be wake-up
        rx_packets = [p for p in result["g2_packets"] if "Glasses" in p["direction"]]
        if rx_packets:
            print(f"  Found {len(rx_packets)} glasses→phone packets:")
            for p in rx_packets[:10]:
                print(f"    #{p['pkt_num']:>5}  {p['service_id']}  ({p['service_name']})  {len(p['payload'])}B")
                if p["payload"]:
                    fields = decode_protobuf_raw(p["payload"])
                    if fields:
                        print(format_protobuf(fields, indent=3))

        step(3, 3, "Decode AI Response")
        print(f"\n  Looking for phone→glasses packets with text content...")
        tx_packets = [p for p in result["g2_packets"] if "Phone" in p["direction"]]
        for p in tx_packets:
            if p["payload"]:
                fields = decode_protobuf_raw(p["payload"])
                _find_text_fields(fields, p["service_id"], prefix="")

        step(3, 4, "Check Audio Channel")
        print(f"\n  Audio data might flow on characteristic 7402 (third channel).")
        print(f"  ATT handles seen in this capture:")
        for handle, direction in sorted(result["handle_map"].items()):
            print(f"    0x{handle:04X} → {direction}")

    wait_for_user()
    mark_phase_done(progress, 3)


def _extract_audio_frames(g2_packets: list) -> list:
    """Extract likely audio frames from G2 packets based on timing and size.

    Audio frames are LC3-encoded at 10ms intervals (16kHz, mono).
    Expected frame size: ~40-80 bytes depending on bitrate.
    Returns list of dicts with payload bytes and metadata.
    """
    frames = []

    # First pass: find service IDs with rapid successive packets (~10ms spacing)
    # Group packets by service ID
    by_service = {}
    for p in g2_packets:
        sid = p["service_id"]
        if sid not in by_service:
            by_service[sid] = []
        by_service[sid].append(p)

    audio_service = None
    best_burst = 0

    for sid, pkts in by_service.items():
        if len(pkts) < 10:
            continue
        burst = 0
        for i in range(1, len(pkts)):
            delta_us = pkts[i]["timestamp"] - pkts[i - 1]["timestamp"]
            delta_ms = delta_us / 1000
            if 5 <= delta_ms <= 25:  # ~10ms LC3 frame interval with jitter
                burst += 1
        if burst > best_burst:
            best_burst = burst
            audio_service = sid

    if not audio_service or best_burst < 10:
        return []

    # Second pass: extract frame payloads from the identified audio service
    for p in by_service[audio_service]:
        payload = p.get("payload", b"")
        if not payload:
            continue

        # The protobuf payload contains the LC3 frame.
        # Try to extract the raw bytes field (typically field 1 or 2, length-delimited).
        fields = decode_protobuf_raw(payload)
        frame_data = None
        for f in fields:
            if f["wire_type"] == WIRE_LENGTH_DELIMITED and "raw_hex" in f:
                raw = bytes.fromhex(f["raw_hex"])
                # LC3 frames at 16kHz/10ms are typically 20-80 bytes
                if 10 <= len(raw) <= 200:
                    frame_data = raw
                    break

        if frame_data is None:
            # Fallback: use entire protobuf payload as frame
            frame_data = payload

        frames.append({
            "pkt_num": p["pkt_num"],
            "timestamp": p["timestamp"],
            "service_id": audio_service,
            "frame_bytes": frame_data,
            "raw_payload": payload,
        })

    return frames


def _save_audio_frames(frames: list, output_path: str, save_pcm: bool = False):
    """Save extracted audio frames to files for analysis.

    Saves:
      - <output_path>.lc3_frames  — raw LC3 frame data (concatenated)
      - <output_path>.frame_log   — CSV of frame sizes and timestamps
      - <output_path>.pcm         — decoded PCM if liblc3 is available and save_pcm=True
    """
    if not frames:
        print(f"  {C.RED}No audio frames to save.{C.RESET}")
        return

    # Save raw LC3 frames (concatenated with 2-byte length prefix per frame)
    lc3_path = output_path + ".lc3_frames"
    with open(lc3_path, "wb") as f:
        for frame in frames:
            data = frame["frame_bytes"]
            f.write(struct.pack("<H", len(data)))
            f.write(data)
    print(f"  {C.GREEN}Saved {len(frames)} LC3 frames to: {lc3_path}{C.RESET}")

    # Save frame log (for analysis of timing, sizes)
    log_path = output_path + ".frame_log"
    with open(log_path, "w") as f:
        f.write("pkt_num,timestamp_us,frame_size,service_id\n")
        for frame in frames:
            f.write(f"{frame['pkt_num']},{frame['timestamp']},{len(frame['frame_bytes'])},{frame['service_id']}\n")
    print(f"  {C.GREEN}Saved frame log to: {log_path}{C.RESET}")

    # Analyze frame statistics
    sizes = [len(f["frame_bytes"]) for f in frames]
    deltas = []
    for i in range(1, len(frames)):
        d = (frames[i]["timestamp"] - frames[i - 1]["timestamp"]) / 1000  # ms
        if d > 0:
            deltas.append(d)

    print(f"\n  {C.BOLD}Audio Frame Statistics:{C.RESET}")
    print(f"    Total frames:  {len(frames)}")
    print(f"    Frame sizes:   min={min(sizes)}B, max={max(sizes)}B, avg={sum(sizes)/len(sizes):.0f}B")
    if deltas:
        avg_delta = sum(deltas) / len(deltas)
        print(f"    Frame spacing:  avg={avg_delta:.1f}ms (expected: 10ms for LC3)")
        duration_s = sum(deltas) / 1000
        print(f"    Est. duration: {duration_s:.1f}s")

    # Verify LC3 format (works without decoder libraries)
    _verify_lc3_format(frames)

    # Try LC3 decode to PCM if requested
    if save_pcm:
        _try_lc3_decode(frames, output_path + ".pcm")


def _verify_lc3_format(frames: list):
    """Verify captured frames match the LC3 audio codec format without decoding.

    Checks:
      1. Frame size consistency (LC3 produces fixed-size frames per config)
      2. Frame sizes vs LC3 spec for known bitrate/sample-rate combos
      3. Timing regularity (10ms intervals expected)
      4. Byte entropy (compressed audio has high entropy, ~7+ bits/byte)
      5. Not plaintext or simple protobuf (rules out non-audio data)
    """
    if not frames:
        print(f"  {C.YELLOW}No frames to verify.{C.RESET}")
        return

    print(f"\n  {C.BOLD}LC3 Format Verification:{C.RESET}")

    sizes = [len(f["frame_bytes"]) for f in frames]
    unique_sizes = set(sizes)
    most_common_size = max(unique_sizes, key=lambda s: sizes.count(s))
    size_consistency = sizes.count(most_common_size) / len(sizes) * 100

    # --- Check 1: Frame size consistency ---
    # LC3 produces fixed-size frames for a given config
    print(f"    Frame count:       {len(frames)}")
    print(f"    Dominant size:     {most_common_size} bytes ({size_consistency:.0f}% of frames)")
    print(f"    Unique sizes:      {len(unique_sizes)} ({sorted(unique_sizes)})")
    if size_consistency >= 90:
        print(f"    {C.GREEN}[PASS]{C.RESET} Frame sizes are consistent (expected for LC3)")
    else:
        print(f"    {C.YELLOW}[WARN]{C.RESET} Frame sizes vary — may not be LC3 or bitrate is adaptive")

    # --- Check 2: Size matches known LC3 configurations ---
    # LC3 frame size = (bitrate * frame_duration_ms) / (8 * 1000)
    # Common configs at 10ms frame duration:
    #   16kHz/32kbps  → 40 bytes     16kHz/48kbps → 60 bytes
    #   16kHz/64kbps  → 80 bytes     32kHz/64kbps → 80 bytes
    #   16kHz/24kbps  → 30 bytes     16kHz/16kbps → 20 bytes
    known_lc3_sizes = {
        20: "16kHz/16kbps", 26: "16kHz/20.8kbps", 30: "16kHz/24kbps",
        40: "16kHz/32kbps", 50: "16kHz/40kbps", 60: "16kHz/48kbps",
        80: "16kHz/64kbps or 32kHz/64kbps", 100: "32kHz/80kbps",
        120: "48kHz/96kbps", 150: "48kHz/120kbps",
    }
    if most_common_size in known_lc3_sizes:
        config = known_lc3_sizes[most_common_size]
        print(f"    {C.GREEN}[PASS]{C.RESET} Frame size {most_common_size}B matches LC3 config: {config}")
    else:
        # Check if close to a known size (within 2 bytes for overhead/padding)
        close = [s for s in known_lc3_sizes if abs(s - most_common_size) <= 2]
        if close:
            config = known_lc3_sizes[close[0]]
            print(f"    {C.CYAN}[NEAR]{C.RESET} Frame size {most_common_size}B is close to LC3 config: {config} ({close[0]}B)")
        else:
            print(f"    {C.YELLOW}[UNKNOWN]{C.RESET} Frame size {most_common_size}B doesn't match common LC3 configs")

    # --- Check 3: Timing regularity ---
    deltas = []
    for i in range(1, len(frames)):
        d = (frames[i]["timestamp"] - frames[i - 1]["timestamp"]) / 1000  # ms
        if d > 0:
            deltas.append(d)

    if deltas:
        avg_delta = sum(deltas) / len(deltas)
        within_tolerance = sum(1 for d in deltas if 7 <= d <= 13) / len(deltas) * 100
        print(f"    Avg spacing:       {avg_delta:.1f}ms (expected: 10ms)")
        print(f"    Within 7-13ms:     {within_tolerance:.0f}%")
        if within_tolerance >= 80:
            print(f"    {C.GREEN}[PASS]{C.RESET} Timing matches LC3 10ms frame interval")
        elif within_tolerance >= 50:
            print(f"    {C.YELLOW}[WARN]{C.RESET} Timing partially matches — some jitter or gaps")
        else:
            print(f"    {C.RED}[FAIL]{C.RESET} Timing does not match 10ms LC3 intervals")

    # --- Check 4: Byte entropy ---
    # Compressed audio should have high entropy (near 8 bits/byte)
    # Plaintext/protobuf structure has lower entropy
    sample_data = b"".join(f["frame_bytes"] for f in frames[:50])
    if sample_data:
        byte_counts = [0] * 256
        for b in sample_data:
            byte_counts[b] += 1
        total = len(sample_data)
        import math
        entropy = -sum(
            (c / total) * math.log2(c / total) for c in byte_counts if c > 0
        )
        print(f"    Byte entropy:      {entropy:.2f} bits/byte (max 8.0)")
        if entropy >= 7.0:
            print(f"    {C.GREEN}[PASS]{C.RESET} High entropy — consistent with compressed audio")
        elif entropy >= 5.5:
            print(f"    {C.CYAN}[MAYBE]{C.RESET} Moderate entropy — could be compressed audio with headers")
        else:
            print(f"    {C.RED}[FAIL]{C.RESET} Low entropy — unlikely to be compressed audio")

    # --- Check 5: Not plaintext or structured protobuf ---
    sample = frames[0]["frame_bytes"]
    is_ascii = all(32 <= b <= 126 or b in (10, 13, 9) for b in sample)
    if is_ascii:
        print(f"    {C.RED}[FAIL]{C.RESET} First frame is ASCII text — not audio data")
    else:
        print(f"    {C.GREEN}[PASS]{C.RESET} Binary data (not ASCII text)")

    # --- Verdict ---
    checks_passed = 0
    checks_total = 5
    if size_consistency >= 90:
        checks_passed += 1
    if most_common_size in known_lc3_sizes or close:
        checks_passed += 1
    if deltas and within_tolerance >= 80:
        checks_passed += 1
    if sample_data and entropy >= 7.0:
        checks_passed += 1
    if not is_ascii:
        checks_passed += 1

    print(f"\n    {C.BOLD}Verdict: {checks_passed}/{checks_total} checks passed{C.RESET}")
    if checks_passed >= 4:
        print(f"    {C.GREEN}Audio format is almost certainly LC3 (16kHz, 10ms frames){C.RESET}")
    elif checks_passed >= 3:
        print(f"    {C.CYAN}Audio format is likely LC3 — some characteristics don't fully match{C.RESET}")
    elif checks_passed >= 2:
        print(f"    {C.YELLOW}Inconclusive — data may be LC3 or another codec{C.RESET}")
    else:
        print(f"    {C.RED}Unlikely to be LC3 audio data{C.RESET}")


def _try_lc3_decode(frames: list, pcm_path: str):
    """Attempt to decode LC3 frames to PCM using pylc3 or lc3-codec.

    LC3 parameters (from dex analysis):
      - Frame duration: 10ms (10000 µs)
      - Sample rate: 16kHz
      - Output: 16-bit signed PCM, mono
      - 160 samples per frame = 320 bytes PCM per frame
    """
    # Try pylc3 (pip install pylc3)
    try:
        import pylc3  # noqa: F811
        decoder = pylc3.Decoder(dt_us=10000, sr_hz=16000)
        pcm_samples = []
        decode_errors = 0
        for frame in frames:
            try:
                pcm = decoder.decode(frame["frame_bytes"])
                pcm_samples.append(pcm)
            except Exception:
                decode_errors += 1
                # Insert silence on decode error
                pcm_samples.append(b"\x00" * 320)

        with open(pcm_path, "wb") as f:
            for pcm in pcm_samples:
                f.write(pcm)

        print(f"  {C.GREEN}Decoded to PCM: {pcm_path}{C.RESET}")
        print(f"    Format: 16-bit signed, 16kHz, mono")
        print(f"    Decode errors: {decode_errors}/{len(frames)}")
        print(f"    Play with: ffplay -f s16le -ar 16000 -ac 1 {pcm_path}")
        return
    except ImportError:
        pass

    # Try lc3 module (pip install lc3-codec)
    try:
        import lc3  # noqa: F811
        dec = lc3.decoder(10000, 16000)
        pcm_samples = []
        decode_errors = 0
        for frame in frames:
            try:
                pcm = dec.decode(frame["frame_bytes"])
                pcm_samples.append(pcm)
            except Exception:
                decode_errors += 1
                pcm_samples.append(b"\x00" * 320)

        with open(pcm_path, "wb") as f:
            for pcm in pcm_samples:
                f.write(pcm)

        print(f"  {C.GREEN}Decoded to PCM: {pcm_path}{C.RESET}")
        print(f"    Format: 16-bit signed, 16kHz, mono")
        print(f"    Decode errors: {decode_errors}/{len(frames)}")
        print(f"    Play with: ffplay -f s16le -ar 16000 -ac 1 {pcm_path}")
        return
    except ImportError:
        pass

    print(f"  {C.YELLOW}No LC3 decoder available. Install one:{C.RESET}")
    print(f"    pip install pylc3        # Google's Python bindings")
    print(f"    pip install lc3-codec    # Alternative")
    print(f"  Then re-run to decode the saved .lc3_frames file.")
    print(f"  Or use liblc3 C library: https://github.com/google/liblc3")


def phase_4_audio(progress: dict):
    """Phase 3: Audio Protocol Details"""
    banner("PHASE 4: Audio Protocol Details (30 min)")
    print(f"""
  Goal: Capture audio frames from the G2 microphone and decode LC3.

  {C.BOLD}Verified from dex bytecode (updated extract):{C.RESET}
    - Audio: LC3 codec, decoded by flutter_ezw_lc3 plugin
    - Processing: flutter_ezw_audio (AGC, speech enhancement)
    - STT: Azure Cognitive Services Speech SDK (PushAudioInputStream)
    - Translation: com.even.translate.azure.translation.AzureTranslationRecognizer
    - Audio is NOT encrypted (LC3 = codec compression, not encryption)
    - BLE link-layer encryption is OS-managed (standard pairing)

  {C.BOLD}Expected LC3 parameters:{C.RESET}
    - Frame duration: 10ms
    - Sample rate: 16kHz
    - Output: 160 samples × 16-bit = 320 bytes PCM per frame
    """)

    step(4, 1, "Capture App-Initiated Audio (Conversate)")
    result = capture_cycle(
        "audio_conversate",
        [
            "Connect glasses via Even app",
            "Open the Conversate feature",
            "Speak clearly for 10-15 seconds",
            "Stop Conversate",
        ],
        progress,
        context="Audio/Conversate",
    )

    if result and result["g2_packets"]:
        step(4, 2, "Identify Audio Control & Data")

        # Look for rapid successive packets (audio frames)
        timestamps = [(p["pkt_num"], p["timestamp"], len(p["payload"]), p["service_id"])
                      for p in result["g2_packets"]]

        if len(timestamps) >= 2:
            print(f"\n  Packet timing analysis (looking for audio frame bursts):")
            prev_ts = timestamps[0][1]
            burst_count = 0
            for pkt_num, ts, size, sid in timestamps[1:]:
                delta_ms = (ts - prev_ts) / 1000  # microseconds to ms
                if 5 <= delta_ms <= 20:  # ~10ms frame interval
                    burst_count += 1
                    if burst_count <= 5 or burst_count % 50 == 0:
                        print(f"    #{pkt_num:>5}  Δ{delta_ms:>6.1f}ms  {size:>4}B  {sid}  {'<-- likely audio frame' if burst_count <= 5 else ''}")
                prev_ts = ts

            if burst_count > 10:
                print(f"\n  {C.GREEN}Found {burst_count} packets with ~10ms spacing → likely audio frames{C.RESET}")
                print(f"  LC3 parameters estimate: 10ms frames @ 16kHz = ~40B/frame")
            else:
                print(f"\n  {C.YELLOW}Only {burst_count} rapid packets found. Audio may be on 7402 (third channel).{C.RESET}")

        # Extract and save audio frames
        step(4, 3, "Extract & Decode Audio Frames")
        frames = _extract_audio_frames(result["g2_packets"])

        if frames:
            output_base = str(RESULTS_DIR / "audio_capture")
            _save_audio_frames(frames, output_base, save_pcm=True)

            print(f"\n  {C.BOLD}Audio service ID: {frames[0]['service_id']}{C.RESET}")
            print(f"  This is the service ID for audio data. Register it.")

            # Register audio service
            sid = frames[0]["service_id"]
            if sid not in progress.get("discovered_services", {}):
                hi = int(sid.split("-")[0], 16)
                lo = int(sid.split("-")[1], 16)
                register_service(progress, hi, lo, "Audio Data")
        else:
            print(f"\n  {C.YELLOW}No audio frames detected in G2 packets.{C.RESET}")
            print(f"  Audio may flow on characteristic 7402 (third channel),")
            print(f"  which may not be captured as G2 protocol packets.")
            print(f"  Check raw ATT packets for handle 0x7402 data.")

            # Check raw ATT traffic for non-G2 high-frequency data
            att_packets = result.get("_att_packets", [])
            non_g2 = [a for a in att_packets
                      if len(a["value"]) > 0 and (len(a["value"]) < 10 or a["value"][0] != G2_MAGIC)]
            if non_g2:
                print(f"\n  {C.CYAN}Found {len(non_g2)} non-G2 ATT packets — checking for audio...{C.RESET}")
                # Group by handle
                by_handle = {}
                for a in non_g2:
                    h = a["att_handle"]
                    if h not in by_handle:
                        by_handle[h] = []
                    by_handle[h].append(a)
                for h, pkts in sorted(by_handle.items(), key=lambda x: -len(x[1])):
                    if len(pkts) > 20:
                        sizes = [len(p["value"]) for p in pkts]
                        print(f"    Handle 0x{h:04X}: {len(pkts)} pkts, avg {sum(sizes)/len(sizes):.0f}B — {'likely audio!' if len(pkts) > 50 else ''}")

    # Step 4.4 — Capture wake-word triggered audio
    step(4, 4, "Capture Wake Word Audio (Hey Even)")
    if ask_yes_no("Capture wake-word triggered audio?"):
        result_wake = capture_cycle(
            "audio_wake_word",
            [
                "Connect glasses via Even app",
                "Wait 10 seconds for idle",
                "Say 'Hey Even' clearly",
                "Wait for AI prompt, then speak for 10 seconds",
                "Wait for AI response",
                "Wait 10 more seconds",
            ],
            progress,
            context="Audio/Wake Word",
        )

        if result_wake and result_wake["g2_packets"]:
            frames = _extract_audio_frames(result_wake["g2_packets"])
            if frames:
                output_base = str(RESULTS_DIR / "audio_wake_word")
                _save_audio_frames(frames, output_base, save_pcm=True)

    wait_for_user()
    mark_phase_done(progress, 4)


def phase_5_conversate(progress: dict):
    """Phase 4: Conversate Protocol"""
    banner("PHASE 5: Conversate Protocol (30 min)")
    print(f"  Goal: Confirm all Conversate field numbers for real-time text.\n")

    step(5, 1, "Capture Conversate Session")
    result = capture_cycle(
        "conversate_session",
        [
            "Connect glasses",
            "Open Conversate in Even app",
            "Speak several sentences, wait for transcription",
            "Wait for key points to generate",
            "Stop the session",
        ],
        progress,
        context="Conversate",
    )

    if result and result["g2_packets"]:
        step(5, 2, "Decode Conversate Messages")

        # Filter to Conversate service
        conversate_pkts = [p for p in result["g2_packets"]
                          if p["svc_hi"] == 0x0B]
        if conversate_pkts:
            print(f"\n  Found {len(conversate_pkts)} Conversate packets:")
            for p in conversate_pkts:
                print(f"\n    #{p['pkt_num']:>5}  {p['direction']}  {len(p['payload'])}B")
                fields = decode_protobuf_raw(p["payload"])
                if fields:
                    print(format_protobuf(fields, indent=3))
        else:
            print(f"\n  {C.YELLOW}No packets with known Conversate service ID found.{C.RESET}")
            print(f"  Check new service IDs — Conversate might use a different ID than expected.")

    wait_for_user()
    mark_phase_done(progress, 5)


def phase_6_translate_transcribe(progress: dict):
    """Phase 5: Translate & Transcribe"""
    banner("PHASE 6: Translate & Transcribe (30 min)")

    step(6, 1, "Capture Translate Session")
    if ask_yes_no("Capture Translate?"):
        capture_cycle(
            "translate_session",
            [
                "Open Translate feature, set language pair (e.g., English → French)",
                "Speak several sentences",
                "Wait for translations",
                "Stop",
            ],
            progress,
            context="Translate",
        )

    step(6, 2, "Capture Transcribe Session")
    if ask_yes_no("Capture Transcribe?"):
        capture_cycle(
            "transcribe_session",
            [
                "Open Transcribe feature",
                "Speak several sentences",
                "Wait for transcription",
                "Stop",
            ],
            progress,
            context="Transcribe",
        )

    wait_for_user()
    mark_phase_done(progress, 6)


def _analyze_display_packets(result: dict):
    """Deep analysis of display-related packets: handle channels, BMP headers, page lifecycle."""
    if not result or not result.get("g2_packets"):
        return

    att_packets_raw = result.get("_att_packets", [])
    g2_packets = result["g2_packets"]
    handle_map = result.get("handle_map", {})

    # --- 1. Classify ATT handles by observed traffic patterns ---
    # NOTE: ATT handles are opaque server-assigned integers (e.g. 0x0015),
    # NOT the UUID suffixes (0x5401, 0x6401). We classify by what data each
    # handle actually carries: G2 protocol (0xAA magic) vs other (ring, GATT, etc.)
    print(f"\n  {C.BOLD}Channel Analysis:{C.RESET}")
    print(f"  UUID suffixes: 5401/5402 (main), 6401/6402 (display), 7401/7402 (third)")
    print(f"  Use nRF Connect or GATT discovery to map handles → UUIDs\n")

    g2_handles = {p.get("att_handle") for p in g2_packets if p.get("att_handle")}
    all_att_handles = {a["att_handle"] for a in att_packets_raw}
    non_g2_handles = all_att_handles - g2_handles

    for handle, direction in sorted(handle_map.items()):
        label = "G2 protocol" if handle in g2_handles else "non-G2 (ring/other)"
        print(f"    0x{handle:04X} → {direction:<4} [{label}]")
    for h in sorted(non_g2_handles - set(handle_map.keys())):
        print(f"    0x{h:04X} → ??   [non-G2, direction unknown]")

    # --- 2. Scan ALL ATT packets (not just G2-parsed ones) for BMP headers ---
    print(f"\n  {C.BOLD}Scanning for BMP image data (0x42 0x4D = 'BM')...{C.RESET}")
    bmp_count = 0
    for att in att_packets_raw:
        val = att["value"]
        if len(val) >= 2:
            # Check for BMP header anywhere in the value
            bmp_pos = val.find(b"\x42\x4D")
            if bmp_pos >= 0:
                bmp_count += 1
                handle = att["att_handle"]
                size = len(val)
                # Parse BMP header if possible (14-byte file header)
                bmp_info = ""
                if bmp_pos + 14 <= len(val):
                    bmp_data = val[bmp_pos:]
                    bmp_file_size = struct.unpack("<I", bmp_data[2:6])[0]
                    bmp_offset = struct.unpack("<I", bmp_data[10:14])[0]
                    bmp_info = f" file_size={bmp_file_size}, pixel_offset={bmp_offset}"
                    if bmp_pos + 18 <= len(val):
                        bmp_w = struct.unpack("<i", bmp_data[18:22])[0] if bmp_pos + 22 <= len(val) else "?"
                        bmp_h = struct.unpack("<i", bmp_data[22:26])[0] if bmp_pos + 26 <= len(val) else "?"
                        bmp_info += f", {bmp_w}x{bmp_h}px"
                print(f"    {C.GREEN}BMP found!{C.RESET} pkt #{att['pkt_num']:>5}  handle=0x{handle:04X}  {size}B  offset={bmp_pos}{bmp_info}")
                if bmp_count <= 3:
                    print(f"      First 40B: {val[:40].hex()}")

    if bmp_count == 0:
        print(f"    {C.DIM}No BMP headers found in raw ATT data.{C.RESET}")
        print(f"    {C.DIM}Images may be sent as raw pixel data without BMP headers,{C.RESET}")
        print(f"    {C.DIM}or may need L2CAP reassembly for large transfers.{C.RESET}")
    else:
        print(f"\n    {C.GREEN}Total BMP images found: {bmp_count}{C.RESET}")

    # --- 3. Look for page lifecycle commands in G2 protobuf packets ---
    print(f"\n  {C.BOLD}Page Lifecycle Analysis:{C.RESET}")
    print(f"  Looking for create/rebuild/shutdown page commands...")
    print(f"  Expected flow: CREATE_PAGE → UPDATE_IMAGE/TEXT → REBUILD_PAGE → SHUTDOWN_PAGE\n")

    # Group packets by service and look for display-related services
    display_services = {}
    for p in g2_packets:
        sid = p["service_id"]
        if sid not in display_services:
            display_services[sid] = []
        display_services[sid].append(p)

    for sid, pkts in sorted(display_services.items()):
        # Decode first packet of each service to see structure
        sample = pkts[0]
        fields = decode_protobuf_raw(sample["payload"]) if sample["payload"] else []
        if fields:
            # Check field 1 for command type
            type_field = next((f for f in fields if f["field"] == 1 and f["wire_type"] == WIRE_VARINT), None)
            if type_field:
                cmd_type = type_field["value"]
                print(f"    {sid} ({sample['service_name']:<16})  {len(pkts):>4} pkts  cmd_type={cmd_type}")

    # --- 4. Look for large payloads (likely image data) ---
    print(f"\n  {C.BOLD}Large Payload Analysis (likely image/display data):{C.RESET}")
    large_pkts = sorted([p for p in g2_packets if len(p.get("payload", b"")) > 100],
                        key=lambda p: len(p["payload"]), reverse=True)
    if large_pkts:
        for p in large_pkts[:10]:
            payload = p["payload"]
            print(f"    #{p['pkt_num']:>5}  {p['direction']:<16}  {p['service_id']}  {len(payload):>4}B"
                  f"  multi={p['pkt_total']}/{p['pkt_serial']}")
    else:
        print(f"    {C.DIM}No large G2 payloads found.{C.RESET}")
        print(f"    {C.DIM}Image data likely flows on display channel (6401) outside G2 framing.{C.RESET}")

    # --- 5. Multi-packet sequences (image transfers are multi-fragment) ---
    multi_pkts = [p for p in g2_packets if p["pkt_total"] > 1]
    if multi_pkts:
        print(f"\n  {C.BOLD}Multi-Fragment Transfers:{C.RESET}")
        # Group by sequence
        sequences = {}
        for p in multi_pkts:
            key = (p["service_id"], p["seq"])
            if key not in sequences:
                sequences[key] = []
            sequences[key].append(p)
        for (sid, seq), frags in sequences.items():
            total_bytes = sum(len(f["payload"]) for f in frags)
            print(f"    {sid} seq={seq}: {len(frags)}/{frags[0]['pkt_total']} fragments, {total_bytes}B total")


def phase_7_display(progress: dict):
    """Phase 6: Display & Images"""
    banner("PHASE 7: Display & Images (1 hour)")
    print(f"""
  Goal: Decode text rendering, bitmap transfer, and page lifecycle.

  {C.BOLD}Display architecture (from decompiled code):{C.RESET}
    - Text display: protobuf via main channel (5401/5402)
    - Bitmap/raw images: display channel (6401/6402)
    - Page lifecycle: CREATE → UPDATE_IMAGE/TEXT → REBUILD → SHUTDOWN

  {C.BOLD}Known display packet types:{C.RESET}
    - APP_REQUEST_CREATE_STARTUP_PAGE_PACKET
    - APP_UPDATE_IMAGE_RAW_DATA_PACKET
    - APP_UPDATE_TEXT_DATA_PACKET
    - APP_REQUEST_REBUILD_PAGE_PACKET
    - APP_REQUEST_SHUTDOWN_PAGE_PACKET
    """)

    # Step 6.1 — Teleprompter (text display, known proto format = good baseline)
    step(7, 1, "Capture Teleprompter (Text Display Baseline)")
    if ask_yes_no("Capture Teleprompter? (best text display test)"):
        result = capture_cycle(
            "display_teleprompter",
            [
                "Connect glasses",
                "Open Teleprompter in Even app",
                "Create a short script with 3-4 paragraphs if none exists",
                "Send the script to glasses",
                "Wait for text to render on display",
                "Scroll through the text (swipe touchpad)",
                "Wait 10 seconds",
            ],
            progress,
            context="Teleprompter",
        )
        if result:
            # Filter teleprompter packets
            tp_pkts = [p for p in result["g2_packets"] if p["svc_hi"] == 0x06]
            if tp_pkts:
                print(f"\n  {C.GREEN}Found {len(tp_pkts)} Teleprompter packets — good text baseline!{C.RESET}")
                for p in tp_pkts:
                    fields = decode_protobuf_raw(p["payload"]) if p["payload"] else []
                    _find_text_fields(fields, p["service_id"])

    # Step 6.2 — Notification display (text + possibly icons)
    step(7, 2, "Capture Notification Display")
    if ask_yes_no("Capture Notifications? (need to trigger a phone notification)"):
        result = capture_cycle(
            "display_notification",
            [
                "Connect glasses",
                "Make sure notification forwarding is enabled in Even app",
                "Send yourself a test message (SMS, WhatsApp, or email)",
                "Wait for the notification to appear on glasses",
                "Send 2-3 more notifications from different apps",
                "Wait 15 seconds",
            ],
            progress,
            context="Notification",
        )
        if result:
            _analyze_display_packets(result)

    # Step 6.3 — Dashboard (widgets with icons/graphics)
    step(7, 3, "Capture Dashboard (Widgets + Graphics)")
    if ask_yes_no("Capture Dashboard?"):
        result = capture_cycle(
            "display_dashboard",
            [
                "Connect glasses",
                "Tilt head UP sharply to trigger dashboard",
                "Wait for all widgets to render (weather, calendar, etc.)",
                "Tilt head DOWN to dismiss",
                "Tilt UP again to trigger a second time",
                "Wait 10 seconds",
            ],
            progress,
            context="Dashboard",
        )
        if result:
            _analyze_display_packets(result)

    # Step 6.4 — Navigation (map tiles = bitmap transfer)
    step(7, 4, "Capture Navigation Maps (Bitmap Transfer)")
    if ask_yes_no("Capture Navigation? (need Google Maps directions active)"):
        result = capture_cycle(
            "display_navigation",
            [
                "Start a navigation route in Google Maps on your phone",
                "Even app should bridge navigation to glasses",
                "Wait for the map/arrow to appear on glasses",
                "Follow at least 2-3 turns so the map updates",
                "Watch for mini-map and overview updates",
                "Wait 15 seconds after the last update",
            ],
            progress,
            context="Navigation",
        )
        if result:
            print(f"\n  {C.BOLD}Navigation uses mini-map and overview-map bitmap transfers.{C.RESET}")
            print(f"  These should be the largest payloads on the display channel.\n")
            _analyze_display_packets(result)

    # Step 6.5 — Even AI response display (text rendering after AI reply)
    step(7, 5, "Capture AI Response Display")
    if ask_yes_no("Capture Even AI display? (shows text on glasses)"):
        result = capture_cycle(
            "display_ai_response",
            [
                "Connect glasses",
                "Say 'Hey Even'",
                "Ask a question that produces a LONG text response",
                "  e.g., 'Tell me about the Eiffel Tower'",
                "Wait for the full response to render on glasses",
                "Wait 15 seconds",
            ],
            progress,
            context="Even AI Display",
        )
        if result:
            print(f"\n  {C.BOLD}AI responses use text rendering — look for the display service.{C.RESET}")
            _analyze_display_packets(result)
            # Search for text in all packets
            for p in result["g2_packets"]:
                if p["payload"]:
                    fields = decode_protobuf_raw(p["payload"])
                    _find_text_fields(fields, p["service_id"])

    # Step 6.6 — Summary of display channels
    step(7, 6, "Display Channel Summary")
    print(f"""
  {C.BOLD}What to look for in the results above:{C.RESET}

  1. {C.CYAN}Text rendering:{C.RESET}
     - Teleprompter: field 3 = page content (UTF-8 with \\n separators)
     - AI response: look for similar text fields on the AI service ID
     - Conversate: field 7.1 = transcribed text

  2. {C.CYAN}Bitmap transfer:{C.RESET}
     - BMP header (42 4D) on display channel (6401)
     - Large multi-fragment transfers (pkt_total > 1)
     - Raw pixel data without headers (1-bit monochrome, 480x136px)

  3. {C.CYAN}Page lifecycle:{C.RESET}
     - CREATE → content flows → REBUILD → eventually SHUTDOWN
     - Each display feature creates its own page
    """)

    wait_for_user()
    mark_phase_done(progress, 7)


def phase_8_gestures(progress: dict):
    """Phase 7: Gestures & EvenHub"""
    banner("PHASE 8: Gestures, Ring Input & EvenHub (45 min)")
    print(f"""
  Goal: Decode all input events: head tilt, touchpad, and ring gestures.

  {C.BOLD}Input sources:{C.RESET}
    - Glasses IMU: head tilt up/down (triggers dashboard, etc.)
    - Glasses touchpads: tap, double tap, long press (both temples)
    - R1 Ring: tap, double tap, swipe/scroll (ring surface)

  {C.BOLD}Event flow:{C.RESET}
    Ring → Phone (BAE80001) → Phone bridges → Glasses (_createRingDataPackage)
    Glasses → Phone (EvenHub 0x81-0x20) for head tilt / touchpad events
    """)

    step(8, 1, "Capture Head Tilt Events")
    if ask_yes_no("Capture head tilts?"):
        capture_cycle(
            "head_tilts",
            [
                "Connect glasses",
                "Tilt head UP sharply (trigger dashboard)",
                "Wait 5 seconds",
                "Tilt head DOWN",
                "Wait 5 seconds",
                "Nod head (up-down quickly)",
                "Repeat 3 times with varying angles",
            ],
            progress,
            context="EvenHub/Gestures",
        )

    step(8, 2, "Capture Touchpad Gestures (Glasses)")
    print(f"  {C.DIM}The G2 has capacitive touchpads on both temple arms.{C.RESET}")
    print(f"  {C.DIM}No swipe — only tap, double tap, long press.{C.RESET}\n")
    if ask_yes_no("Capture touchpad gestures?"):
        capture_cycle(
            "touch_gestures",
            [
                "Single tap RIGHT touchpad, wait 5s",
                "Double tap RIGHT touchpad, wait 5s",
                "Long press RIGHT touchpad (~2 seconds), wait 5s",
                "Single tap LEFT touchpad, wait 5s",
                "Double tap LEFT touchpad, wait 5s",
                "Long press BOTH touchpads simultaneously (silent mode toggle)",
                "Wait 10 seconds",
            ],
            progress,
            context="EvenHub/Touch",
        )

    step(8, 3, "Capture Ring Click & Scroll (R1 Ring → Glasses)")
    print(f"  {C.DIM}Ring gestures are detected by the ring, sent to phone,{C.RESET}")
    print(f"  {C.DIM}then bridged to glasses via _createRingDataPackage.{C.RESET}\n")
    if ask_yes_no("Capture ring input? (need R1 ring connected)"):
        result = capture_cycle(
            "ring_input_gestures",
            [
                "Make sure R1 ring AND glasses are both connected",
                "Open a scrollable view on glasses (e.g., Teleprompter or Quick List)",
                "Single tap ring, wait 5s",
                "Double tap ring, wait 5s",
                "Swipe FORWARD on ring surface (scroll down), wait 5s",
                "Swipe BACKWARD on ring surface (scroll up), wait 5s",
                "Do 3 more scroll swipes in one direction",
                "Wait 10 seconds",
            ],
            progress,
            context="Ring Input",
        )
        if result and result["g2_packets"]:
            # Look for Ring service packets bridged to glasses
            print(f"\n  {C.BOLD}Ring Event Analysis:{C.RESET}")
            print(f"  Looking for Ring service packets and EvenHub events...\n")
            for p in result["g2_packets"]:
                sid = p["service_id"]
                # Show all non-baseline packets (filter out auth/sync noise)
                if p["svc_hi"] not in (0x80,):  # Skip auth/sync heartbeats
                    fields = decode_protobuf_raw(p["payload"]) if p["payload"] else []
                    print(f"    #{p['pkt_num']:>5}  {p['direction']:<16}  {sid} ({p['service_name']:<16})  {len(p['payload']):>3}B")
                    if fields:
                        print(format_protobuf(fields, indent=3))

    wait_for_user()
    mark_phase_done(progress, 8)


def phase_9_ring(progress: dict):
    """Phase 8: R1 Ring Binary Protocol"""
    banner("PHASE 9: R1 Ring Protocol (1-2 hours)")
    print(f"  Goal: Reverse engineer the ring's custom binary protocol.")
    print(f"  Note: Ring uses BAE80001 service, NOT G2 protobuf transport.\n")

    step(9, 1, "Capture Ring Connection")
    if ask_yes_no("Capture Ring? (need R1 ring)"):
        capture_cycle(
            "ring_connection",
            [
                "Turn on ring (put on finger)",
                "Open Even app, let it connect to ring",
                "Wait for initial handshake to complete",
            ],
            progress,
            context="Ring",
        )

    step(9, 2, "Capture Ring Gestures")
    if ask_yes_no("Capture Ring gestures?"):
        capture_cycle(
            "ring_gestures",
            [
                "Ensure ring is connected",
                "Single tap ring, wait 5s",
                "Double tap ring, wait 5s",
                "Swipe on ring surface (if supported), wait 5s",
            ],
            progress,
            context="Ring Gestures",
        )

    step(9, 3, "Capture Health Data")
    if ask_yes_no("Capture Health data sync?"):
        capture_cycle(
            "ring_health",
            [
                "Open Health tab in Even app",
                "Wait for daily data to sync",
                "Wait 30 seconds for real-time data",
            ],
            progress,
            context="Health",
        )

    step(9, 4, "Capture Ring Battery & Charging")
    if ask_yes_no("Capture Ring battery/charging status?"):
        capture_cycle(
            "ring_battery_idle",
            [
                "Ensure ring is connected and on your finger",
                "Open Even app — look for any battery indicator",
                "Wait 15 seconds for status packets",
            ],
            progress,
            context="Ring Battery",
        )
        if ask_yes_no("Capture ring charging state change? (need ring charger)"):
            capture_cycle(
                "ring_charging",
                [
                    "Start capture with ring connected and on finger",
                    "Place ring on its charger",
                    "Wait 15 seconds",
                    "Remove ring from charger",
                    "Wait 15 seconds",
                ],
                progress,
                context="Ring Charging",
            )

    wait_for_user()
    mark_phase_done(progress, 9)


def phase_10_minor(progress: dict):
    """Phase 9: Settings & Minor Services"""
    banner("PHASE 10: Settings & Minor Services (30 min)")

    step(10, 1, "Capture Settings Changes")
    if ask_yes_no("Capture Settings?"):
        capture_cycle(
            "settings_changes",
            [
                "Open Even app settings",
                "Change display brightness",
                "Change head-up angle",
                "Change gesture mappings",
            ],
            progress,
            context="G2 Settings",
        )

    step(10, 2, "Capture Glasses Battery & Charging")
    if ask_yes_no("Capture glasses battery/charging status?"):
        capture_cycle(
            "glasses_battery_idle",
            [
                "Ensure glasses are connected and worn",
                "Open Even app — note any battery level shown",
                "Wait 15 seconds for status packets",
            ],
            progress,
            context="Glasses Battery",
        )
        if ask_yes_no("Capture glasses charging state change? (need charging case)"):
            capture_cycle(
                "glasses_charging",
                [
                    "Start with glasses connected and worn",
                    "Place glasses in the charging case",
                    "Wait 15 seconds (glasses may disconnect)",
                    "Remove glasses from case",
                    "Wait for reconnection",
                    "Wait 15 seconds",
                ],
                progress,
                context="Glasses Charging",
            )

    step(10, 3, "Capture Quick List")
    if ask_yes_no("Capture Quick List?"):
        capture_cycle(
            "quick_list",
            [
                "Create a quick list with 3 items",
                "Send it to glasses",
            ],
            progress,
            context="Quick List",
        )

    wait_for_user()
    mark_phase_done(progress, 10)


def phase_11_validation(progress: dict):
    """Phase 10: Validation & Summary"""
    banner("PHASE 11: Validation & Summary")

    print_service_table(progress)

    # Export results
    step(11, 1, "Export Results")
    results_file = RESULTS_DIR / "service_map.json"
    export = {
        "generated": datetime.now().isoformat(),
        "known_services": {f"0x{h:02X}-0x{l:02X}": n for (h, l), n in KNOWN_SERVICES.items()},
        "discovered_services": progress.get("discovered_services", {}),
        "captures": progress.get("captures", []),
    }
    results_file.write_text(json.dumps(export, indent=2))
    print(f"  {C.GREEN}Results exported to: {results_file}{C.RESET}")

    # Validation summary
    step(11, 2, "Capture Validation Summary")
    print_validation_summary(progress)

    # File listing
    step(11, 3, "Capture Files")
    for cap in progress.get("captures", []):
        v = cap.get("validation", {})
        status = f"{C.GREEN}✓{C.RESET}" if v.get("passed") else f"{C.RED}✗{C.RESET}" if v else " "
        print(f"  {status} {cap['label']:<30} {cap['file']}")

    print(f"\n{C.BOLD}{C.GREEN}All phases complete!{C.RESET}")
    print(f"  Next steps:")
    print(f"    1. Review decoded packets in {RESULTS_DIR}/")
    print(f"    2. Update proto files in even_decompiled/findings/proto/")
    print(f"    3. Build validation tool (see even-g2-protocol/examples/)")


# =============================================================================
# Standalone Analysis Mode
# =============================================================================

def standalone_analyze(filepath: str):
    """Analyze a btsnoop file without the guided workflow."""
    if not os.path.exists(filepath):
        print(f"{C.RED}File not found: {filepath}{C.RESET}")
        return

    result = analyze_capture(filepath, verbose=True)

    # Save analysis
    basename = os.path.splitext(os.path.basename(filepath))[0]
    out_file = RESULTS_DIR / f"analysis_{basename}.json"

    export_packets = []
    for g2 in result["g2_packets"]:
        fields = decode_protobuf_raw(g2["payload"]) if g2["payload"] else []
        export_packets.append({
            "pkt_num": g2["pkt_num"],
            "direction": g2["direction"],
            "service_id": g2["service_id"],
            "service_name": g2["service_name"],
            "seq": g2["seq"],
            "payload_hex": g2["payload"].hex() if g2["payload"] else "",
            "payload_size": len(g2["payload"]) if g2["payload"] else 0,
            "protobuf_fields": fields,
            "crc_ok": g2["crc_ok"],
        })

    export = {
        "file": filepath,
        "analyzed": datetime.now().isoformat(),
        "summary": {
            "total_att_packets": result["total_att_packets"],
            "g2_packets": len(result["g2_packets"]),
            "service_ids": {k: {"name": v["name"], "count": v["count"]}
                          for k, v in result["service_ids"].items()},
        },
        "packets": export_packets,
    }

    out_file.write_text(json.dumps(export, indent=2, default=str))
    print(f"\n  {C.GREEN}Analysis saved to: {out_file}{C.RESET}")


# =============================================================================
# Main
# =============================================================================

PHASES = {
    0: ("Prerequisites & Setup", phase_0_setup),
    1: ("Pairing & Authentication", phase_1_pairing),
    2: ("Service ID Discovery", phase_2_service_discovery),
    3: ("Even AI Protocol", phase_3_even_ai),
    4: ("Audio Protocol", phase_4_audio),
    5: ("Conversate Protocol", phase_5_conversate),
    6: ("Translate & Transcribe", phase_6_translate_transcribe),
    7: ("Display & Images", phase_7_display),
    8: ("Gestures, Ring Input & EvenHub", phase_8_gestures),
    9: ("R1 Ring Protocol", phase_9_ring),
    10: ("Minor Services", phase_10_minor),
    11: ("Validation & Summary", phase_11_validation),
}


def main():
    parser = argparse.ArgumentParser(description="Even G2 BLE Capture Assistant")
    parser.add_argument("--phase", type=int, help="Start from a specific phase (0-11)")
    parser.add_argument("--analyze", type=str, help="Analyze a btsnoop_hci.log file")
    parser.add_argument("--status", action="store_true", help="Show current discovery progress")
    parser.add_argument("--reset", action="store_true", help="Reset all progress")
    args = parser.parse_args()

    # Standalone analyze mode
    if args.analyze:
        standalone_analyze(args.analyze)
        return

    # Load progress
    progress = load_progress()

    # Status mode
    if args.status:
        print_service_table(progress)
        print(f"  Completed phases: {', '.join(progress.get('completed_phases', [])) or 'none'}")
        print(f"  Total captures: {len(progress.get('captures', []))}")
        return

    # Reset
    if args.reset:
        if ask_yes_no("Reset all progress? This cannot be undone"):
            PROGRESS_FILE.unlink(missing_ok=True)
            print(f"  {C.GREEN}Progress reset.{C.RESET}")
        return

    # Interactive guided mode
    banner("EVEN G2 BLE CAPTURE ASSISTANT")
    print(f"""
  This tool guides you step-by-step through capturing and decoding
  BLE traffic from your Even G2 glasses (and R1 ring).

  {C.BOLD}What it automates:{C.RESET}
    - ADB snoop log management (enable, pull, restart BT)
    - btsnoop_hci.log parsing (no Wireshark needed)
    - G2 transport header extraction (0xAA magic)
    - Raw protobuf decoding (no .proto files needed)
    - Service ID tracking and progress saving

  {C.BOLD}What you do manually:{C.RESET}
    - Physical actions (say 'Hey Even', tap touchpad, etc.)
    - Confirm each step before proceeding

  {C.BOLD}Estimated total time: ~8-10 hours (all phases){C.RESET}
  {C.BOLD}Minimum viable (AI only): Phases 0-5 = ~3-4 hours{C.RESET}

  Progress is saved automatically between sessions.
    """)

    # Determine starting phase
    start_phase = args.phase if args.phase is not None else 0

    if start_phase == 0 and progress.get("completed_phases"):
        print(f"  {C.CYAN}Previous progress found!{C.RESET}")
        print(f"  Completed: {', '.join(progress['completed_phases'])}")
        print(f"  Captures: {len(progress.get('captures', []))}")
        print()

        # Find next uncompleted phase
        for i in range(12):
            if f"phase_{i}" not in progress["completed_phases"]:
                start_phase = i
                break

        if ask_yes_no(f"Resume from Phase {start_phase}?"):
            pass
        else:
            try:
                start_phase = int(input("  Enter phase number to start from (0-11): ").strip())
            except (ValueError, EOFError):
                start_phase = 0

    # Run phases
    for phase_num in range(start_phase, 12):
        name, func = PHASES[phase_num]
        print(f"\n  {C.BOLD}Phase {phase_num}: {name}{C.RESET}")

        if f"phase_{phase_num}" in progress.get("completed_phases", []):
            if not ask_yes_no(f"Phase {phase_num} already completed. Re-run?"):
                continue

        func(progress)

        if phase_num < 11:
            if not ask_yes_no(f"\nContinue to Phase {phase_num + 1}?"):
                print(f"\n  {C.GREEN}Progress saved. Run again to continue.{C.RESET}")
                break

    print(f"\n{C.BOLD}Session complete. Run with --status to see progress.{C.RESET}\n")


if __name__ == "__main__":
    import io
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8', errors='replace')
    try:
        main()
    except KeyboardInterrupt:
        print(f"\n\n  {C.YELLOW}Interrupted. Progress has been saved.{C.RESET}\n")
    except EOFError:
        print(f"\n\n  {C.YELLOW}Input ended. Progress has been saved.{C.RESET}\n")
