# -*- coding: utf-8 -*-
"""Lightweight live session snapshots for refresh-time chat rendering."""
from __future__ import annotations

import json
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Sequence

from pydantic import BaseModel, Field, ValidationError

from agentscope_runtime.engine.schemas.agent_schemas import Message

from .session import sanitize_filename

logger = logging.getLogger(__name__)


class LiveSessionSnapshot(BaseModel):
    """Refresh-time snapshot for a running session."""

    session_id: str
    user_id: str
    updated_at: str = Field(
        default_factory=lambda: datetime.now(timezone.utc).isoformat(),
    )
    messages: list[Message] = Field(default_factory=list)


def merge_live_turn_messages(
    existing_messages: Sequence[Message],
    incoming_messages: Sequence[Message],
    original_id: str | None,
) -> list[Message]:
    """Merge the latest streamed message view into the current turn snapshot.

    AgentScope streaming may emit multiple chunks with the same original
    message id. Each chunk can represent the latest full view for that single
    streamed message, so we should replace only that message group while
    preserving earlier reasoning/tool messages from the same turn.
    """
    if not incoming_messages:
        return list(existing_messages)
    if not original_id:
        return [*existing_messages, *incoming_messages]

    merged = list(existing_messages)
    first_match_index: int | None = None
    filtered: list[Message] = []

    for message in merged:
        message_original_id = (getattr(message, "metadata", {}) or {}).get(
            "original_id"
        )
        if message_original_id == original_id:
            if first_match_index is None:
                first_match_index = len(filtered)
            continue
        filtered.append(message)

    if first_match_index is None:
        filtered.extend(incoming_messages)
        return filtered

    return [
        *filtered[:first_match_index],
        *incoming_messages,
        *filtered[first_match_index:],
    ]


def get_live_session_snapshot_path(
    workspace_dir: str | Path | None,
    session_id: str,
    user_id: str,
) -> Path | None:
    """Return the path for a session's live snapshot file."""
    if not workspace_dir or not session_id:
        return None

    runtime_dir = (
        Path(workspace_dir).expanduser() / ".runtime" / "live_sessions"
    )
    safe_sid = sanitize_filename(session_id)
    safe_uid = sanitize_filename(user_id) if user_id else ""
    filename = (
        f"{safe_uid}_{safe_sid}.json" if safe_uid else f"{safe_sid}.json"
    )
    return runtime_dir / filename


async def save_live_session_snapshot(
    workspace_dir: str | Path | None,
    session_id: str,
    user_id: str,
    messages: Sequence[Message],
) -> None:
    """Persist a lightweight live snapshot for refresh-time reads."""
    path = get_live_session_snapshot_path(workspace_dir, session_id, user_id)
    if path is None:
        return

    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        snapshot = LiveSessionSnapshot(
            session_id=session_id,
            user_id=user_id,
            messages=list(messages),
        )
        tmp_path = path.with_suffix(f"{path.suffix}.tmp")
        tmp_path.write_text(
            json.dumps(
                snapshot.model_dump(mode="json"),
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        tmp_path.replace(path)
    except Exception as exc:
        logger.warning(
            "Failed to save live session snapshot for %s: %s",
            session_id,
            exc,
        )


async def load_live_session_snapshot(
    workspace_dir: str | Path | None,
    session_id: str,
    user_id: str,
) -> LiveSessionSnapshot | None:
    """Load a live snapshot if one exists for the session."""
    path = get_live_session_snapshot_path(workspace_dir, session_id, user_id)
    if path is None or not path.exists():
        return None

    try:
        return LiveSessionSnapshot.model_validate_json(
            path.read_text(encoding="utf-8"),
        )
    except (OSError, ValidationError, json.JSONDecodeError) as exc:
        logger.warning(
            "Failed to load live session snapshot for %s: %s",
            session_id,
            exc,
        )
        return None


async def delete_live_session_snapshot(
    workspace_dir: str | Path | None,
    session_id: str,
    user_id: str,
) -> None:
    """Delete a live snapshot after the run finishes."""
    path = get_live_session_snapshot_path(workspace_dir, session_id, user_id)
    if path is None:
        return

    try:
        path.unlink(missing_ok=True)
    except Exception as exc:
        logger.warning(
            "Failed to delete live session snapshot for %s: %s",
            session_id,
            exc,
        )
