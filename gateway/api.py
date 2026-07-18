import os
import re
import subprocess
import time
import json
import csv
import io
from datetime import datetime
from urllib import parse as urllib_parse
from urllib import request as urllib_request

from flask import Flask, jsonify, request, Response, send_from_directory

app = Flask(__name__)

PROFILES_DIR = "/app/profiles"
LAN_IFACE = os.environ.get("LAN_IFACE", "eth0")
WAN_IFACE = os.environ.get("WAN_IFACE", "eth1")
EXTRA_LAN_IFACES = [
    iface.strip() for iface in os.environ.get("EXTRA_LAN_IFACES", "").split()
    if iface.strip()
]
# Set by entrypoint.sh only when WG_ENABLE=true: the physical interface that
# also carries wg0's own encapsulated UDP transport (it's the container's
# only route back to the host). Shaping it plainly double-delays WG-tunneled
# traffic - see apply_shaping()'s wg_exempt path below and common.sh's
# apply_netem_wg_exempt for the full explanation.
WG_CARRIER_IFACE = os.environ.get("WG_CARRIER_IFACE", "")
WG_LISTEN_PORT = os.environ.get("WG_LISTEN_PORT", "51820")

QOO_CONFIG_PATH = os.environ.get("QOO_CONFIG_PATH", "/pcap/qoo-config.json")
QOO_ACTIVE_PROFILE_PATH = os.environ.get("QOO_ACTIVE_PROFILE_PATH", "/pcap/qoo-active-profile.txt")
QOO_PROFILES_DIR = os.environ.get("QOO_PROFILES_DIR", "/qoo-profiles")
INFLUX_URL = os.environ.get("INFLUX_URL", "")
INFLUX_ORG = os.environ.get("INFLUX_ORG", "")
INFLUX_BUCKET = os.environ.get("INFLUX_BUCKET", "")
INFLUX_TOKEN = os.environ.get("INFLUX_TOKEN", "")
CORS_ALLOWED_ORIGINS = {
    origin.strip()
    for origin in os.environ.get(
        "CORS_ALLOWED_ORIGINS",
        "http://localhost:8080,http://127.0.0.1:8080,http://localhost:3000,http://127.0.0.1:3000",
    ).split(",")
    if origin.strip()
}
WEBRTC_RECORDINGS_DIR = os.environ.get("WEBRTC_RECORDINGS_DIR", "/webrtc-recordings")
WEBRTC_REFERENCE_DIR = os.environ.get("WEBRTC_REFERENCE_DIR", "/webrtc-reference")
WEBRTC_CACHE_DIR = os.environ.get("WEBRTC_CACHE_DIR", "/webrtc-cache")
WEBRTC_SOURCE_MODE = os.environ.get("WEBRTC_SOURCE_MODE", "reference")
WEBRTC_ICE_SERVERS = [
    {"urls": ["stun:stun.l.google.com:19302"]},
    {
        "urls": [
            "stun:openrelay.metered.ca:80",
            "turn:openrelay.metered.ca:80",
            "turn:openrelay.metered.ca:443",
            "turn:openrelay.metered.ca:443?transport=tcp",
        ],
        "username": "openrelayproject",
        "credential": "openrelayproject",
    },
]

WEBRTC_SESSION_TTL_SECS = 60 * 60
WEBRTC_SESSIONS = {}
WEBRTC_MEDIA_EXTENSIONS = {".mp4", ".mkv"}

QOO_DEFAULTS = {
    "qooMinThroughputMbps": 2.0,
    "qooLossLower": 0.001,
    "qooLossUpper": 0.02,
    "qooLatencyP50Lower": 50.0,
    "qooLatencyP50Upper": 150.0,
    "qooLatencyP75Lower": 75.0,
    "qooLatencyP75Upper": 175.0,
    "qooLatencyP90Lower": 90.0,
    "qooLatencyP90Upper": 190.0,
    "qooLatencyP95Lower": 100.0,
    "qooLatencyP95Upper": 200.0,
    "qooLatencyP99Lower": 150.0,
    "qooLatencyP99Upper": 300.0,
    "qooLatencyPercentiles": ["p50", "p75", "p90", "p95", "p99"],
}

state = {
    "active_profile": "baseline",
    "switched_at": time.time(),
}


def _qoo_string_field_escape(value):
    return str(value).replace("\\", "\\\\").replace('"', '\\"')


def _qoo_escape_tag(value):
    return str(value).replace(",", "\\,").replace(" ", "\\ ").replace("=", "\\=")


def _qoo_clean_percentiles(value):
    if isinstance(value, str):
        raw = [v.strip() for v in value.split(",") if v.strip()]
    elif isinstance(value, list):
        raw = [str(v).strip() for v in value if str(v).strip()]
    else:
        raw = []

    allowed = ["p50", "p75", "p90", "p95", "p99"]
    cleaned = [v for v in raw if v in allowed]
    order = {"p50": 0, "p75": 1, "p90": 2, "p95": 3, "p99": 4}
    cleaned = sorted(set(cleaned), key=lambda x: order[x])
    if not cleaned:
        return ["p50", "p75", "p90", "p95", "p99"]
    return cleaned


def _qoo_normalize(candidate):
    normalized = dict(QOO_DEFAULTS)
    incoming = candidate or {}

    for key, default in QOO_DEFAULTS.items():
        if key == "qooLatencyPercentiles":
            normalized[key] = _qoo_clean_percentiles(incoming.get(key, default))
            continue
        value = incoming.get(key, default)
        try:
            num = float(value)
        except (TypeError, ValueError):
            num = float(default)
        if num < 0:
            num = 0.0
        normalized[key] = num

    # Keep latency bounds valid even if caller sends inverted values.
    for p in ("P50", "P75", "P90", "P95", "P99"):
        lower_key = f"qooLatency{p}Lower"
        upper_key = f"qooLatency{p}Upper"
        if normalized[lower_key] >= normalized[upper_key]:
            normalized[upper_key] = normalized[lower_key] + 1.0

    return normalized


def _qoo_load():
    try:
        with open(QOO_CONFIG_PATH, "r", encoding="utf-8") as f:
            return _qoo_normalize(json.load(f))
    except FileNotFoundError:
        return dict(QOO_DEFAULTS)
    except Exception:
        return dict(QOO_DEFAULTS)


def _qoo_save(config):
    os.makedirs(os.path.dirname(QOO_CONFIG_PATH), exist_ok=True)
    tmp_path = f"{QOO_CONFIG_PATH}.tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, sort_keys=True)
    os.replace(tmp_path, QOO_CONFIG_PATH)


def _qoo_active_profile_load():
    try:
        with open(QOO_ACTIVE_PROFILE_PATH, "r", encoding="utf-8") as f:
            value = f.read().strip()
            if _qoo_profile_name_ok(value):
                return value
    except FileNotFoundError:
        pass
    except Exception:
        pass
    return "manual"


def _qoo_active_profile_save(name):
    os.makedirs(os.path.dirname(QOO_ACTIVE_PROFILE_PATH), exist_ok=True)
    tmp_path = f"{QOO_ACTIVE_PROFILE_PATH}.tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.write(f"{name}\n")
    os.replace(tmp_path, QOO_ACTIVE_PROFILE_PATH)


def _qoo_write_influx(config, active_profile=None):
    if not (INFLUX_URL and INFLUX_ORG and INFLUX_BUCKET and INFLUX_TOKEN):
        return

    write_url = (
        f"{INFLUX_URL.rstrip('/')}/api/v2/write?"
        f"org={urllib_parse.quote(INFLUX_ORG)}&"
        f"bucket={urllib_parse.quote(INFLUX_BUCKET)}&precision=ns"
    )
    fields = _qoo_config_fields(config, active_profile=active_profile)
    line = f"qoo_config,source={_qoo_escape_tag('gateway')} {','.join(fields)}"

    req = urllib_request.Request(
        write_url,
        data=line.encode("utf-8"),
        method="POST",
        headers={
            "Authorization": f"Token {INFLUX_TOKEN}",
            "Content-Type": "text/plain; charset=utf-8",
        },
    )
    try:
        with urllib_request.urlopen(req, timeout=5):
            pass
    except Exception as exc:
        print(f"QOO_CONFIG_WRITE_INFLUX error={exc}", flush=True)


def _qoo_config_fields(config, active_profile=None):
    percentile_csv = ",".join(config["qooLatencyPercentiles"])
    fields = [
        f"qooMinThroughputMbps={config['qooMinThroughputMbps']}",
        f"qooLossLower={config['qooLossLower']}",
        f"qooLossUpper={config['qooLossUpper']}",
        f"qooLatencyP50Lower={config['qooLatencyP50Lower']}",
        f"qooLatencyP50Upper={config['qooLatencyP50Upper']}",
        f"qooLatencyP75Lower={config['qooLatencyP75Lower']}",
        f"qooLatencyP75Upper={config['qooLatencyP75Upper']}",
        f"qooLatencyP90Lower={config['qooLatencyP90Lower']}",
        f"qooLatencyP90Upper={config['qooLatencyP90Upper']}",
        f"qooLatencyP95Lower={config['qooLatencyP95Lower']}",
        f"qooLatencyP95Upper={config['qooLatencyP95Upper']}",
        f"qooLatencyP99Lower={config['qooLatencyP99Lower']}",
        f"qooLatencyP99Upper={config['qooLatencyP99Upper']}",
        f'qooLatencyPercentilesCsv="{_qoo_string_field_escape(percentile_csv)}"',
    ]
    if active_profile:
        fields.append(f'qooActiveProfile="{_qoo_string_field_escape(active_profile)}"')
    return fields


def _influx_write_line(line):
    if not (INFLUX_URL and INFLUX_ORG and INFLUX_BUCKET and INFLUX_TOKEN):
        raise RuntimeError("influx not configured")

    write_url = (
        f"{INFLUX_URL.rstrip('/')}/api/v2/write?"
        f"org={urllib_parse.quote(INFLUX_ORG)}&"
        f"bucket={urllib_parse.quote(INFLUX_BUCKET)}&precision=ns"
    )

    req = urllib_request.Request(
        write_url,
        data=line.encode("utf-8"),
        method="POST",
        headers={
            "Authorization": f"Token {INFLUX_TOKEN}",
            "Content-Type": "text/plain; charset=utf-8",
        },
    )
    try:
        with urllib_request.urlopen(req, timeout=5):
            pass
    except Exception as exc:
        raise RuntimeError(str(exc)) from exc


def _influx_query_rows(flux_query):
    if not (INFLUX_URL and INFLUX_ORG and INFLUX_TOKEN):
        raise RuntimeError("influx not configured")

    query_url = f"{INFLUX_URL.rstrip('/')}/api/v2/query?org={urllib_parse.quote(INFLUX_ORG)}"
    req = urllib_request.Request(
        query_url,
        data=flux_query.encode("utf-8"),
        method="POST",
        headers={
            "Authorization": f"Token {INFLUX_TOKEN}",
            "Accept": "application/csv",
            "Content-Type": "application/vnd.flux",
        },
    )
    with urllib_request.urlopen(req, timeout=8) as resp:
        text = resp.read().decode("utf-8", errors="replace")

    rows = []
    for row in csv.DictReader(io.StringIO(text)):
        if not row:
            continue
        # Influx CSV repeats table metadata rows with empty _field/_value.
        if row.get("_measurement") == "error":
            continue
        rows.append(row)
    return rows


def _qoo_profile_name_ok(name):
    return bool(re.fullmatch(r"[A-Za-z0-9._-]{1,64}", name or ""))


def _webrtc_session_ok(value):
    return bool(re.fullmatch(r"[A-Za-z0-9._:-]{1,128}", value or ""))


def _webrtc_gc_sessions():
    now = time.time()
    stale = []
    for sid, entry in WEBRTC_SESSIONS.items():
        ts = float(entry.get("updated_at", 0.0))
        if now - ts > WEBRTC_SESSION_TTL_SECS:
            stale.append(sid)
    for sid in stale:
        WEBRTC_SESSIONS.pop(sid, None)


def _webrtc_touch_session(session):
    _webrtc_gc_sessions()
    entry = WEBRTC_SESSIONS.setdefault(session, {})
    entry.setdefault("offer_candidates", [])
    entry.setdefault("answer_candidates", [])
    entry["updated_at"] = time.time()
    return entry


def _webrtc_event(session, event, data=None):
    entry = _webrtc_touch_session(session)
    events = entry.setdefault("events", [])
    events.append({
        "ts": time.time(),
        "event": event,
        "data": data or {},
    })
    if len(events) > 500:
        del events[:-500]


def _webrtc_ts_filename(prefix, session, ext):
    ts = datetime.utcnow().strftime("%Y%m%d-%H%M%S")
    safe_session = re.sub(r"[^A-Za-z0-9._:-]", "_", session)
    return f"{prefix}-{safe_session}-{ts}.{ext}"


def _webrtc_reference_files():
    files = []
    if not os.path.isdir(WEBRTC_REFERENCE_DIR):
        return files

    for name in sorted(os.listdir(WEBRTC_REFERENCE_DIR)):
        full = os.path.join(WEBRTC_REFERENCE_DIR, name)
        ext = os.path.splitext(name)[1].lower()
        if os.path.isfile(full) and ext in WEBRTC_MEDIA_EXTENSIONS:
            files.append(name)
    return files


def _webrtc_reference_filename_ok(name):
    return bool(re.fullmatch(r"[A-Za-z0-9._ -]{1,255}", name or ""))


def _webrtc_ensure_playable(name):
    ext = os.path.splitext(name)[1].lower()
    src = os.path.join(WEBRTC_REFERENCE_DIR, name)
    if not os.path.isfile(src):
        raise FileNotFoundError("reference media not found")

    if ext == ".mp4":
        return f"/webrtc/reference/{name}"

    if ext != ".mkv":
        raise ValueError("unsupported reference extension")

    os.makedirs(WEBRTC_CACHE_DIR, exist_ok=True)
    out_name = os.path.splitext(name)[0] + ".mp4"
    out_path = os.path.join(WEBRTC_CACHE_DIR, out_name)

    src_mtime = os.path.getmtime(src)
    out_mtime = os.path.getmtime(out_path) if os.path.isfile(out_path) else 0.0
    if out_mtime < src_mtime:
        cmd = [
            "ffmpeg", "-y",
            "-i", src,
            "-an",
            "-c:v", "libx264",
            "-preset", "veryfast",
            "-crf", "23",
            "-pix_fmt", "yuv420p",
            "-movflags", "+faststart",
            out_path,
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            raise RuntimeError(f"ffmpeg transcode failed: {proc.stderr[-500:]}")

    return f"/webrtc/cache/{out_name}"


def _qoo_write_profile(name, config):
    fields = _qoo_config_fields(config)
    line = f"qoo_config_profile,name={_qoo_escape_tag(name)} {','.join(fields)}"
    _influx_write_line(line)


def _qoo_profile_path(name):
    return os.path.join(QOO_PROFILES_DIR, f"{name}.json")


def _qoo_profiles_list_files():
    try:
        entries = os.listdir(QOO_PROFILES_DIR)
    except FileNotFoundError:
        return []
    names = []
    for entry in entries:
        if not entry.endswith(".json"):
            continue
        name = entry[:-5]
        if _qoo_profile_name_ok(name):
            names.append(name)
    return sorted(set(names))


def _qoo_profile_load_file(name):
    path = _qoo_profile_path(name)
    try:
        with open(path, "r", encoding="utf-8") as f:
            payload = json.load(f)
    except FileNotFoundError:
        return None
    except Exception as exc:
        raise RuntimeError(f"invalid profile file '{name}': {exc}") from exc
    return _qoo_normalize(payload)


def _qoo_profile_save_file(name, config, overwrite=False):
    path = _qoo_profile_path(name)
    if os.path.exists(path) and not overwrite:
        raise FileExistsError(name)
    os.makedirs(QOO_PROFILES_DIR, exist_ok=True)
    tmp_path = f"{path}.tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, sort_keys=True)
    os.replace(tmp_path, path)


def _qoo_sync_profiles_to_influx():
    names = _qoo_profiles_list_files()
    synced = []
    for name in names:
        config = _qoo_profile_load_file(name)
        if config is None:
            continue
        _qoo_write_profile(name, config)
        synced.append(name)
    return synced


def _qoo_profile_from_rows(rows):
    if not rows:
        return None

    # Query uses pivot, so the latest row has one column per field.
    row = rows[-1]
    parsed = {}
    for key in QOO_DEFAULTS.keys():
        if key == "qooLatencyPercentiles":
            csv_value = row.get("qooLatencyPercentilesCsv", "")
            parsed[key] = _qoo_clean_percentiles(csv_value)
            continue
        parsed[key] = row.get(key, QOO_DEFAULTS[key])
    return _qoo_normalize(parsed)


def _qoo_init(active_profile):
    config = _qoo_normalize(_qoo_load())
    _qoo_save(config)
    _qoo_write_influx(config, active_profile=active_profile)
    return config


qoo_active_profile = _qoo_active_profile_load()
qoo_config = _qoo_init(qoo_active_profile)
try:
    _qoo_sync_profiles_to_influx()
except Exception as exc:
    print(f"QOO_PROFILE_SYNC_STARTUP error={exc}", flush=True)


@app.after_request
def add_cors_headers(response):
    # Allow only configured local origins by default (demo-safe baseline).
    origin = request.headers.get("Origin", "")
    allow_any = "*" in CORS_ALLOWED_ORIGINS
    if origin and (allow_any or origin in CORS_ALLOWED_ORIGINS):
        response.headers["Access-Control-Allow-Origin"] = "*" if allow_any else origin
        response.headers["Vary"] = "Origin"
    response.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type"
    return response


def list_profiles():
    return sorted(
        f[:-3] for f in os.listdir(PROFILES_DIR)
        if f.endswith(".sh") and f != "common.sh"
    )


@app.route("/profiles", methods=["GET"])
def profiles():
    return jsonify({"profiles": list_profiles()})


@app.route("/webrtc/config", methods=["GET"])
def webrtc_config_get():
    files = _webrtc_reference_files()
    default_file = "reference.mp4" if "reference.mp4" in files else (files[0] if files else None)
    return jsonify({
        "source_mode": WEBRTC_SOURCE_MODE,
        "reference_url": f"/webrtc/reference/{default_file}" if default_file else None,
        "default_reference_file": default_file,
        "reference_files": files,
        "ice_servers": WEBRTC_ICE_SERVERS,
    })


@app.route("/webrtc/reference-files", methods=["GET"])
def webrtc_reference_files_get():
    files = _webrtc_reference_files()
    return jsonify({"files": files})


@app.route("/webrtc/reference-playable/<path:filename>", methods=["GET"])
def webrtc_reference_playable_get(filename):
    if not _webrtc_reference_filename_ok(filename):
        return jsonify({"error": "invalid filename"}), 400
    try:
        playable_url = _webrtc_ensure_playable(filename)
    except FileNotFoundError:
        return jsonify({"error": "reference file not found"}), 404
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400
    except Exception as exc:
        return jsonify({"error": str(exc)}), 500
    return jsonify({"filename": filename, "playable_url": playable_url})


@app.route("/webrtc/reference/<path:filename>", methods=["GET"])
def webrtc_reference_file(filename):
    return send_from_directory(WEBRTC_REFERENCE_DIR, filename)


@app.route("/webrtc/cache/<path:filename>", methods=["GET"])
def webrtc_cache_file(filename):
    return send_from_directory(WEBRTC_CACHE_DIR, filename)


@app.route("/webrtc/sender", methods=["GET"])
def webrtc_sender_page():
    return send_from_directory("/web-ui", "webrtc-sender.html")


@app.route("/webrtc/session", methods=["POST"])
def webrtc_session_create():
    payload = request.get_json(silent=True) or {}
    session = str(payload.get("session") or "").strip()
    if not _webrtc_session_ok(session):
        return jsonify({"error": "invalid session"}), 400

    payload = request.get_json(silent=True) or {}
    reset = bool(payload.get("reset", False))

    entry = _webrtc_touch_session(session)
    created = "offer" not in entry and "answer" not in entry
    if reset or created:
        entry["offer"] = None
        entry["answer"] = None
        entry["offer_candidates"] = []
        entry["answer_candidates"] = []
        _webrtc_event(session, "session_reset", {"reset": reset, "created": created})
    else:
        _webrtc_event(session, "session_reused", {
            "has_offer": bool(entry.get("offer")),
            "has_answer": bool(entry.get("answer")),
            "offer_candidates": len(entry.get("offer_candidates", [])),
            "answer_candidates": len(entry.get("answer_candidates", [])),
        })
    return jsonify({"ok": True, "session": session, "created": created, "reset": reset})


@app.route("/webrtc/session/<session>", methods=["GET"])
def webrtc_session_get(session):
    if not _webrtc_session_ok(session):
        return jsonify({"error": "invalid session"}), 400
    entry = WEBRTC_SESSIONS.get(session)
    if not entry:
        return jsonify({"exists": False, "session": session})
    return jsonify({
        "exists": True,
        "session": session,
        "has_offer": bool(entry.get("offer")),
        "has_answer": bool(entry.get("answer")),
    })


@app.route("/webrtc/offer", methods=["POST"])
def webrtc_offer_post():
    payload = request.get_json(silent=True) or {}
    session = str(payload.get("session") or "").strip()
    sdp = str(payload.get("sdp") or "")
    if not _webrtc_session_ok(session):
        return jsonify({"error": "invalid session"}), 400
    if not sdp:
        return jsonify({"error": "missing sdp"}), 400

    entry = _webrtc_touch_session(session)
    entry["offer"] = sdp
    _webrtc_event(session, "offer_posted", {"sdp_len": len(sdp)})
    return jsonify({"ok": True, "session": session})


@app.route("/webrtc/offer/<session>", methods=["GET"])
def webrtc_offer_get(session):
    if not _webrtc_session_ok(session):
        return jsonify({"error": "invalid session"}), 400
    entry = WEBRTC_SESSIONS.get(session)
    if not entry or not entry.get("offer"):
        return jsonify({"available": False, "session": session})
    return jsonify({"available": True, "session": session, "sdp": entry["offer"]})


@app.route("/webrtc/answer", methods=["POST"])
def webrtc_answer_post():
    payload = request.get_json(silent=True) or {}
    session = str(payload.get("session") or "").strip()
    sdp = str(payload.get("sdp") or "")
    if not _webrtc_session_ok(session):
        return jsonify({"error": "invalid session"}), 400
    if not sdp:
        return jsonify({"error": "missing sdp"}), 400

    entry = _webrtc_touch_session(session)
    entry["answer"] = sdp
    _webrtc_event(session, "answer_posted", {"sdp_len": len(sdp)})
    return jsonify({"ok": True, "session": session})


@app.route("/webrtc/answer/<session>", methods=["GET"])
def webrtc_answer_get(session):
    if not _webrtc_session_ok(session):
        return jsonify({"error": "invalid session"}), 400
    entry = WEBRTC_SESSIONS.get(session)
    if not entry or not entry.get("answer"):
        return jsonify({"available": False, "session": session})
    return jsonify({"available": True, "session": session, "sdp": entry["answer"]})


@app.route("/webrtc/candidate", methods=["POST"])
def webrtc_candidate_post():
    payload = request.get_json(silent=True) or {}
    session = str(payload.get("session") or "").strip()
    role = str(payload.get("role") or "").strip()
    candidate = payload.get("candidate")
    if not _webrtc_session_ok(session):
        return jsonify({"error": "invalid session"}), 400
    if role not in ("offer", "answer"):
        return jsonify({"error": "invalid role"}), 400
    if not isinstance(candidate, dict):
        return jsonify({"error": "invalid candidate"}), 400

    entry = _webrtc_touch_session(session)
    key = "offer_candidates" if role == "offer" else "answer_candidates"
    entry[key].append(candidate)
    cstr = str(candidate.get("candidate") or "")
    ctype = "unknown"
    m = re.search(r" typ ([a-zA-Z0-9_]+)", cstr)
    if m:
        ctype = m.group(1)
    _webrtc_event(session, "candidate_posted", {"role": role, "type": ctype, "count": len(entry[key])})
    return jsonify({"ok": True, "session": session, "role": role, "count": len(entry[key])})


@app.route("/webrtc/candidates/<session>/<role>", methods=["GET"])
def webrtc_candidates_get(session, role):
    if not _webrtc_session_ok(session):
        return jsonify({"error": "invalid session"}), 400
    if role not in ("offer", "answer"):
        return jsonify({"error": "invalid role"}), 400

    entry = WEBRTC_SESSIONS.get(session)
    if not entry:
        return jsonify({"session": session, "role": role, "candidates": [], "next_index": 0})

    key = "offer_candidates" if role == "offer" else "answer_candidates"
    data = entry.get(key, [])
    try:
        start = int(request.args.get("from", "0"))
    except Exception:
        start = 0
    if start < 0:
        start = 0
    if start > len(data):
        start = len(data)

    result = {
        "session": session,
        "role": role,
        "candidates": data[start:],
        "next_index": len(data),
    }
    _webrtc_event(session, "candidates_polled", {
        "role": role,
        "from": start,
        "returned": len(result["candidates"]),
        "total": len(data),
    })
    return jsonify(result)


@app.route("/webrtc/receiver-metrics", methods=["POST"])
def webrtc_receiver_metrics_post():
    payload = request.get_json(silent=True) or {}
    session = str(payload.get("session") or "").strip()
    if not _webrtc_session_ok(session):
        return jsonify({"error": "invalid session"}), 400

    ts_ms = payload.get("timestamp_ms")
    try:
        ts_ns = int(float(ts_ms) * 1_000_000) if ts_ms is not None else int(time.time() * 1_000_000_000)
    except Exception:
        ts_ns = int(time.time() * 1_000_000_000)

    def _num(name):
        value = payload.get(name)
        if value is None:
            return None
        try:
            return float(value)
        except Exception:
            return None

    fields = []
    for name in (
        "rtt_ms",
        "jitter_ms",
        "packets_lost",
        "packets_received",
        "bytes_received",
        "bitrate_bps",
        "frame_rate_fps",
        "resolution_width",
        "resolution_height",
        "freeze_count",
    ):
        v = _num(name)
        if v is not None:
            fields.append(f"{name}={v}")

    if not fields:
        return jsonify({"ok": True, "dropped": "no metrics provided"})

    _webrtc_event(session, "receiver_metrics", {"field_count": len(fields)})

    line = (
        "qoo_webrtc_receiver,source=webrtc,mode=active,role=receiver,"
        f"session={_qoo_escape_tag(session)} "
        + ",".join(fields)
        + f" {ts_ns}"
    )

    try:
        _influx_write_line(line)
    except Exception as exc:
        _webrtc_event(session, "receiver_metrics_error", {"error": str(exc)})
        return jsonify({"error": str(exc)}), 500
    return jsonify({"ok": True})


@app.route("/webrtc/debug/<session>", methods=["GET"])
def webrtc_debug_get(session):
    if not _webrtc_session_ok(session):
        return jsonify({"error": "invalid session"}), 400
    entry = WEBRTC_SESSIONS.get(session)
    if not entry:
        return jsonify({"exists": False, "session": session})

    events = entry.get("events", [])
    limit = request.args.get("limit", "100")
    try:
        limit_int = max(1, min(int(limit), 500))
    except Exception:
        limit_int = 100

    def _summarize_candidates(items):
        out = []
        for c in items[-30:]:
            cstr = str(c.get("candidate") or "")
            ctype = "unknown"
            m = re.search(r" typ ([a-zA-Z0-9_]+)", cstr)
            if m:
                ctype = m.group(1)
            out.append({
                "type": ctype,
                "sdpMid": c.get("sdpMid"),
                "sdpMLineIndex": c.get("sdpMLineIndex"),
                "usernameFragment": c.get("usernameFragment"),
                "raw": cstr[:180],
            })
        return out

    return jsonify({
        "exists": True,
        "session": session,
        "has_offer": bool(entry.get("offer")),
        "has_answer": bool(entry.get("answer")),
        "offer_sdp_len": len(entry.get("offer") or ""),
        "answer_sdp_len": len(entry.get("answer") or ""),
        "offer_candidates": len(entry.get("offer_candidates", [])),
        "answer_candidates": len(entry.get("answer_candidates", [])),
        "offer_candidate_details": _summarize_candidates(entry.get("offer_candidates", [])),
        "answer_candidate_details": _summarize_candidates(entry.get("answer_candidates", [])),
        "updated_at": entry.get("updated_at"),
        "events": events[-limit_int:],
    })


@app.route("/webrtc/recording", methods=["POST"])
def webrtc_recording_upload():
    session = str(request.args.get("session") or request.form.get("session") or "").strip()
    if not _webrtc_session_ok(session):
        return jsonify({"error": "invalid session"}), 400

    file = request.files.get("recording")
    if file is None:
        return jsonify({"error": "missing recording file"}), 400

    os.makedirs(WEBRTC_RECORDINGS_DIR, exist_ok=True)
    filename = _webrtc_ts_filename("webrtc-receiver", session, "webm")
    path = os.path.join(WEBRTC_RECORDINGS_DIR, filename)
    file.save(path)
    return jsonify({"ok": True, "session": session, "filename": filename, "path": path})


@app.route("/qoo-config", methods=["GET"])
def qoo_config_get():
    return jsonify(qoo_config)


@app.route("/qoo-active-profile", methods=["GET"])
def qoo_active_profile_get():
    return jsonify({"activeProfile": qoo_active_profile})


@app.route("/qoo-config", methods=["POST"])
def qoo_config_set():
    global qoo_config, qoo_active_profile
    data = request.get_json(silent=True) or {}
    merged = dict(qoo_config)
    merged.update(data)
    qoo_config = _qoo_normalize(merged)
    qoo_active_profile = "manual"
    _qoo_save(qoo_config)
    _qoo_active_profile_save(qoo_active_profile)
    _qoo_write_influx(qoo_config, active_profile=qoo_active_profile)
    return jsonify(qoo_config)


@app.route("/qoo-profiles", methods=["GET"])
def qoo_profiles_list():
    names = _qoo_profiles_list_files()
    return jsonify({"profiles": names})


@app.route("/qoo-profiles/<name>", methods=["GET"])
def qoo_profile_get(name):
    if not _qoo_profile_name_ok(name):
        return jsonify({"error": "invalid profile name"}), 400

    try:
        config = _qoo_profile_load_file(name)
    except RuntimeError as exc:
        return jsonify({"error": str(exc)}), 500
    if config is None:
        return jsonify({"error": "profile not found"}), 404
    return jsonify({"name": name, "config": config})


@app.route("/qoo-profiles/<name>", methods=["POST"])
def qoo_profile_save(name):
    if not _qoo_profile_name_ok(name):
        return jsonify({"error": "invalid profile name"}), 400

    payload = request.get_json(silent=True) or {}
    overwrite = str(request.args.get("overwrite", "")).lower() in ("1", "true", "yes")
    if isinstance(payload, dict):
        overwrite = overwrite or bool(payload.pop("overwrite", False))
    merged = dict(qoo_config)
    merged.update(payload)
    config = _qoo_normalize(merged)
    try:
        _qoo_profile_save_file(name, config, overwrite=overwrite)
        _qoo_write_profile(name, config)
    except FileExistsError:
        return jsonify({"error": "profile exists", "name": name}), 409
    except Exception as exc:
        return jsonify({"error": str(exc)}), 500
    return jsonify({"saved": True, "name": name, "config": config, "overwrote": overwrite})


@app.route("/qoo-profiles/load/<name>", methods=["POST"])
def qoo_profile_load(name):
    global qoo_config, qoo_active_profile
    if not _qoo_profile_name_ok(name):
        return jsonify({"error": "invalid profile name"}), 400

    try:
        config = _qoo_profile_load_file(name)
    except RuntimeError as exc:
        return jsonify({"error": str(exc)}), 500
    if config is None:
        return jsonify({"error": "profile not found"}), 404

    qoo_config = config
    qoo_active_profile = name
    _qoo_save(qoo_config)
    _qoo_active_profile_save(qoo_active_profile)
    _qoo_write_influx(qoo_config, active_profile=qoo_active_profile)
    return jsonify({"loaded": True, "name": name, "activeProfile": qoo_active_profile, "config": qoo_config})


@app.route("/qoo-profiles/reload", methods=["POST"])
def qoo_profile_reload_all():
    try:
        synced = _qoo_sync_profiles_to_influx()
    except Exception as exc:
        return jsonify({"error": str(exc)}), 500
    return jsonify({"reloaded": True, "count": len(synced), "profiles": synced})


@app.route("/qoo-profiles/import", methods=["POST"])
def qoo_profile_import():
    payload = request.get_json(silent=True) or {}
    name = (payload.get("name") or "").strip()
    if not _qoo_profile_name_ok(name):
        return jsonify({"error": "invalid profile name"}), 400

    incoming = payload.get("config")
    if not isinstance(incoming, dict):
        return jsonify({"error": "missing config object"}), 400

    overwrite = bool(payload.get("overwrite", False))
    config = _qoo_normalize(incoming)
    try:
        _qoo_profile_save_file(name, config, overwrite=overwrite)
        _qoo_write_profile(name, config)
    except FileExistsError:
        return jsonify({"error": "profile exists", "name": name}), 409
    except Exception as exc:
        return jsonify({"error": str(exc)}), 500

    return jsonify({"imported": True, "name": name, "config": config, "overwrote": overwrite})


@app.route("/qoo-profiles/export/<name>", methods=["GET"])
def qoo_profile_export(name):
    if not _qoo_profile_name_ok(name):
        return jsonify({"error": "invalid profile name"}), 400
    try:
        config = _qoo_profile_load_file(name)
    except RuntimeError as exc:
        return jsonify({"error": str(exc)}), 500
    if config is None:
        return jsonify({"error": "profile not found"}), 404

    body = json.dumps({"name": name, "config": config}, indent=2, sort_keys=True)
    resp = Response(body, mimetype="application/json")
    resp.headers["Content-Disposition"] = f'attachment; filename="{name}.json"'
    return resp


@app.route("/status", methods=["GET"])
def status():
    return jsonify(state)


@app.route("/profile/<name>", methods=["POST"])
def switch_profile(name):
    script = os.path.join(PROFILES_DIR, f"{name}.sh")
    if not os.path.isfile(script):
        return jsonify({"error": f"unknown profile '{name}'"}), 404

    # LAN_IFACE/WAN_IFACE are already in the environment (exported by
    # entrypoint.sh); profile scripts read them directly.
    result = subprocess.run([script], capture_output=True, text=True)
    if result.returncode != 0:
        return jsonify({"error": result.stderr.strip()}), 500

    state["active_profile"] = name
    state["switched_at"] = time.time()
    state.pop("custom_params", None)

    # annotation label consumed by the collector metrics pipeline
    print(f"PROFILE_SWITCH profile={name} ts={state['switched_at']}", flush=True)

    return jsonify(state)


def build_netem_args(delay_ms, jitter_ms, distribution, loss_pct, loss_model, rate_mbit):
    """Build a `tc ... netem <args>` argument list, or [] for no shaping."""
    args = []
    if delay_ms > 0:
        args += ["delay", f"{delay_ms}ms"]
        if jitter_ms > 0:
            args += [f"{jitter_ms}ms", "distribution", distribution]
    if loss_pct > 0:
        if loss_model == "burst":
            # Gilbert model: same shape as the canned burst-loss profile
            # (bad-state/good-state loss ratio and transition probabilities),
            # scaled by the requested loss percentage.
            bad_state_loss = min(loss_pct * 2, 100)
            args += ["loss", "gemodel", f"{loss_pct}%", f"{bad_state_loss}%", "90%", "80%"]
        else:
            args += ["loss", f"{loss_pct}%"]
    if rate_mbit > 0:
        args += ["rate", f"{rate_mbit}mbit"]
    return args


def apply_shaping(iface, netem_args, wg_exempt=False):
    subprocess.run(["tc", "qdisc", "del", "dev", iface, "root"], capture_output=True)
    if not netem_args:
        subprocess.run(
            ["tc", "qdisc", "add", "dev", iface, "root", "pfifo_fast"],
            check=True, capture_output=True, text=True,
        )
        return
    if not wg_exempt:
        subprocess.run(
            ["tc", "qdisc", "add", "dev", iface, "root", "netem"] + netem_args,
            check=True, capture_output=True, text=True,
        )
        return
    # iface is WG_CARRIER_IFACE: it also carries wg0's own encapsulated UDP
    # traffic, so shape everything except that port - see WG_CARRIER_IFACE
    # comment above and common.sh's apply_netem_wg_exempt for the full story.
    subprocess.run(
        ["tc", "qdisc", "add", "dev", iface, "root", "handle", "1:", "prio",
         "bands", "2", "priomap"] + ["0"] * 16,
        check=True, capture_output=True, text=True,
    )
    subprocess.run(
        ["tc", "qdisc", "add", "dev", iface, "parent", "1:1", "netem"] + netem_args,
        check=True, capture_output=True, text=True,
    )
    subprocess.run(
        ["tc", "qdisc", "add", "dev", iface, "parent", "1:2", "pfifo_fast"],
        check=True, capture_output=True, text=True,
    )
    for direction in ("sport", "dport"):
        subprocess.run(
            ["tc", "filter", "add", "dev", iface, "parent", "1:0", "protocol", "ip",
             "prio", "1", "u32", "match", "ip", direction, WG_LISTEN_PORT, "0xffff",
             "flowid", "1:2"],
            check=True, capture_output=True, text=True,
        )


def lan_ifaces():
    ifaces = [LAN_IFACE]
    for iface in EXTRA_LAN_IFACES:
        if iface not in ifaces:
            ifaces.append(iface)
    return ifaces


def _time_to_ms(value, unit):
    value = float(value)
    if unit == "s":
        return value * 1000
    if unit == "us":
        return value / 1000
    return value  # "ms", or tc's unitless default (also milliseconds)


def _parse_netem(qdisc_show_output):
    """
    Pull delay/jitter/loss/rate back out of `tc qdisc show dev <iface>` text.
    Only the netem line matters here - on WG_CARRIER_IFACE that line is a
    child of the prio qdisc (see apply_shaping's wg_exempt path), but it's
    still a "qdisc netem ..." line in the same listing, so no special case
    is needed to find it.
    """
    result = {
        "delay_ms": 0.0, "jitter_ms": 0.0,
        "loss_pct": 0.0, "loss_model": "uniform",
        "rate_mbit": 0.0,
    }
    netem_line = next((l for l in qdisc_show_output.splitlines() if "netem" in l), None)
    if not netem_line:
        return result

    # tc adapts the time unit to magnitude when printing - a 1000ms delay
    # comes back as "delay 1s", not "delay 1000ms" (confirmed: pushing
    # delay_ms=2000, i.e. 1000ms per leg, printed literally "delay 1s"). An
    # "ms"-only regex silently matched nothing here and reported 0. Match
    # all three units tc can use (s/ms/us) and normalize back to ms.
    m = re.search(r"delay\s+([\d.]+)(s|ms|us)(?:\s+([\d.]+)(s|ms|us))?", netem_line)
    if m:
        result["delay_ms"] = _time_to_ms(m.group(1), m.group(2))
        if m.group(3):
            result["jitter_ms"] = _time_to_ms(m.group(3), m.group(4))

    # gemodel (burst/Gilbert) prints as "loss gemodel p 3% r 6% 1-h 90% 1-k 80%"
    m = re.search(r"loss gemodel p\s+([\d.]+)%", netem_line)
    if m:
        result["loss_pct"] = float(m.group(1))
        result["loss_model"] = "burst"
    else:
        m = re.search(r"loss\s+([\d.]+)%", netem_line)
        if m:
            result["loss_pct"] = float(m.group(1))
            result["loss_model"] = "uniform"

    m = re.search(r"rate\s+([\d.]+)([KMG]?)bit", netem_line, re.IGNORECASE)
    if m:
        val = float(m.group(1))
        unit = m.group(2).lower()
        if unit == "k":
            val /= 1000
        elif unit == "g":
            val *= 1000
        result["rate_mbit"] = val

    return result


@app.route("/deployed-config", methods=["GET"])
def deployed_config():
    """
    Read shaping straight off the interfaces via `tc qdisc show`, instead of
    trusting the in-memory `state` dict - `state` only reflects what this API
    process itself applied, and drifts from reality on a container recreate
    (tc resets, `state` doesn't survive either, but a stale client cache
    could) or a manual `tc` edit. This is the ground truth.

    delay_ms/jitter_ms are round-trip: custom shaping splits them in half
    across the downstream and upstream legs (see /custom), so they're summed
    back here. `distribution` isn't recoverable from `tc qdisc show` at all -
    tc doesn't echo the distribution table name back, only the delay/jitter
    values it produced - so it's reported from last-applied state as a
    best-effort hint, not read off the interface.
    """
    def qdisc_text(iface):
        result = subprocess.run(
            ["tc", "qdisc", "show", "dev", iface], capture_output=True, text=True,
        )
        return result.stdout

    downstream_iface = lan_ifaces()[0]
    downstream = _parse_netem(qdisc_text(downstream_iface))
    upstream = _parse_netem(qdisc_text(WAN_IFACE))

    loss_model = "burst" if downstream["loss_pct"] and downstream["loss_model"] == "burst" \
        else "burst" if upstream["loss_pct"] and upstream["loss_model"] == "burst" \
        else "uniform"

    return jsonify({
        "delay_ms": downstream["delay_ms"] + upstream["delay_ms"],
        "jitter_ms": downstream["jitter_ms"] + upstream["jitter_ms"],
        "distribution": state.get("custom_params", {}).get("distribution", "normal"),
        "downstream_loss_pct": downstream["loss_pct"],
        "upstream_loss_pct": upstream["loss_pct"],
        "loss_model": loss_model,
        "downstream_rate_mbit": downstream["rate_mbit"],
        "upstream_rate_mbit": upstream["rate_mbit"],
        "downstream_iface": downstream_iface,
        "upstream_iface": WAN_IFACE,
    })


@app.route("/custom", methods=["POST"])
def custom_profile():
    """
    Apply ad-hoc shaping instead of a named profile. Latency/jitter are
    round-trip values split symmetrically across both interfaces (see
    gateway/profiles/common.sh for why that's enough - no ingress
    redirection needed). Loss and bandwidth are one-directional by design,
    independently configurable per direction.

    Body (all optional, default 0/"uniform"/"normal"):
      delay_ms, jitter_ms, distribution ("normal"|"uniform"),
      downstream_loss_pct, upstream_loss_pct, loss_model ("uniform"|"burst"),
      downstream_rate_mbit, upstream_rate_mbit
    """
    data = request.get_json(silent=True) or {}

    try:
        delay_ms = float(data.get("delay_ms", 0))
        jitter_ms = float(data.get("jitter_ms", 0))
        distribution = data.get("distribution", "normal")
        downstream_loss_pct = float(data.get("downstream_loss_pct", 0))
        upstream_loss_pct = float(data.get("upstream_loss_pct", 0))
        loss_model = data.get("loss_model", "uniform")
        downstream_rate_mbit = float(data.get("downstream_rate_mbit", 0))
        upstream_rate_mbit = float(data.get("upstream_rate_mbit", 0))
    except (TypeError, ValueError) as e:
        return jsonify({"error": f"invalid parameter: {e}"}), 400

    if distribution not in ("normal", "uniform"):
        return jsonify({"error": "distribution must be 'normal' or 'uniform'"}), 400
    if loss_model not in ("uniform", "burst"):
        return jsonify({"error": "loss_model must be 'uniform' or 'burst'"}), 400

    half_delay = delay_ms / 2
    half_jitter = jitter_ms / 2

    downstream_args = build_netem_args(
        half_delay, half_jitter, distribution, downstream_loss_pct, loss_model, downstream_rate_mbit
    )
    upstream_args = build_netem_args(
        half_delay, half_jitter, distribution, upstream_loss_pct, loss_model, upstream_rate_mbit
    )

    try:
        for iface in lan_ifaces():
            wg_exempt = bool(WG_CARRIER_IFACE) and iface == WG_CARRIER_IFACE
            apply_shaping(iface, downstream_args, wg_exempt=wg_exempt)
        apply_shaping(WAN_IFACE, upstream_args)
    except subprocess.CalledProcessError as e:
        return jsonify({"error": (e.stderr or str(e)).strip()}), 500

    state["active_profile"] = "custom"
    state["switched_at"] = time.time()
    state["custom_params"] = data

    print(f"PROFILE_SWITCH profile=custom ts={state['switched_at']}", flush=True)

    return jsonify(state)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=9000)
