#!/usr/bin/env -S uv run --script
# /// script
# dependencies = [
#   "flask",
# ]
# ///

"""iMessage Search — A search interface for Apple Messages."""

import datetime
import os
import re
import sqlite3
import sys
import threading
import webbrowser
from pathlib import Path

from flask import Flask, jsonify, request, send_file

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
APPLE_EPOCH_OFFSET = 978307200  # seconds between Unix epoch and 2001-01-01
DB_PATH = Path.home() / "Library" / "Messages" / "chat.db"
PER_PAGE = 50
CONTEXT_SIZE = 5

# ---------------------------------------------------------------------------
# Contact resolution
# ---------------------------------------------------------------------------
def normalize_phone(raw: str) -> str:
    digits = re.sub(r"\D", "", raw)
    if len(digits) > 10 and digits.startswith("1"):
        digits = digits[1:]
    return digits


def build_contact_lookup() -> dict[str, str]:
    """Read contacts directly from the macOS AddressBook SQLite databases."""
    ab_base = Path.home() / "Library" / "Application Support" / "AddressBook"
    db_paths = list(ab_base.glob("Sources/*/AddressBook-v22.abcddb"))
    # Also include the top-level DB
    top_db = ab_base / "AddressBook-v22.abcddb"
    if top_db.exists():
        db_paths.append(top_db)

    if not db_paths:
        print("  No AddressBook databases found.")
        return {}

    lookup = {}
    for db_path in db_paths:
        try:
            conn = sqlite3.connect(f"file:{db_path}?mode=ro&immutable=1", uri=True)
            # Phone numbers
            for row in conn.execute("""
                SELECT r.ZFIRSTNAME, r.ZLASTNAME, r.ZNICKNAME, r.ZORGANIZATION,
                       p.ZFULLNUMBER
                FROM ZABCDRECORD r
                JOIN ZABCDPHONENUMBER p ON p.ZOWNER = r.Z_PK
            """).fetchall():
                first, last, nick, org, phone = row
                name = f"{first or ''} {last or ''}".strip()
                if not name:
                    name = nick or org or ""
                if name and phone:
                    normed = normalize_phone(phone)
                    if normed:
                        lookup[normed] = name

            # Email addresses
            for row in conn.execute("""
                SELECT r.ZFIRSTNAME, r.ZLASTNAME, r.ZNICKNAME, r.ZORGANIZATION,
                       e.ZADDRESS
                FROM ZABCDRECORD r
                JOIN ZABCDEMAILADDRESS e ON e.ZOWNER = r.Z_PK
            """).fetchall():
                first, last, nick, org, email = row
                name = f"{first or ''} {last or ''}".strip()
                if not name:
                    name = nick or org or ""
                if name and email:
                    lookup[email.lower()] = name

            conn.close()
        except Exception as e:
            print(f"  Warning: could not read {db_path.name}: {e}")
            continue

    return lookup


def resolve_handle(handle_id: str, contact_lookup: dict) -> str:
    if not handle_id:
        return "Unknown"
    if "@" in handle_id:
        return contact_lookup.get(handle_id.lower(), handle_id)
    return contact_lookup.get(normalize_phone(handle_id), handle_id)


# ---------------------------------------------------------------------------
# attributedBody parsing
# ---------------------------------------------------------------------------
def extract_text_from_attributed_body(blob: bytes) -> str | None:
    if not blob:
        return None
    MARKER = b"\x01\x2b"
    idx = blob.find(MARKER)
    if idx == -1:
        return None
    pos = idx + len(MARKER)
    if pos >= len(blob):
        return None
    length_byte = blob[pos]
    pos += 1
    if length_byte < 0x80:
        text_length = length_byte
    else:
        num_bytes = (length_byte - 0x80) + 1
        if pos + num_bytes > len(blob):
            return None
        text_length = int.from_bytes(blob[pos:pos + num_bytes], "little")
        pos += num_bytes
    if pos + text_length > len(blob):
        end = blob.find(b"\x86\x84", pos)
        if end == -1:
            return None
        text_bytes = blob[pos:end]
    else:
        text_bytes = blob[pos:pos + text_length]
    try:
        text = text_bytes.decode("utf-8")
    except UnicodeDecodeError:
        text = text_bytes.decode("utf-8", errors="replace")
    return text.replace("\ufffc", "").strip() or None


# ---------------------------------------------------------------------------
# Date utilities
# ---------------------------------------------------------------------------
def apple_ns_to_iso(ns):
    if not ns:
        return None
    ts = ns / 1_000_000_000 + APPLE_EPOCH_OFFSET
    return datetime.datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M")


def iso_to_apple_ns(iso: str) -> int:
    dt = datetime.datetime.strptime(iso, "%Y-%m-%d")
    return int((dt.timestamp() - APPLE_EPOCH_OFFSET) * 1_000_000_000)


# ---------------------------------------------------------------------------
# FTS5 query preprocessing
# ---------------------------------------------------------------------------
def preprocess_fts_query(q: str) -> str:
    """Transform user query into valid FTS5 syntax."""
    # Convert -term to NOT term
    q = re.sub(r"(?:^|\s)-(\w+)", r" NOT \1", q)
    return q.strip()


# ---------------------------------------------------------------------------
# Database initialization
# ---------------------------------------------------------------------------
def init_db():
    db_path_str = str(DB_PATH.resolve())
    conn = sqlite3.connect("file::memory:", uri=True, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute(f"ATTACH DATABASE 'file:{db_path_str}?mode=ro' AS chatdb")

    # Register REGEXP function for regex searches
    def _regexp(pattern, string):
        if string is None:
            return False
        try:
            return bool(re.search(pattern, string, re.IGNORECASE))
        except re.error:
            return False
    conn.create_function("REGEXP", 2, _regexp)

    # Create in-memory tables for search
    conn.execute("CREATE TABLE message_text (rowid INTEGER PRIMARY KEY, text TEXT NOT NULL)")
    conn.execute("""
        CREATE VIRTUAL TABLE message_fts USING fts5(
            text, content='', content_rowid='rowid'
        )
    """)

    # Populate from chat.db
    rows = conn.execute(
        "SELECT ROWID, text, attributedBody FROM chatdb.message"
    ).fetchall()

    count = 0
    for row in rows:
        rowid, text, body = row[0], row[1], row[2]
        if not text and body:
            text = extract_text_from_attributed_body(body)
        if text:
            text = text.replace("\ufffc", "").strip()
            if text:
                conn.execute("INSERT INTO message_text(rowid, text) VALUES (?, ?)", (rowid, text))
                conn.execute("INSERT INTO message_fts(rowid, text) VALUES (?, ?)", (rowid, text))
                count += 1

    conn.commit()
    return conn, count


# ---------------------------------------------------------------------------
# Application factory
# ---------------------------------------------------------------------------
def create_app():
    print("iMessage Search")
    print("=" * 40)

    print("Loading contacts...")
    contacts = build_contact_lookup()
    print(f"  {len(contacts)} contact mappings loaded")

    print("Indexing messages...")
    conn, msg_count = init_db()
    print(f"  {msg_count} messages indexed")

    # Build handle name cache: handle ROWID -> {id, name}
    handles = {}
    for row in conn.execute("SELECT ROWID, id FROM chatdb.handle"):
        hid = row[0]
        handle_str = row[1]
        handles[hid] = {"id": handle_str, "name": resolve_handle(handle_str, contacts)}

    # Build chat cache: chat ROWID -> {name, is_group, ...}
    chats = {}
    for row in conn.execute("""
        SELECT c.ROWID, c.display_name, c.chat_identifier,
               GROUP_CONCAT(h.id, '|||') as members
        FROM chatdb.chat c
        LEFT JOIN chatdb.chat_handle_join chj ON c.ROWID = chj.chat_id
        LEFT JOIN chatdb.handle h ON chj.handle_id = h.ROWID
        GROUP BY c.ROWID
    """):
        cid, display_name, chat_id, members = row[0], row[1], row[2], row[3]
        member_list = members.split("|||") if members else []
        is_group = bool(display_name) or len(member_list) > 1
        # Resolve member names for group chats
        member_names = [resolve_handle(m, contacts) for m in member_list if m]
        if display_name:
            name = display_name
        elif is_group and member_names:
            # Show resolved member names instead of "chat123456"
            name = ", ".join(sorted(member_names))
        elif chat_id:
            name = resolve_handle(chat_id, contacts)
        else:
            name = "Unknown Chat"
        chats[cid] = {"id": cid, "name": name, "is_group": is_group, "identifier": chat_id}

    app = Flask(__name__)

    def message_to_dict(row):
        text = row["text"]
        if not text:
            body = row["attributedBody"] if "attributedBody" in row.keys() else None
            if body:
                text = extract_text_from_attributed_body(body)
        text = (text or "").replace("\ufffc", "").strip()

        handle_rowid = row["handle_id"]
        hinfo = handles.get(handle_rowid, {"id": "", "name": "Unknown"})
        chat_id = row["chat_id"]
        cinfo = chats.get(chat_id, {"name": "Unknown", "is_group": False})
        sender = "Me" if row["is_from_me"] else hinfo["name"]

        return {
            "id": row["message_id"],
            "text": text,
            "is_from_me": bool(row["is_from_me"]),
            "date": apple_ns_to_iso(row["date"]),
            "sender": sender,
            "handle": hinfo["id"],
            "chat_id": chat_id,
            "chat_name": cinfo["name"],
            "is_group": cinfo["is_group"],
            "has_attachments": bool(row["cache_has_attachments"]),
        }

    @app.route("/")
    def index():
        return HTML_TEMPLATE

    @app.route("/api/search")
    def search():
        q = request.args.get("q", "").strip()
        contact_filter = request.args.get("contact", "").strip()
        date_from = request.args.get("date_from", "").strip()
        date_to = request.args.get("date_to", "").strip()
        direction = request.args.get("direction", "all")
        chat_id_filter = request.args.get("chat_id", "")
        use_regex = request.args.get("regex", "0") == "1"
        page = int(request.args.get("page", "1"))

        if not q and not contact_filter and not date_from and not date_to and not chat_id_filter:
            return jsonify({"results": [], "total": 0, "page": 1})

        offset = (page - 1) * PER_PAGE
        params = []

        if q and not use_regex:
            # FTS5 search
            fts_query = preprocess_fts_query(q)
            base = """
                SELECT m.ROWID as message_id, m.text, m.attributedBody,
                       m.is_from_me, m.date, m.handle_id,
                       m.cache_has_attachments, cmj.chat_id
                FROM message_fts fts
                JOIN chatdb.message m ON fts.rowid = m.ROWID
                LEFT JOIN chatdb.chat_message_join cmj ON m.ROWID = cmj.message_id
                WHERE message_fts MATCH ?
            """
            params.append(fts_query)
        elif q and use_regex:
            # Regex search via message_text table
            base = """
                SELECT m.ROWID as message_id, m.text, m.attributedBody,
                       m.is_from_me, m.date, m.handle_id,
                       m.cache_has_attachments, cmj.chat_id
                FROM message_text mt
                JOIN chatdb.message m ON mt.rowid = m.ROWID
                LEFT JOIN chatdb.chat_message_join cmj ON m.ROWID = cmj.message_id
                WHERE mt.text REGEXP ?
            """
            params.append(q)
        else:
            # No text query — filter only
            base = """
                SELECT m.ROWID as message_id, m.text, m.attributedBody,
                       m.is_from_me, m.date, m.handle_id,
                       m.cache_has_attachments, cmj.chat_id
                FROM chatdb.message m
                LEFT JOIN chatdb.chat_message_join cmj ON m.ROWID = cmj.message_id
                WHERE 1=1
            """

        if direction == "sent":
            base += " AND m.is_from_me = 1"
        elif direction == "received":
            base += " AND m.is_from_me = 0"

        if date_from:
            base += " AND m.date >= ?"
            params.append(iso_to_apple_ns(date_from))
        if date_to:
            base += " AND m.date <= ?"
            dt = datetime.datetime.strptime(date_to, "%Y-%m-%d") + datetime.timedelta(days=1)
            params.append(int((dt.timestamp() - APPLE_EPOCH_OFFSET) * 1_000_000_000))

        if chat_id_filter:
            chat_ids = [int(x) for x in chat_id_filter.split(",")]
            placeholders = ",".join("?" * len(chat_ids))
            base += f" AND cmj.chat_id IN ({placeholders})"
            params.extend(chat_ids)

        if contact_filter:
            handle_ids = []
            cf_lower = contact_filter.lower()
            for hid, hinfo in handles.items():
                if cf_lower in hinfo["name"].lower() or cf_lower in hinfo["id"].lower():
                    handle_ids.append(hid)
            if handle_ids:
                placeholders = ",".join("?" * len(handle_ids))
                base += f" AND m.handle_id IN ({placeholders})"
                params.extend(handle_ids)
            else:
                return jsonify({"results": [], "total": 0, "page": page})

        try:
            total = conn.execute(f"SELECT COUNT(*) FROM ({base})", params).fetchone()[0]
        except Exception as e:
            return jsonify({"error": str(e)}), 400

        results_sql = base + " ORDER BY m.date DESC LIMIT ? OFFSET ?"
        params.extend([PER_PAGE, offset])

        try:
            rows = conn.execute(results_sql, params).fetchall()
        except Exception as e:
            return jsonify({"error": str(e)}), 400

        results = [message_to_dict(row) for row in rows]

        return jsonify({
            "results": results,
            "total": total,
            "page": page,
            "per_page": PER_PAGE,
        })

    @app.route("/api/context/<int:message_id>")
    def get_context(message_id):
        n = int(request.args.get("n", str(CONTEXT_SIZE)))

        row = conn.execute("""
            SELECT chat_id FROM chatdb.chat_message_join WHERE message_id = ? LIMIT 1
        """, (message_id,)).fetchone()
        if not row:
            return jsonify({"messages": []})

        chat_id = row[0]
        target_date = conn.execute(
            "SELECT date FROM chatdb.message WHERE ROWID = ?", (message_id,)
        ).fetchone()[0]

        before = conn.execute("""
            SELECT m.ROWID as message_id, m.text, m.attributedBody,
                   m.is_from_me, m.date, m.handle_id,
                   m.cache_has_attachments, ? as chat_id
            FROM chatdb.chat_message_join cmj
            JOIN chatdb.message m ON cmj.message_id = m.ROWID
            WHERE cmj.chat_id = ? AND m.date <= ?
            ORDER BY m.date DESC LIMIT ?
        """, (chat_id, chat_id, target_date, n + 1)).fetchall()

        after = conn.execute("""
            SELECT m.ROWID as message_id, m.text, m.attributedBody,
                   m.is_from_me, m.date, m.handle_id,
                   m.cache_has_attachments, ? as chat_id
            FROM chatdb.chat_message_join cmj
            JOIN chatdb.message m ON cmj.message_id = m.ROWID
            WHERE cmj.chat_id = ? AND m.date > ?
            ORDER BY m.date ASC LIMIT ?
        """, (chat_id, chat_id, target_date, n)).fetchall()

        all_msgs = list(reversed(before)) + list(after)
        seen = set()
        result = []
        for msg_row in all_msgs:
            mid = msg_row["message_id"]
            if mid in seen:
                continue
            seen.add(mid)
            d = message_to_dict(msg_row)
            d["is_match"] = mid == message_id
            result.append(d)

        return jsonify({"messages": result})

    @app.route("/api/contacts")
    def list_contacts():
        # Deduplicate by resolved name, collecting all handle IDs per name
        seen = {}
        for hid, hinfo in handles.items():
            name = hinfo["name"]
            key = name.lower()
            if key not in seen:
                seen[key] = {"name": name, "ids": set()}
            seen[key]["ids"].add(hinfo["id"])
        result = []
        for entry in sorted(seen.values(), key=lambda x: x["name"].lower()):
            # Show the name, with the raw ID as subtitle for unresolved ones
            is_resolved = entry["name"] != list(entry["ids"])[0]
            result.append({
                "name": entry["name"],
                "id": sorted(entry["ids"])[0],
                "is_resolved": is_resolved,
            })
        return jsonify(result)

    @app.route("/api/chats")
    def list_chats():
        # Deduplicate chats by name — merge multiple handles for same person
        seen = {}
        for cid, cinfo in chats.items():
            name = cinfo["name"]
            key = name.lower()
            if key not in seen:
                # Count messages in this chat
                count = conn.execute(
                    "SELECT COUNT(*) FROM chatdb.chat_message_join WHERE chat_id = ?",
                    (cid,)
                ).fetchone()[0]
                seen[key] = {"id": cid, "name": name, "is_group": cinfo["is_group"],
                             "msg_count": count, "chat_ids": [cid]}
            else:
                # Merge: add this chat_id, keep the one with more messages
                count = conn.execute(
                    "SELECT COUNT(*) FROM chatdb.chat_message_join WHERE chat_id = ?",
                    (cid,)
                ).fetchone()[0]
                seen[key]["chat_ids"].append(cid)
                seen[key]["msg_count"] += count
                if count > 0 and seen[key]["id"] != cid:
                    # Keep the chat_id with the most recent activity
                    pass  # first one is fine, search will match by contact name anyway

        result = []
        for entry in sorted(seen.values(), key=lambda x: x["name"].lower()):
            if entry["msg_count"] == 0:
                continue  # Skip empty chats
            # A chat is "resolved" if its name contains at least one known contact name
            name = entry["name"]
            is_resolved = any(
                cname in name for cname in contacts.values()
            ) if contacts else False
            result.append({
                "id": ",".join(str(c) for c in entry["chat_ids"]),
                "name": name,
                "is_group": entry["is_group"],
                "msg_count": entry["msg_count"],
                "is_resolved": is_resolved,
            })
        return jsonify(result)

    @app.route("/api/attachment/<int:attachment_id>")
    def serve_attachment(attachment_id):
        row = conn.execute("""
            SELECT filename, mime_type FROM chatdb.attachment WHERE ROWID = ?
        """, (attachment_id,)).fetchone()
        if not row or not row[0]:
            return "Not found", 404
        filepath = row[0].replace("~", str(Path.home()))
        if not os.path.exists(filepath):
            return "File not found", 404
        return send_file(filepath, mimetype=row[1])

    @app.route("/api/attachments/<int:message_id>")
    def message_attachments(message_id):
        rows = conn.execute("""
            SELECT a.ROWID, a.filename, a.mime_type, a.transfer_name, a.total_bytes
            FROM chatdb.attachment a
            JOIN chatdb.message_attachment_join maj ON a.ROWID = maj.attachment_id
            WHERE maj.message_id = ?
        """, (message_id,)).fetchall()
        result = []
        for row in rows:
            filepath = (row[1] or "").replace("~", str(Path.home()))
            result.append({
                "id": row[0],
                "filename": row[3] or os.path.basename(filepath),
                "mime_type": row[2],
                "size": row[4],
                "exists": os.path.exists(filepath) if filepath else False,
            })
        return jsonify(result)

    @app.route("/api/stats")
    def stats():
        total = conn.execute("SELECT COUNT(*) FROM message_text").fetchone()[0]
        date_range = conn.execute("""
            SELECT MIN(date), MAX(date) FROM chatdb.message WHERE date > 0
        """).fetchone()
        return jsonify({
            "total_messages": total,
            "total_contacts": len(handles),
            "total_chats": len(chats),
            "date_from": apple_ns_to_iso(date_range[0]),
            "date_to": apple_ns_to_iso(date_range[1]),
        })

    return app


# ---------------------------------------------------------------------------
# HTML Template
# ---------------------------------------------------------------------------
HTML_TEMPLATE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>iMessage Search</title>
<style>
:root {
    --blue: #007AFF;
    --blue-dark: #0056CC;
    --gray-bubble: #E9E9EB;
    --bg: #f5f5f7;
    --card: #ffffff;
    --text: #1d1d1f;
    --text-secondary: #86868b;
    --border: #d2d2d7;
    --highlight: #FDED72;
    --green: #34C759;
    --radius: 12px;
    --bubble-radius: 18px;
    --shadow: 0 1px 3px rgba(0,0,0,0.08), 0 1px 2px rgba(0,0,0,0.04);
    --shadow-lg: 0 4px 12px rgba(0,0,0,0.1);
}
@media (prefers-color-scheme: dark) {
    :root {
        --bg: #1c1c1e;
        --card: #2c2c2e;
        --text: #f5f5f7;
        --text-secondary: #98989d;
        --border: #48484a;
        --gray-bubble: #3a3a3c;
        --highlight: #a08a00;
        --shadow: 0 1px 3px rgba(0,0,0,0.3);
        --shadow-lg: 0 4px 12px rgba(0,0,0,0.4);
    }
}
* { margin: 0; padding: 0; box-sizing: border-box; }
body {
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
    background: var(--bg);
    color: var(--text);
    line-height: 1.5;
    min-height: 100vh;
}
.container {
    max-width: 800px;
    margin: 0 auto;
    padding: 20px;
}
header {
    text-align: center;
    padding: 30px 0 10px;
}
header h1 {
    font-size: 28px;
    font-weight: 700;
    letter-spacing: -0.5px;
}
header .stats {
    font-size: 13px;
    color: var(--text-secondary);
    margin-top: 4px;
}

/* Search bar */
.search-box {
    background: var(--card);
    border-radius: var(--radius);
    box-shadow: var(--shadow-lg);
    padding: 16px;
    margin: 20px 0 12px;
    position: sticky;
    top: 12px;
    z-index: 100;
}
.search-input-wrap {
    display: flex;
    align-items: center;
    background: var(--bg);
    border-radius: 10px;
    padding: 8px 14px;
    gap: 10px;
    border: 2px solid transparent;
    transition: border-color 0.2s;
}
.search-input-wrap:focus-within {
    border-color: var(--blue);
}
.search-input-wrap svg {
    flex-shrink: 0;
    color: var(--text-secondary);
}
#search-input {
    flex: 1;
    border: none;
    background: none;
    font-size: 16px;
    color: var(--text);
    outline: none;
    font-family: inherit;
}
#search-input::placeholder { color: var(--text-secondary); }

/* Filters */
.filters {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    margin-top: 12px;
    align-items: center;
}
.filter-group {
    display: flex;
    align-items: center;
    gap: 4px;
}
.filter-group label {
    font-size: 12px;
    font-weight: 600;
    color: var(--text-secondary);
    text-transform: uppercase;
    letter-spacing: 0.5px;
}
.filter-input {
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 5px 10px;
    font-size: 13px;
    background: var(--bg);
    color: var(--text);
    font-family: inherit;
    outline: none;
}
.filter-input:focus { border-color: var(--blue); }
select.filter-input { padding-right: 24px; }
input[type="date"].filter-input { max-width: 140px; }

/* Segmented control */
.segmented {
    display: flex;
    background: var(--bg);
    border-radius: 8px;
    padding: 2px;
    gap: 1px;
}
.segmented button {
    border: none;
    background: none;
    padding: 5px 12px;
    font-size: 12px;
    font-weight: 500;
    border-radius: 6px;
    cursor: pointer;
    color: var(--text-secondary);
    font-family: inherit;
    transition: all 0.15s;
}
.segmented button.active {
    background: var(--card);
    color: var(--text);
    box-shadow: 0 1px 2px rgba(0,0,0,0.08);
}

/* Toggles */
.toggle-group {
    display: flex;
    align-items: center;
    gap: 4px;
    font-size: 13px;
    color: var(--text-secondary);
    cursor: pointer;
    user-select: none;
}
.toggle-group input[type="checkbox"] {
    accent-color: var(--blue);
}

/* Results */
.results-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 16px 0 8px;
    font-size: 13px;
    color: var(--text-secondary);
}
.result-count { font-weight: 600; }

/* Conversation group */
.conversation-group {
    background: var(--card);
    border-radius: var(--radius);
    box-shadow: var(--shadow);
    margin-bottom: 12px;
    overflow: hidden;
}
.conversation-header {
    padding: 10px 16px;
    font-size: 13px;
    font-weight: 600;
    color: var(--text-secondary);
    border-bottom: 1px solid var(--border);
    display: flex;
    justify-content: space-between;
    align-items: center;
}
.conversation-header .chat-name {
    color: var(--text);
    font-size: 14px;
}
.messages-wrap {
    padding: 12px 16px;
}

/* Message bubbles */
.message-row {
    display: flex;
    flex-direction: column;
    margin-bottom: 6px;
    max-width: 85%;
    user-select: text;
}
.message-row.sent {
    align-self: flex-end;
    margin-left: auto;
    align-items: flex-end;
}
.message-row.received {
    align-self: flex-start;
    align-items: flex-start;
}
.message-row.context-msg {
    opacity: 0.5;
}
.message-row.context-msg:hover {
    opacity: 0.8;
}
.sender-name {
    font-size: 11px;
    font-weight: 600;
    color: var(--text-secondary);
    margin-bottom: 1px;
    padding: 0 8px;
}
.bubble {
    padding: 8px 14px;
    border-radius: var(--bubble-radius);
    font-size: 15px;
    line-height: 1.4;
    word-wrap: break-word;
    max-width: 100%;
    position: relative;
}
.sent .bubble {
    background: var(--blue);
    color: white;
    border-bottom-right-radius: 6px;
}
.received .bubble {
    background: var(--gray-bubble);
    color: var(--text);
    border-bottom-left-radius: 6px;
}
.message-meta {
    font-size: 11px;
    color: var(--text-secondary);
    margin-top: 2px;
    padding: 0 8px;
}
.sent .message-meta { text-align: right; }
mark {
    background: var(--highlight);
    color: inherit;
    border-radius: 2px;
    padding: 0 1px;
}
.sent mark {
    background: rgba(255,255,255,0.35);
    color: white;
}

/* Context area */
.context-container {
    border-top: 1px solid var(--border);
    padding: 12px 16px;
    display: none;
}
.context-container.visible { display: block; }
/* Context button */
.context-btn-wrap {
    text-align: center;
    margin: 2px 0 8px;
}
.context-btn {
    font-size: 11px;
    color: var(--text-secondary);
    background: none;
    border: none;
    cursor: pointer;
    font-family: inherit;
    padding: 2px 8px;
    border-radius: 4px;
}
.context-btn:hover { color: var(--blue); background: var(--bg); }

/* Inline attachments */
.attachment-inline img {
    max-width: 300px;
    max-height: 240px;
    border-radius: 10px;
    margin-top: 6px;
    display: block;
    cursor: pointer;
}
.attachment-inline a {
    display: inline-block;
    font-size: 12px;
    margin-top: 4px;
    color: var(--blue);
}
.sent .attachment-inline a { color: rgba(255,255,255,0.9); }
.attachment-inline .att-unavailable {
    font-size: 12px;
    color: var(--text-secondary);
    margin-top: 4px;
}

/* Links inside bubbles */
.bubble a {
    color: inherit;
    text-decoration: underline;
    text-decoration-color: rgba(255,255,255,0.5);
}
.received .bubble a { text-decoration-color: rgba(0,0,0,0.3); }
.bubble a:hover { text-decoration-color: inherit; }

/* Load more */
.load-more {
    display: block;
    width: 100%;
    padding: 14px;
    font-size: 14px;
    font-weight: 500;
    color: var(--blue);
    background: var(--card);
    border: none;
    border-radius: var(--radius);
    cursor: pointer;
    box-shadow: var(--shadow);
    margin: 12px 0 40px;
    font-family: inherit;
}
.load-more:hover { background: var(--bg); }

/* Loading & empty states */
.loading {
    text-align: center;
    padding: 40px;
    color: var(--text-secondary);
}
.spinner {
    display: inline-block;
    width: 20px; height: 20px;
    border: 2px solid var(--border);
    border-top-color: var(--blue);
    border-radius: 50%;
    animation: spin 0.6s linear infinite;
}
@keyframes spin { to { transform: rotate(360deg); } }
.empty-state {
    text-align: center;
    padding: 60px 20px;
    color: var(--text-secondary);
}
.empty-state .icon { font-size: 48px; margin-bottom: 12px; }
.error-msg {
    background: #FFF3F3;
    color: #D70015;
    padding: 12px 16px;
    border-radius: var(--radius);
    margin: 12px 0;
    font-size: 14px;
}
@media (prefers-color-scheme: dark) {
    .error-msg { background: #3a2020; color: #FF6B6B; }
}
</style>
</head>
<body>
<div class="container">
    <header>
        <h1>iMessage Search</h1>
        <div class="stats" id="stats-line"></div>
    </header>

    <div class="search-box">
        <form id="search-form" onsubmit="doSearch(); return false;">
            <div class="search-input-wrap">
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg>
                <input type="text" id="search-input" placeholder="Search messages..." autocomplete="off" autofocus>
            </div>
            <div class="filters">
                <div class="filter-group">
                    <label>Contact</label>
                    <select id="filter-contact" class="filter-input" style="max-width:200px">
                        <option value="">Anyone</option>
                    </select>
                    <label class="toggle-group" style="margin-left:2px">
                        <input type="checkbox" id="show-unknowns" onchange="rebuildContactDropdown()">
                        <span style="font-size:11px">Show unknowns</span>
                    </label>
                </div>
                <div class="filter-group">
                    <label>From</label>
                    <input type="date" id="filter-date-from" class="filter-input">
                </div>
                <div class="filter-group">
                    <label>To</label>
                    <input type="date" id="filter-date-to" class="filter-input">
                </div>
                <div class="segmented" id="direction-filter">
                    <button type="button" class="active" data-val="all">All</button>
                    <button type="button" data-val="sent">Sent</button>
                    <button type="button" data-val="received">Received</button>
                </div>
                <div class="filter-group">
                    <label>Chat</label>
                    <select id="filter-chat" class="filter-input" style="max-width:180px">
                        <option value="">All chats</option>
                    </select>
                    <label class="toggle-group" style="margin-left:2px">
                        <input type="checkbox" id="show-unknown-chats" onchange="rebuildChatDropdown()">
                        <span style="font-size:11px">Show unknowns</span>
                    </label>
                </div>
                <label class="toggle-group">
                    <input type="checkbox" id="regex-toggle">
                    Regex
                </label>
            </div>
        </form>
    </div>

    <div class="results-header" id="results-header" style="display:none">
        <span class="result-count" id="result-count"></span>
        <span id="search-time"></span>
    </div>

    <div id="results"></div>
    <button class="load-more" id="load-more" style="display:none" onclick="loadMore()">Load more results</button>
</div>

<script>
let currentPage = 1;
let currentTotal = 0;
let currentQuery = {};
let searchStartTime = 0;

// Load stats
fetch('/api/stats').then(r => r.json()).then(s => {
    document.getElementById('stats-line').textContent =
        s.total_messages.toLocaleString() + ' messages | ' +
        s.total_contacts.toLocaleString() + ' contacts | ' +
        s.date_from + ' to ' + s.date_to;
});

// Load contacts for dropdown — cache for rebuild
let allContacts = [];
fetch('/api/contacts').then(r => r.json()).then(contacts => {
    allContacts = contacts;
    rebuildContactDropdown();
});

function rebuildContactDropdown() {
    const sel = document.getElementById('filter-contact');
    const prev = sel.value;
    // Remove all optgroups but keep the first "Anyone" option
    while (sel.children.length > 1) sel.removeChild(sel.lastChild);

    const showUnknowns = document.getElementById('show-unknowns').checked;
    const resolved = allContacts.filter(c => c.is_resolved);
    const unresolved = allContacts.filter(c => !c.is_resolved);

    if (resolved.length > 0) {
        const grp = document.createElement('optgroup');
        grp.label = 'Contacts';
        resolved.forEach(c => {
            const opt = document.createElement('option');
            opt.value = c.name;
            opt.textContent = c.name;
            grp.appendChild(opt);
        });
        sel.appendChild(grp);
    }
    if (showUnknowns && unresolved.length > 0) {
        const grp = document.createElement('optgroup');
        grp.label = 'Other (' + unresolved.length + ')';
        unresolved.forEach(c => {
            const opt = document.createElement('option');
            opt.value = c.name;
            opt.textContent = c.name;
            grp.appendChild(opt);
        });
        sel.appendChild(grp);
    }
    sel.value = prev;
}

// Load chats for dropdown — cache for rebuild
let allChats = [];
fetch('/api/chats').then(r => r.json()).then(chats => {
    allChats = chats;
    rebuildChatDropdown();
});

function rebuildChatDropdown() {
    const sel = document.getElementById('filter-chat');
    const prev = sel.value;
    while (sel.children.length > 1) sel.removeChild(sel.lastChild);

    const showUnknowns = document.getElementById('show-unknown-chats').checked;
    const visible = showUnknowns ? allChats : allChats.filter(c => c.is_resolved);
    const oneOnOne = visible.filter(c => !c.is_group);
    const groups = visible.filter(c => c.is_group);

    if (oneOnOne.length > 0) {
        const grp = document.createElement('optgroup');
        grp.label = 'Direct Messages';
        oneOnOne.forEach(c => {
            const opt = document.createElement('option');
            opt.value = c.id;
            opt.textContent = c.name + ' (' + c.msg_count + ')';
            grp.appendChild(opt);
        });
        sel.appendChild(grp);
    }
    if (groups.length > 0) {
        const grp = document.createElement('optgroup');
        grp.label = 'Group Chats';
        groups.forEach(c => {
            const opt = document.createElement('option');
            opt.value = c.id;
            opt.textContent = c.name + ' (' + c.msg_count + ')';
            grp.appendChild(opt);
        });
        sel.appendChild(grp);
    }
    sel.value = prev;
}

// Direction filter
document.querySelectorAll('#direction-filter button').forEach(btn => {
    btn.addEventListener('click', () => {
        document.querySelectorAll('#direction-filter button').forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
    });
});

function getDirection() {
    return document.querySelector('#direction-filter button.active').dataset.val;
}

function escapeHtml(str) {
    const div = document.createElement('div');
    div.textContent = str;
    return div.innerHTML;
}

function highlightText(text, query) {
    if (!query || document.getElementById('regex-toggle').checked) {
        // For regex, try to highlight matches
        if (query && document.getElementById('regex-toggle').checked) {
            try {
                const re = new RegExp('(' + query + ')', 'gi');
                return escapeHtml(text).replace(re, '<mark>$1</mark>');
            } catch(e) { return escapeHtml(text); }
        }
        return escapeHtml(text);
    }
    // For FTS queries, highlight individual terms
    const terms = query.replace(/NOT\s+\w+/gi, '')
                       .replace(/\bOR\b/gi, '')
                       .replace(/["-]/g, '')
                       .split(/\s+/)
                       .filter(t => t.length > 0);
    let html = escapeHtml(text);
    terms.forEach(term => {
        const re = new RegExp('(' + term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + ')', 'gi');
        html = html.replace(re, '<mark>$1</mark>');
    });
    return html;
}

function linkify(html) {
    // Turn URLs into clickable links (applied after escaping/highlighting)
    return html.replace(/(https?:\/\/[^\s<]+)/g, '<a href="$1" target="_blank" rel="noopener">$1</a>');
}

function renderMessage(msg, query, isContext) {
    const cls = msg.is_from_me ? 'sent' : 'received';
    const contextCls = isContext ? ' context-msg' : '';
    let senderHtml = '';
    if (!msg.is_from_me && msg.is_group) {
        senderHtml = '<div class="sender-name">' + escapeHtml(msg.sender) + '</div>';
    }
    let textHtml = isContext ? escapeHtml(msg.text) : highlightText(msg.text, query);
    textHtml = linkify(textHtml);
    let attachHtml = '';
    if (msg.has_attachments) {
        attachHtml = '<div class="attachment-inline" data-msg-id="' + msg.id + '"></div>';
    }
    return '<div class="message-row ' + cls + contextCls + '">' +
        senderHtml +
        '<div class="bubble">' + textHtml + attachHtml + '</div>' +
        '<div class="message-meta">' + (msg.date || '') + '</div>' +
    '</div>';
}

function renderResults(data, append) {
    const container = document.getElementById('results');
    const header = document.getElementById('results-header');
    const loadMoreBtn = document.getElementById('load-more');

    if (!append) container.innerHTML = '';

    if (data.error) {
        container.innerHTML = '<div class="error-msg">' + escapeHtml(data.error) + '</div>';
        header.style.display = 'none';
        loadMoreBtn.style.display = 'none';
        return;
    }

    currentTotal = data.total;
    const elapsed = ((Date.now() - searchStartTime) / 1000).toFixed(2);
    document.getElementById('result-count').textContent = data.total.toLocaleString() + ' results';
    document.getElementById('search-time').textContent = elapsed + 's';
    header.style.display = 'flex';

    if (data.results.length === 0 && !append) {
        container.innerHTML = '<div class="empty-state"><div class="icon">&#128269;</div>No messages found</div>';
        loadMoreBtn.style.display = 'none';
        return;
    }

    // Group results by chat
    const groups = [];
    let currentGroup = null;
    data.results.forEach(msg => {
        if (!currentGroup || currentGroup.chat_id !== msg.chat_id) {
            currentGroup = { chat_id: msg.chat_id, chat_name: msg.chat_name, messages: [] };
            groups.push(currentGroup);
        }
        currentGroup.messages.push(msg);
    });

    const query = currentQuery.q || '';
    groups.forEach(group => {
        const div = document.createElement('div');
        div.className = 'conversation-group';
        let html = '<div class="conversation-header"><span class="chat-name">' +
            escapeHtml(group.chat_name) + '</span></div>';
        html += '<div class="messages-wrap">';
        group.messages.forEach(msg => {
            html += '<div data-msg-id="' + msg.id + '">';
            html += renderMessage(msg, query, false);
            html += '<div class="context-btn-wrap"><button class="context-btn" data-ctx-id="' + msg.id + '">Show context</button></div>';
            html += '</div>';
        });
        html += '</div>';
        div.innerHTML = html;
        container.appendChild(div);
    });

    const shown = data.page * data.per_page;
    loadMoreBtn.style.display = shown < data.total ? 'block' : 'none';

    // Auto-load inline attachments
    loadInlineAttachments(container);
}

function doSearch(page) {
    page = page || 1;
    currentPage = page;

    const q = document.getElementById('search-input').value.trim();
    const contact = document.getElementById('filter-contact').value.trim();
    const dateFrom = document.getElementById('filter-date-from').value;
    const dateTo = document.getElementById('filter-date-to').value;
    const direction = getDirection();
    const regex = document.getElementById('regex-toggle').checked ? '1' : '0';
    const chatId = document.getElementById('filter-chat').value;

    currentQuery = { q, contact, date_from: dateFrom, date_to: dateTo, direction, regex, chat_id: chatId };

    const params = new URLSearchParams();
    if (q) params.set('q', q);
    if (contact) params.set('contact', contact);
    if (dateFrom) params.set('date_from', dateFrom);
    if (dateTo) params.set('date_to', dateTo);
    if (direction !== 'all') params.set('direction', direction);
    if (regex === '1') params.set('regex', '1');
    if (chatId) params.set('chat_id', chatId);
    params.set('page', page);

    const container = document.getElementById('results');
    if (page === 1) {
        container.innerHTML = '<div class="loading"><div class="spinner"></div></div>';
        searchStartTime = Date.now();
    }

    fetch('/api/search?' + params.toString())
        .then(r => r.json())
        .then(data => renderResults(data, page > 1))
        .catch(err => {
            container.innerHTML = '<div class="error-msg">Search failed: ' + err.message + '</div>';
        });
}

function loadMore() {
    doSearch(currentPage + 1);
}

function toggleContext(el, messageId) {
    let ctxEl = el.querySelector('.context-container');
    if (ctxEl) {
        ctxEl.classList.toggle('visible');
        return;
    }
    // Load context
    fetch('/api/context/' + messageId + '?n=' + 5)
        .then(r => r.json())
        .then(data => {
            if (!data.messages || data.messages.length <= 1) return;
            ctxEl = document.createElement('div');
            ctxEl.className = 'context-container visible';
            let html = '<div style="font-size:11px;font-weight:600;color:var(--text-secondary);margin-bottom:8px;">Conversation context</div>';
            html += '<div class="messages-wrap" style="padding:0">';
            data.messages.forEach(msg => {
                const isMatch = msg.is_match;
                html += renderMessage(msg, isMatch ? (currentQuery.q || '') : '', !isMatch);
            });
            html += '</div>';
            ctxEl.innerHTML = html;
            el.appendChild(ctxEl);
            loadInlineAttachments(ctxEl);
        });
}

function loadInlineAttachments(container) {
    // Find all attachment placeholders and load them
    container.querySelectorAll('.attachment-inline[data-msg-id]').forEach(el => {
        const msgId = el.dataset.msgId;
        if (el.dataset.loaded) return;
        el.dataset.loaded = '1';
        fetch('/api/attachments/' + msgId)
            .then(r => r.json())
            .then(attachments => {
                let html = '';
                attachments.forEach(att => {
                    if (att.exists && att.mime_type && att.mime_type.startsWith('image/')) {
                        html += '<img src="/api/attachment/' + att.id + '" alt="' + escapeHtml(att.filename) + '" onclick="window.open(this.src)">';
                    } else if (att.exists) {
                        html += '<a href="/api/attachment/' + att.id + '" target="_blank">' + escapeHtml(att.filename) + '</a><br>';
                    } else {
                        html += '<span class="att-unavailable">' + escapeHtml(att.filename) + ' (unavailable)</span><br>';
                    }
                });
                el.innerHTML = html;
            });
    });
}

// Delegated click handler for context buttons
document.addEventListener('click', e => {
    const btn = e.target.closest('.context-btn[data-ctx-id]');
    if (btn) {
        const msgId = parseInt(btn.dataset.ctxId);
        const wrapper = btn.closest('[data-msg-id]');
        if (wrapper) toggleContext(wrapper, msgId);
    }
});

// Keyboard shortcut: Cmd+K to focus search
document.addEventListener('keydown', e => {
    if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
        e.preventDefault();
        document.getElementById('search-input').focus();
        document.getElementById('search-input').select();
    }
});
</script>
</body>
</html>
"""


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    if not DB_PATH.exists():
        print(f"Error: {DB_PATH} not found.")
        sys.exit(1)
    app = create_app()
    port = 8742
    print(f"\nStarting server at http://localhost:{port}")
    threading.Timer(1.0, lambda: webbrowser.open(f"http://localhost:{port}")).start()
    app.run(host="127.0.0.1", port=port, debug=False)
