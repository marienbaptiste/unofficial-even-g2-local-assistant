"""
BLE Capture Web Server
======================
FastAPI backend for capturing and analyzing BLE traffic from Android phones via ADB.
Device-agnostic: works with any BLE device.

Usage:
    pip install fastapi uvicorn
    python capture_server.py
    # Open http://localhost:8642
"""

import json
import os
import shutil
import subprocess
import tempfile
import time
import zipfile
from datetime import datetime
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

import analyzer

# =============================================================================
# Configuration
# =============================================================================

BASE_DIR = Path(__file__).parent
CAPTURES_DIR = BASE_DIR / "captures"
RESULTS_DIR = BASE_DIR / "results"
PROGRESS_FILE = RESULTS_DIR / "progress.json"
STATIC_DIR = BASE_DIR / "static"

CAPTURES_DIR.mkdir(exist_ok=True)
RESULTS_DIR.mkdir(exist_ok=True)

app = FastAPI(title="BLE Capture Analyzer")

# Serve static files
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")

# In-memory state
_capture_state = {
    "active": False,
    "started_at": None,
    "description": "",
}


# =============================================================================
# Models
# =============================================================================

class CaptureStartRequest(BaseModel):
    description: str = ""


class AnalyzeRequest(BaseModel):
    capture_id: str
    context: str = ""


class SignalRequest(BaseModel):
    status: str  # "done", "retry", "notes"
    capture_id: str = ""
    notes: str = ""


# =============================================================================
# ADB Helpers
# =============================================================================

def _adb_run(args: list, timeout: int = 30) -> dict:
    """Run an ADB command and return result dict."""
    full_cmd = ["adb"] + args
    try:
        result = subprocess.run(full_cmd, capture_output=True, text=True, timeout=timeout)
        return {
            "returncode": result.returncode,
            "stdout": result.stdout.strip(),
            "stderr": result.stderr.strip(),
        }
    except FileNotFoundError:
        return {"returncode": -1, "stdout": "", "stderr": "ADB not found. Install Android SDK platform-tools."}
    except subprocess.TimeoutExpired:
        return {"returncode": -1, "stdout": "", "stderr": f"ADB command timed out after {timeout}s"}


def _get_adb_status() -> dict:
    """Check ADB connection and return device info."""
    result = _adb_run(["devices"])
    if result["returncode"] != 0:
        return {"connected": False, "error": result["stderr"]}

    lines = [
        l for l in result["stdout"].split("\n")[1:]
        if l.strip() and l.strip().endswith("\tdevice")
    ]

    if not lines:
        return {"connected": False, "error": "No authorized device found"}

    serial = lines[0].split("\t")[0]

    # Get phone model
    model_result = _adb_run(["shell", "getprop", "ro.product.model"])
    model = model_result["stdout"] if model_result["returncode"] == 0 else "Unknown"

    # Check BT status
    bt_result = _adb_run(["shell", "settings", "get", "global", "bluetooth_on"])
    bt_on = bt_result["stdout"].strip() == "1" if bt_result["returncode"] == 0 else None

    # Check snoop log mode
    snoop_result = _adb_run(["shell", "settings", "get", "secure", "bluetooth_hci_snoop_log_mode"])
    snoop_mode = snoop_result["stdout"].strip() if snoop_result["returncode"] == 0 else "unknown"

    return {
        "connected": True,
        "serial": serial,
        "model": model,
        "bluetooth_on": bt_on,
        "snoop_mode": snoop_mode,
        "device_count": len(lines),
    }


def _extract_btsnoop_from_bugreport(bugreport_zip: Path, dest_dir: Path) -> Optional[str]:
    """Extract btsnoop_hci.log from a bugreport zip file."""
    try:
        with zipfile.ZipFile(str(bugreport_zip), "r") as zf:
            for name in zf.namelist():
                if "btsnoop" in name.lower():
                    extracted = zf.extract(name, str(dest_dir))
                    return extracted
            # Some bugreports nest inside a directory
            for name in zf.namelist():
                if "bluetooth" in name.lower() and name.endswith(".log"):
                    extracted = zf.extract(name, str(dest_dir))
                    return extracted
    except (zipfile.BadZipFile, Exception):
        pass
    return None


# =============================================================================
# Progress helpers
# =============================================================================

def _load_progress() -> dict:
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
            for key, val in default.items():
                data.setdefault(key, val)
            return data
        except (json.JSONDecodeError, ValueError):
            pass
    return default


def _save_progress(progress: dict):
    PROGRESS_FILE.write_text(json.dumps(progress, indent=2))


def _get_known_services() -> dict:
    """Load known service labels from progress.json if it exists."""
    if PROGRESS_FILE.exists():
        return analyzer.load_known_services_from_progress(str(PROGRESS_FILE))
    return {}


# =============================================================================
# API Endpoints
# =============================================================================

@app.get("/")
async def serve_ui():
    index = STATIC_DIR / "index.html"
    if not index.exists():
        raise HTTPException(status_code=404, detail="UI not found. Place index.html in static/")
    return FileResponse(str(index))


@app.get("/api/status")
async def get_status():
    """Check ADB connection and phone info."""
    status = _get_adb_status()
    status["capture_active"] = _capture_state["active"]
    status["capture_started_at"] = _capture_state["started_at"]
    status["capture_description"] = _capture_state["description"]
    return status


@app.post("/api/capture/start")
async def start_capture(req: CaptureStartRequest):
    """Enable snoop logging and restart Bluetooth for a fresh capture."""
    status = _get_adb_status()
    if not status["connected"]:
        raise HTTPException(status_code=400, detail="No ADB device connected")

    errors = []

    # Enable HCI snoop log
    snoop_result = _adb_run(["shell", "settings", "put", "secure", "bluetooth_hci_snoop_log_mode", "full"])
    if snoop_result["returncode"] != 0:
        errors.append(f"Failed to enable snoop: {snoop_result['stderr']}")

    # Restart Bluetooth
    disable_result = _adb_run(["shell", "svc", "bluetooth", "disable"])
    if disable_result["returncode"] != 0:
        errors.append(f"Failed to disable BT: {disable_result['stderr']}")

    time.sleep(2)

    enable_result = _adb_run(["shell", "svc", "bluetooth", "enable"])
    if enable_result["returncode"] != 0:
        errors.append(f"Failed to enable BT: {enable_result['stderr']}")

    _capture_state["active"] = True
    _capture_state["started_at"] = datetime.now().isoformat()
    _capture_state["description"] = req.description

    # Clear any stale signal so Claude doesn't act on old "done"
    if SIGNAL_FILE.exists():
        SIGNAL_FILE.unlink()

    return {
        "status": "started",
        "description": req.description,
        "started_at": _capture_state["started_at"],
        "errors": errors,
        "message": "Bluetooth restarted. Wait for device to reconnect, then perform your actions.",
    }


@app.post("/api/capture/stop")
async def stop_capture():
    """Pull bugreport, extract btsnoop, and run analysis."""
    status = _get_adb_status()
    if not status["connected"]:
        raise HTTPException(status_code=400, detail="No ADB device connected")

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    description = _capture_state.get("description", "capture")
    label = description.replace(" ", "_")[:40] if description else "capture"

    _capture_state["active"] = False

    # Try direct pull first
    dest_filename = f"{label}_{timestamp}.log"
    dest = CAPTURES_DIR / dest_filename
    snoop_path = None

    direct_result = _adb_run(
        ["pull", "/data/misc/bluetooth/logs/btsnoop_hci.log", str(dest)],
        timeout=60,
    )
    if direct_result["returncode"] == 0 and dest.exists() and dest.stat().st_size > 16:
        snoop_path = str(dest)
    else:
        # Try bugreport method
        bugreport_zip = CAPTURES_DIR / f"bugreport_{timestamp}.zip"
        bug_result = _adb_run(["bugreport", str(bugreport_zip)], timeout=300)

        if bug_result["returncode"] == 0 and bugreport_zip.exists():
            extracted = _extract_btsnoop_from_bugreport(bugreport_zip, CAPTURES_DIR)
            if extracted:
                final = CAPTURES_DIR / dest_filename
                try:
                    shutil.move(extracted, str(final))
                    snoop_path = str(final)
                except Exception:
                    snoop_path = extracted

            # Clean up bugreport zip and extracted dirs
            try:
                bugreport_zip.unlink(missing_ok=True)
                # Clean up any extracted subdirectories
                for item in CAPTURES_DIR.iterdir():
                    if item.is_dir() and item.name.startswith("bugreport"):
                        shutil.rmtree(str(item), ignore_errors=True)
            except Exception:
                pass

    if not snoop_path:
        # Try alternative paths
        alt_paths = [
            "/sdcard/btsnoop_hci.log",
            "/data/log/bt/btsnoop_hci.log",
            "/data/misc/bluedroid/btsnoop_hci.log",
        ]
        for path in alt_paths:
            r = _adb_run(["pull", path, str(dest)], timeout=60)
            if r["returncode"] == 0 and dest.exists() and dest.stat().st_size > 16:
                snoop_path = str(dest)
                break

    if not snoop_path:
        raise HTTPException(
            status_code=500,
            detail="Could not pull btsnoop log. Check that HCI snoop logging is enabled in Developer Options.",
        )

    # Run analysis
    known_services = _get_known_services()
    try:
        result = analyzer.analyze_capture(snoop_path, known_services=known_services)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Analysis failed: {str(e)}")

    # Save result
    capture_id = f"{label}_{timestamp}"
    result_file = RESULTS_DIR / f"{capture_id}.json"

    # Make result JSON-serializable (remove bytes)
    serializable_result = {
        k: v for k, v in result.items()
        if k not in ("_att_packets",)
    }
    serializable_result["capture_id"] = capture_id
    serializable_result["description"] = description
    serializable_result["timestamp"] = timestamp

    result_file.write_text(json.dumps(serializable_result, indent=2, default=str))

    # Update progress
    progress = _load_progress()
    progress["captures"].append({
        "id": capture_id,
        "description": description,
        "timestamp": timestamp,
        "filepath": snoop_path,
        "service_ids": list(result["service_ids"].keys()),
    })
    _save_progress(progress)

    return serializable_result


@app.get("/api/captures")
async def list_captures():
    """List all saved capture results."""
    captures = []
    for f in sorted(RESULTS_DIR.glob("*.json")):
        if f.name == "progress.json":
            continue
        try:
            data = json.loads(f.read_text())
            captures.append({
                "capture_id": data.get("capture_id", f.stem),
                "description": data.get("description", ""),
                "timestamp": data.get("timestamp", ""),
                "total_att_packets": data.get("total_att_packets", 0),
                "total_transport": data.get("total_transport", 0),
                "service_count": len(data.get("service_ids", {})),
            })
        except (json.JSONDecodeError, Exception):
            captures.append({"capture_id": f.stem, "description": "Error reading", "timestamp": ""})
    return {"captures": captures}


@app.get("/api/captures/{capture_id}")
async def get_capture(capture_id: str):
    """Get full analysis results for a capture."""
    result_file = RESULTS_DIR / f"{capture_id}.json"
    if not result_file.exists():
        raise HTTPException(status_code=404, detail=f"Capture '{capture_id}' not found")
    try:
        data = json.loads(result_file.read_text())
        return data
    except (json.JSONDecodeError, Exception) as e:
        raise HTTPException(status_code=500, detail=f"Error reading capture: {e}")


@app.delete("/api/captures")
async def delete_all_captures():
    """Delete all capture logs and result files (except progress.json)."""
    deleted = {"captures": 0, "results": 0}
    for f in CAPTURES_DIR.iterdir():
        if f.is_file():
            f.unlink()
            deleted["captures"] += 1
        elif f.is_dir():
            shutil.rmtree(str(f), ignore_errors=True)
            deleted["captures"] += 1
    for f in RESULTS_DIR.iterdir():
        if f.is_file() and f.name != "progress.json":
            f.unlink()
            deleted["results"] += 1
    # Clear signal file too
    if SIGNAL_FILE.exists():
        SIGNAL_FILE.unlink()
    return {"deleted": deleted}


@app.get("/api/progress")
async def get_progress():
    """Get discovery progress."""
    return _load_progress()


@app.post("/api/analyze")
async def reanalyze(req: AnalyzeRequest):
    """Re-analyze a capture with updated known services."""
    # Find the capture file
    progress = _load_progress()
    filepath = None
    for cap in progress.get("captures", []):
        if cap.get("id") == req.capture_id:
            filepath = cap.get("filepath")
            break

    if not filepath or not os.path.exists(filepath):
        # Try to find in captures dir
        for f in CAPTURES_DIR.glob(f"*{req.capture_id}*"):
            filepath = str(f)
            break

    if not filepath or not os.path.exists(filepath):
        raise HTTPException(status_code=404, detail=f"Capture file for '{req.capture_id}' not found")

    known_services = _get_known_services()
    try:
        result = analyzer.analyze_capture(filepath, known_services=known_services)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Analysis failed: {str(e)}")

    # Update saved result
    serializable_result = {k: v for k, v in result.items() if k not in ("_att_packets",)}
    serializable_result["capture_id"] = req.capture_id
    serializable_result["description"] = req.context or ""
    serializable_result["reanalyzed_at"] = datetime.now().isoformat()

    result_file = RESULTS_DIR / f"{req.capture_id}.json"
    result_file.write_text(json.dumps(serializable_result, indent=2, default=str))

    return serializable_result


@app.post("/api/diff")
async def diff_captures_endpoint(old_id: str, new_id: str):
    """Compare two captures."""
    old_file = RESULTS_DIR / f"{old_id}.json"
    new_file = RESULTS_DIR / f"{new_id}.json"

    if not old_file.exists():
        raise HTTPException(status_code=404, detail=f"Old capture '{old_id}' not found")
    if not new_file.exists():
        raise HTTPException(status_code=404, detail=f"New capture '{new_id}' not found")

    old_data = json.loads(old_file.read_text())
    new_data = json.loads(new_file.read_text())

    return analyzer.diff_captures(old_data, new_data)


SIGNAL_FILE = BASE_DIR / "signal.json"


@app.post("/api/signal")
async def signal_claude(req: SignalRequest):
    """Write a signal file that Claude can poll to know the user's status."""
    signal = {
        "status": req.status,
        "capture_id": req.capture_id,
        "notes": req.notes,
        "timestamp": datetime.now().isoformat(),
    }
    SIGNAL_FILE.write_text(json.dumps(signal, indent=2))
    return signal


@app.get("/api/signal")
async def read_signal():
    """Read the current signal (for Claude to poll)."""
    if not SIGNAL_FILE.exists():
        return {"status": "idle", "timestamp": None}
    try:
        return json.loads(SIGNAL_FILE.read_text())
    except (json.JSONDecodeError, Exception):
        return {"status": "idle", "timestamp": None}


@app.delete("/api/signal")
async def clear_signal():
    """Clear the signal file after Claude has consumed it."""
    if SIGNAL_FILE.exists():
        SIGNAL_FILE.unlink()
    return {"cleared": True}



@app.post("/api/captures/{capture_id}/notes")
async def update_capture_notes(capture_id: str, req: SignalRequest):
    """Add user notes to a capture result."""
    result_file = RESULTS_DIR / f"{capture_id}.json"
    if not result_file.exists():
        raise HTTPException(status_code=404, detail=f"Capture '{capture_id}' not found")
    data = json.loads(result_file.read_text())
    data["user_notes"] = req.notes
    result_file.write_text(json.dumps(data, indent=2, default=str))
    return {"capture_id": capture_id, "notes": req.notes}


# =============================================================================
# Main
# =============================================================================

if __name__ == "__main__":
    import uvicorn
    print("BLE Capture Analyzer")
    print(f"  UI: http://localhost:8642")
    print(f"  Captures: {CAPTURES_DIR}")
    print(f"  Results:  {RESULTS_DIR}")
    uvicorn.run(app, host="0.0.0.0", port=8642)
