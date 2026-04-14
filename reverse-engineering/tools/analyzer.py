"""
BLE Capture Analyzer
====================
Pure-Python btsnoop parser, transport header decoder, and raw protobuf decoder.
Device-agnostic: works with any BLE device. Known service labels can be loaded
from an external config or progress.json at runtime.

Extracted from capture_assistant.py for reuse as a library.
No print statements — all functions return structured data.
"""

import mmap
import os
import struct
import subprocess
from pathlib import Path

# =============================================================================
# btsnoop constants
# =============================================================================

BTSNOOP_MAGIC = b"btsnoop\x00"

HCI_CMD = 0x01
HCI_ACL = 0x02
HCI_SCO = 0x03
HCI_EVT = 0x04

ATT_WRITE_CMD = 0x52
ATT_WRITE_REQ = 0x12
ATT_HANDLE_NOTIFY = 0x1B
ATT_HANDLE_IND = 0x1D

L2CAP_ATT_CID = 0x0004

# Transport header magic byte (0xAA)
TRANSPORT_MAGIC = 0xAA

# Protobuf wire types
WIRE_VARINT = 0
WIRE_64BIT = 1
WIRE_LENGTH_DELIMITED = 2
WIRE_32BIT = 5
WIRE_TYPE_NAMES = {0: "varint", 1: "64-bit", 2: "bytes", 5: "32-bit"}


# =============================================================================
# CRC
# =============================================================================

def crc16_ccitt(data: bytes, init: int = 0xFFFF) -> int:
    crc = init
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else (crc << 1)
            crc &= 0xFFFF
    return crc


# =============================================================================
# L2CAP Reassembler
# =============================================================================

class L2CAPReassembler:
    """Reassembles fragmented L2CAP PDUs from HCI ACL packets."""

    def __init__(self):
        self._buffers = {}

    def process_acl(self, hci_data: bytes, is_sent: bool, timestamp: int, pkt_num: int) -> dict | None:
        if len(hci_data) < 4:
            return None

        handle_flags = struct.unpack("<H", hci_data[0:2])[0]
        acl_handle = handle_flags & 0x0FFF
        pb_flag = (handle_flags >> 12) & 0x03
        acl_len = struct.unpack("<H", hci_data[2:4])[0]
        acl_payload = hci_data[4:4 + acl_len]

        if pb_flag in (0x00, 0x02):
            if len(acl_payload) < 4:
                return None
            l2cap_len = struct.unpack("<H", acl_payload[0:2])[0]
            l2cap_cid = struct.unpack("<H", acl_payload[2:4])[0]
            l2cap_data = acl_payload[4:]

            if l2cap_cid != L2CAP_ATT_CID:
                self._buffers.pop(acl_handle, None)
                return None

            if len(l2cap_data) >= l2cap_len:
                self._buffers.pop(acl_handle, None)
                return _extract_att(l2cap_data[:l2cap_len], is_sent, timestamp, pkt_num)
            else:
                self._buffers[acl_handle] = {
                    "expected_len": l2cap_len,
                    "data": bytearray(l2cap_data),
                    "is_sent": is_sent,
                    "timestamp": timestamp,
                    "pkt_num": pkt_num,
                }
                return None

        elif pb_flag == 0x01:
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
# btsnoop Parser
# =============================================================================

def parse_btsnoop(filepath: str) -> dict:
    """Parse a btsnoop_hci.log file and return ATT packets.

    Returns dict with:
        packets: list of ATT packet dicts
        warnings: list of warning strings
        info: dict with version, datalink, etc.
    """
    packets = []
    warnings = []
    info = {}

    with open(filepath, "rb") as f:
        magic = f.read(8)
        if magic != BTSNOOP_MAGIC:
            warnings.append("Not a btsnoop file - trying raw scan")
            raw_result = raw_scan_for_transport_packets(filepath)
            raw_result["warnings"] = warnings + raw_result.get("warnings", [])
            return raw_result

        version = struct.unpack(">I", f.read(4))[0]
        datalink = struct.unpack(">I", f.read(4))[0]
        info["version"] = version
        info["datalink"] = datalink

        use_h4 = datalink == 1002

        reassembler = L2CAPReassembler()
        pkt_num = 0
        truncated_records = 0

        while True:
            rec_hdr = f.read(24)
            if len(rec_hdr) < 24:
                break

            orig_len, incl_len, flags, drops, ts_us = struct.unpack(">IIIIq", rec_hdr)

            if incl_len > 65536 or incl_len == 0:
                warnings.append(f"Bad btsnoop record at packet {pkt_num + 1} (incl_len={incl_len}) - stopping structured parse")
                break

            data = f.read(incl_len)
            if len(data) < incl_len:
                break

            if orig_len > incl_len:
                truncated_records += 1

            pkt_num += 1

            if use_h4:
                if len(data) < 1:
                    continue
                pkt_type = data[0]
                hci_data = data[1:]
            elif datalink == 1001:
                if (flags >> 1) & 1:
                    continue
                pkt_type = HCI_ACL
                hci_data = data
            else:
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
        warnings.append(f"{truncated_records} btsnoop records were truncated (orig_len > incl_len)")

    if not packets:
        warnings.append("btsnoop parsing found 0 ATT packets - trying raw scan")
        raw_result = raw_scan_for_transport_packets(filepath)
        raw_result["warnings"] = warnings + raw_result.get("warnings", [])
        raw_result["info"] = info
        return raw_result

    return {"packets": packets, "warnings": warnings, "info": info}


def raw_scan_for_transport_packets(filepath: str) -> dict:
    """Fallback: scan binary file for 0xAA transport header packets with CRC verification."""
    packets = []
    warnings = []

    file_size = os.path.getsize(filepath)
    if file_size == 0:
        return {"packets": [], "warnings": ["Empty file"], "info": {}}

    pkt_num = 0
    magic_byte = bytes([TRANSPORT_MAGIC])

    with open(filepath, "rb") as f, \
         mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as data:

        pos = 0
        data_len = len(data)
        while pos < data_len - 9:
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

            total_pkt_len = 8 + payload_len
            if pos + total_pkt_len > data_len:
                break

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

    if not packets:
        packets = _try_tshark_parse(filepath)
        if not packets:
            warnings.append("No transport packets found via raw scan or tshark")

    return {"packets": packets, "warnings": warnings, "info": {"method": "raw_scan"}}


def _try_tshark_parse(filepath: str) -> list:
    """Try to extract ATT data using tshark if available."""
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
        return []

    packets = []
    try:
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
            return []

        pkt_num = 0
        for line in result.stdout.strip().split("\n"):
            if not line.strip():
                continue
            parts = line.split("|")
            if len(parts) < 5:
                continue
            try:
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
    except subprocess.TimeoutExpired:
        pass

    return packets


# =============================================================================
# Transport Header Parser
# =============================================================================

def parse_transport_packet(raw: bytes, known_services: dict | None = None) -> dict | None:
    """Parse a transport packet with 0xAA header.

    Args:
        raw: raw packet bytes
        known_services: optional dict mapping (svc_hi, svc_lo) -> name
    """
    if len(raw) < 10 or raw[0] != TRANSPORT_MAGIC:
        return None

    pkt_type = raw[1]
    seq = raw[2]
    payload_len = raw[3]
    pkt_total = raw[4]
    pkt_serial = raw[5]
    svc_hi = raw[6]
    svc_lo = raw[7]

    total_pkt_len = 8 + payload_len
    if payload_len < 2 or len(raw) < total_pkt_len:
        return None

    if pkt_total == 0 or pkt_serial == 0 or pkt_serial > pkt_total:
        return None

    payload = raw[8:total_pkt_len - 2]
    crc_bytes = raw[total_pkt_len - 2:total_pkt_len]
    crc = struct.unpack("<H", crc_bytes)[0]
    expected_crc = crc16_ccitt(payload)
    crc_ok = (crc == expected_crc)

    if pkt_type == 0x21:
        direction_str = "Phone->Device"
    elif pkt_type == 0x12:
        direction_str = "Device->Phone"
    else:
        direction_str = f"Unknown(0x{pkt_type:02X})"

    service_name = None
    if known_services:
        service_name = known_services.get((svc_hi, svc_lo))

    return {
        "magic": TRANSPORT_MAGIC,
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


def reassemble_fragments(packets: list) -> list:
    """Reassemble multi-fragment transport packets into complete messages."""
    single_packets = []
    fragment_groups = {}

    for p in packets:
        if p["pkt_total"] <= 1:
            single_packets.append(p)
        else:
            key = (p["service_id"], p["seq"], p["direction"])
            if key not in fragment_groups:
                fragment_groups[key] = []
            fragment_groups[key].append(p)

    reassembled = []
    for key, fragments in fragment_groups.items():
        fragments.sort(key=lambda p: p["pkt_serial"])

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

        combined_payload = b"".join(f["payload"] for f in fragments)
        reassembled_pkt = dict(fragments[0])
        reassembled_pkt["payload"] = combined_payload
        reassembled_pkt["pkt_total"] = 1
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

def decode_varint(data: bytes, pos: int) -> tuple:
    result = 0
    shift = 0
    while pos < len(data):
        b = data[pos]
        result |= (b & 0x7F) << shift
        pos += 1
        if not (b & 0x80):
            break
        shift += 7
        if shift >= 64:
            break
    return result, pos


def _is_valid_protobuf(data: bytes) -> bool:
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


def decode_protobuf_raw(data: bytes) -> list:
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
            break

        field = {
            "field": field_num,
            "wire_type": wire_type,
            "wire_type_name": WIRE_TYPE_NAMES.get(wire_type, "?"),
        }

        if wire_type == WIRE_VARINT:
            value, pos = decode_varint(data, pos)
            field["value"] = value
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

            try:
                text = raw.decode("utf-8")
                if all(c.isprintable() or c in "\n\r\t" for c in text):
                    field["as_string"] = text
            except (UnicodeDecodeError, ValueError):
                pass

            try:
                if _is_valid_protobuf(raw):
                    nested = decode_protobuf_raw(raw)
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
            break

        fields.append(field)

    return fields


# =============================================================================
# High-Level Analysis
# =============================================================================

def analyze_capture(filepath: str, known_services: dict | None = None) -> dict:
    """Analyze a btsnoop capture file and extract transport protocol packets.

    Args:
        filepath: path to btsnoop_hci.log
        known_services: optional dict mapping (svc_hi, svc_lo) -> name

    Returns dict with:
        filepath, total_att_packets, transport_packets, service_ids,
        handle_map, warnings, info, decoded_packets
    """
    parse_result = parse_btsnoop(filepath)
    att_packets = parse_result["packets"]
    warnings = parse_result.get("warnings", [])
    info = parse_result.get("info", {})

    transport_raw = []
    handle_map = {}

    for att in att_packets:
        val = att["value"]
        if len(val) >= 10 and val[0] == TRANSPORT_MAGIC:
            pkt = parse_transport_packet(val, known_services)
            if pkt:
                pkt["att_handle"] = att["att_handle"]
                pkt["att_direction"] = att["direction"]
                pkt["pkt_num"] = att["pkt_num"]
                pkt["timestamp"] = att["timestamp"]
                transport_raw.append(pkt)
                handle_map[att["att_handle"]] = att["direction"]

    transport_packets = reassemble_fragments(transport_raw)

    # Build service stats
    service_ids = {}
    for pkt in transport_packets:
        sid = pkt["service_id"]
        if sid not in service_ids:
            service_ids[sid] = {
                "name": pkt["service_name"],
                "count": 0,
                "first_pkt": pkt["pkt_num"],
                "directions": [],
            }
        service_ids[sid]["count"] += 1
        d = pkt["direction"]
        if d not in service_ids[sid]["directions"]:
            service_ids[sid]["directions"].append(d)

    # Decode protobuf for each packet
    decoded_packets = []
    for pkt in transport_packets:
        decoded = {
            "pkt_num": pkt["pkt_num"],
            "direction": pkt["direction"],
            "service_id": pkt["service_id"],
            "service_name": pkt["service_name"],
            "seq": pkt["seq"],
            "crc_ok": pkt["crc_ok"],
            "payload_hex": pkt["payload"].hex() if pkt["payload"] else "",
            "payload_len": len(pkt["payload"]) if pkt["payload"] else 0,
            "att_handle": pkt.get("att_handle", 0),
            "reassembly": pkt.get("_reassembly"),
            "fragment_count": pkt.get("_fragment_count"),
        }
        if pkt["payload"]:
            fields = decode_protobuf_raw(pkt["payload"])
            decoded["protobuf"] = _fields_to_serializable(fields)
        else:
            decoded["protobuf"] = []
        decoded_packets.append(decoded)

    reassembled_count = sum(1 for p in transport_packets if p.get("_reassembly") == "complete")
    crc_failures = sum(1 for p in transport_packets if not p.get("crc_ok", True))

    return {
        "filepath": filepath,
        "total_att_packets": len(att_packets),
        "total_transport_raw": len(transport_raw),
        "total_transport": len(transport_packets),
        "reassembled_count": reassembled_count,
        "crc_failures": crc_failures,
        "service_ids": service_ids,
        "handle_map": {f"0x{h:04X}": d for h, d in sorted(handle_map.items())},
        "decoded_packets": decoded_packets,
        "warnings": warnings,
        "info": info,
    }


def _fields_to_serializable(fields: list) -> list:
    """Convert decoded protobuf fields to JSON-serializable form."""
    result = []
    for f in fields:
        item = {
            "field": f["field"],
            "wire_type": f["wire_type"],
            "wire_type_name": f["wire_type_name"],
        }
        if f["wire_type"] == WIRE_VARINT:
            item["value"] = f["value"]
            item["signed"] = f["signed"]
        elif f["wire_type"] == WIRE_64BIT:
            item["value_hex"] = f["value_hex"]
            item["as_int64"] = f["as_int64"]
        elif f["wire_type"] == WIRE_LENGTH_DELIMITED:
            item["length"] = f["length"]
            item["raw_hex"] = f["raw_hex"]
            if "as_string" in f:
                item["as_string"] = f["as_string"]
            if "as_message" in f:
                item["as_message"] = _fields_to_serializable(f["as_message"])
        elif f["wire_type"] == WIRE_32BIT:
            item["value_hex"] = f["value_hex"]
            item["as_float"] = f["as_float"]
            item["as_int32"] = f["as_int32"]
        result.append(item)
    return result


def diff_captures(old_result: dict, new_result: dict) -> dict:
    """Compare two capture analysis results to find new packets/services.

    Returns dict with:
        new_service_ids: service IDs in new but not old
        removed_service_ids: service IDs in old but not new
        count_deltas: per-service packet count changes
    """
    old_sids = set(old_result.get("service_ids", {}).keys())
    new_sids = set(new_result.get("service_ids", {}).keys())

    new_service_ids = {}
    for sid in new_sids - old_sids:
        new_service_ids[sid] = new_result["service_ids"][sid]

    removed_service_ids = list(old_sids - new_sids)

    count_deltas = {}
    for sid in new_sids:
        new_count = new_result["service_ids"][sid]["count"]
        old_count = old_result["service_ids"].get(sid, {}).get("count", 0)
        delta = new_count - old_count
        if delta != 0:
            count_deltas[sid] = {
                "old": old_count,
                "new": new_count,
                "delta": delta,
                "name": new_result["service_ids"][sid]["name"],
            }

    return {
        "new_service_ids": new_service_ids,
        "removed_service_ids": removed_service_ids,
        "count_deltas": count_deltas,
    }


def load_known_services_from_progress(progress_path: str) -> dict:
    """Load known service labels from a progress.json file.

    Returns dict mapping (svc_hi, svc_lo) -> name, suitable for
    passing as known_services to parse/analyze functions.
    """
    import json
    try:
        with open(progress_path) as f:
            data = json.load(f)
        services = {}
        for key, name in data.get("discovered_services", {}).items():
            parts = key.split("-")
            if len(parts) == 2:
                try:
                    hi = int(parts[0], 16)
                    lo = int(parts[1], 16)
                    services[(hi, lo)] = name
                except ValueError:
                    pass
        return services
    except (FileNotFoundError, json.JSONDecodeError):
        return {}
