"""Account-free moderation helpers for PennyMe user-generated content.

New clients send a random installation identifier with contributions. PennyMe
stores only a one-way digest of that identifier. Content submitted without an
installation identifier receives a content-scoped legacy ID, allowing older app
versions to keep contributing without assigning them a persistent identity.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import tempfile
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Mapping, Optional, TypedDict

_BANNED_WORDS = {
    "asshole",
    "bastard",
    "bitch",
    "cunt",
    "fuck",
    "fucking",
    "motherfucker",
    "naked",
    "nudes",
    "porn",
    "porno",
    "pornography",
    "pussy",
    "retard",
    "slut",
    "whore",
}

_THREAT_PHRASES = (
    "attack you",
    "beat you",
    "find where you live",
    "hurt you",
    "i know where you live",
    "i will find you",
    "i will kill",
    "i will shoot",
    "i will stab",
    "i'll find you",
    "i'll kill",
    "i'll shoot",
    "i'll stab",
    "kill you",
    "shoot you",
    "stab you",
)

_VALID_TARGET_KINDS = {"comment", "image", "machine"}
_VALID_REASONS = {
    "harassment",
    "hate",
    "other",
    "sexual_content",
    "spam_scam",
    "violence",
}


class ResolvedContent(TypedDict):
    """Private attribution resolved for one piece of public content.

    Attributes:
        contributor_id: Internal digest identifying the content contributor.
    """

    contributor_id: str


class ModerationReport(TypedDict):
    """Private fields recorded for one user-submitted content report.

    Attributes:
        machine_id: Machine containing the reported content.
        content_key: Canonical kind-and-ID key for the content.
        reason: Controlled report reason selected in the app.
        block_contributor: Whether the reporter also requested a local block.
        contributor_id: Internal digest of the reported contributor.
        reporter_id: Internal digest of the reporting installation.
    """

    machine_id: str
    content_key: str
    reason: str
    block_contributor: bool
    contributor_id: str
    reporter_id: str


class ReportRequest(TypedDict):
    """Validated-shape fields read from a content-report request.

    Attributes:
        machine_id: Machine containing the reported content.
        target_kind: Reported content category.
        target_id: Category-specific content identifier.
        reason: Controlled report reason selected in the app.
        block_contributor: Whether the reporter also requested a local block.
    """

    machine_id: str
    target_kind: str
    target_id: str
    reason: str
    block_contributor: bool


def utc_now() -> str:
    """Return the current UTC timestamp in ISO 8601 format.

    Returns:
        An offset-aware ISO 8601 timestamp string.
    """
    return datetime.now(timezone.utc).isoformat()


def text_block_reason(*values: str) -> Optional[str]:
    """Check submitted text for the small local objectionable-content filter.

    Args:
        *values: Text fields belonging to one submission. Empty strings are
            allowed and all fields are checked together.

    Returns:
        A user-facing rejection message when a banned word or threat is found;
        otherwise, ``None``.
    """
    normalized = "\n".join(value or "" for value in values).casefold()
    tokens = set(re.findall(r"[\w']+", normalized, flags=re.UNICODE))
    if tokens.intersection(_BANNED_WORDS):
        return "This text contains language that is not allowed. Please edit it and try again."
    if any(phrase in normalized for phrase in _THREAT_PHRASES):
        return "This text appears to contain a threat. Please edit it and try again."
    return None


def validate_report(target_kind: str, reason: str) -> Optional[str]:
    """Validate the controlled values accepted by the report endpoint.

    Args:
        target_kind: Reported content category, such as ``image`` or ``comment``.
        reason: Machine-readable report reason sent by the iOS client.

    Returns:
        A user-facing validation error, or ``None`` when both values are valid.
    """
    if target_kind not in _VALID_TARGET_KINDS:
        return "Unknown content type"
    if reason not in _VALID_REASONS:
        return "Unknown report reason"
    return None


def parse_report_request(payload: Mapping[str, Any]) -> ReportRequest:
    """Extract supported fields from a content-report request.

    Unknown fields are intentionally ignored so requests produced by older app
    versions remain compatible with the current backend.

    Args:
        payload: Decoded JSON or form fields submitted to the report endpoint.

    Returns:
        Normalized report fields with strings trimmed and the block flag
        converted to a boolean.
    """
    block_contributor = payload.get("block_contributor", False)
    if isinstance(block_contributor, str):
        block_contributor = block_contributor.casefold() in {"1", "true", "yes"}
    return {
        "machine_id": str(payload.get("machine_id", "")).strip(),
        "target_kind": str(payload.get("target_kind", "")).strip(),
        "target_id": str(payload.get("target_id", "")).strip(),
        "reason": str(payload.get("reason", "")).strip(),
        "block_contributor": bool(block_contributor),
    }


class ModerationStore:
    """Store private content attribution and an append-only moderation log.

    Attributes:
        attribution_path: JSON file mapping machine/content keys to contributors.
        reports_path: JSON Lines file containing submitted moderation reports.
    """

    def __init__(
        self,
        attribution_path: Path,
        reports_path: Path,
    ) -> None:
        """Initialize the store with explicit filesystem locations.

        Args:
            attribution_path: Destination for the private attribution JSON file.
            reports_path: Destination for the append-only report JSONL file.
        """
        self.attribution_path = Path(attribution_path)
        self.reports_path = Path(reports_path)
        self._lock = threading.Lock()
        self._attribution_cache: Optional[Dict[str, Dict[str, Any]]] = None
        self._attribution_mtime_ns: Optional[int] = None

    @staticmethod
    def content_key(target_kind: str, target_id: str) -> str:
        """Build the canonical key for a reportable content item.

        Args:
            target_kind: Content category, for example ``image`` or ``comment``.
            target_id: Category-specific identifier, such as ``coin_0``.

        Returns:
            A stable key in ``<kind>:<identifier>`` format.
        """
        return f"{target_kind}:{target_id}"

    @staticmethod
    def contributor_id(anonymous_id: str) -> Optional[str]:
        """Derive an internal contributor ID from an installation identifier.

        Args:
            anonymous_id: Random installation UUID supplied by the iOS client.

        Returns:
            A 32-character one-way digest, or ``None`` when the client did not
            provide an installation identifier.
        """
        normalized_id = (anonymous_id or "").strip()
        if not normalized_id:
            return None
        digest = hashlib.sha256(f"device:{normalized_id}".encode("utf-8")).hexdigest()
        return digest[:32]

    def legacy_content_id(self, machine_id: str, content_key: str) -> str:
        """Create a stable identity that applies to one legacy content item only.

        Args:
            machine_id: Penny machine containing the content.
            content_key: Canonical content key returned by :meth:`content_key`.

        Returns:
            A deterministic content-scoped identifier prefixed with ``legacy-``.
        """
        value = f"legacy:{machine_id}:{content_key}"
        return "legacy-" + hashlib.sha256(value.encode("utf-8")).hexdigest()[:24]

    def block_id(self, contributor_id: str, viewer_id: str) -> str:
        """Create a stable contributor pseudonym scoped to one viewing device.

        Args:
            contributor_id: Private internal contributor digest for the author.
            viewer_id: Private internal contributor digest for the viewing device.

        Returns:
            A 32-character pseudonym suitable for device-local block storage.
        """
        value = f"block:{viewer_id}:{contributor_id}"
        return hashlib.sha256(value.encode("utf-8")).hexdigest()[:32]

    def record_content(
        self,
        machine_id: str,
        content_key: str,
        anonymous_id: str,
    ) -> str:
        """Associate one public contribution with its private author metadata.

        Args:
            machine_id: Penny machine receiving the contribution.
            content_key: Canonical content key, such as ``image:coin_0``.
            anonymous_id: Random installation UUID supplied by the client.

        Returns:
            The internal contributor digest. When ``anonymous_id`` is absent,
            this is a legacy ID unique to the individual content item.

        Raises:
            OSError: If the attribution file cannot be written atomically.
            TypeError: If the attribution data cannot be serialized as JSON.
        """
        contributor_id = self.contributor_id(anonymous_id)
        if contributor_id is None:
            contributor_id = self.legacy_content_id(str(machine_id), content_key)
        entry = {
            "contributor_id": contributor_id,
            "updated_at": utc_now(),
        }
        with self._lock:
            current = self._read_attribution()
            data = dict(current)
            existing_machine = current.get(str(machine_id), {})
            machine = (
                dict(existing_machine) if isinstance(existing_machine, dict) else {}
            )
            data[str(machine_id)] = machine
            machine[content_key] = entry
            self._atomic_write_json(self.attribution_path, data)
        return contributor_id

    def manifest(self, machine_id: str, viewer_id: str) -> Dict[str, str]:
        """Return content-owner pseudonyms safe to expose to one viewer.

        Args:
            machine_id: Penny machine whose content is being displayed.
            viewer_id: Internal contributor digest of the requesting installation.

        Returns:
            A mapping from content keys to viewer-scoped block pseudonyms. Raw
            installation IDs and internal contributor IDs are excluded.
        """
        with self._lock:
            machine = self._read_attribution().get(str(machine_id), {})
        manifest: Dict[str, str] = {}
        for key, value in machine.items():
            if isinstance(value, dict) and value.get("contributor_id"):
                manifest[key] = self.block_id(str(value["contributor_id"]), viewer_id)
            elif isinstance(value, str):
                # Backward compatibility if an early deployment stored only IDs.
                manifest[key] = self.block_id(value, viewer_id)
        return manifest

    def listing_manifest(self, viewer_id: str) -> Dict[str, str]:
        """Return owners for all user-contributed machine listings.

        The attribution JSON is cached by :meth:`_read_attribution`, so this
        global pass does not repeatedly parse the file. Each machine contributes
        at most one entry to the response.

        Args:
            viewer_id: Internal contributor digest of the requesting installation.

        Returns:
            A mapping from machine IDs to viewer-scoped block pseudonyms. Machines
            without attributed listing content are omitted.
        """
        with self._lock:
            attribution = self._read_attribution()

        manifest: Dict[str, str] = {}
        listing_key = self.content_key("machine", "listing")
        for machine_id, machine in attribution.items():
            if not isinstance(machine, dict):
                continue
            value = machine.get(listing_key)
            if isinstance(value, dict) and value.get("contributor_id"):
                manifest[str(machine_id)] = self.block_id(
                    str(value["contributor_id"]), viewer_id
                )
            elif isinstance(value, str):
                manifest[str(machine_id)] = self.block_id(value, viewer_id)
        return manifest

    def resolve_content(self, machine_id: str, content_key: str) -> ResolvedContent:
        """Resolve private author metadata for a reportable content item.

        Args:
            machine_id: Penny machine containing the reported content.
            content_key: Canonical key of the reported content.

        Returns:
            A dictionary containing the internal ``contributor_id``. Unknown
            content receives a stable, content-scoped legacy contributor ID.
        """
        with self._lock:
            value = self._read_attribution().get(str(machine_id), {}).get(content_key)
        if isinstance(value, dict) and value.get("contributor_id"):
            return {"contributor_id": str(value["contributor_id"])}
        if isinstance(value, str):
            return {"contributor_id": value}
        return {
            "contributor_id": self.legacy_content_id(str(machine_id), content_key),
        }

    def record_report(self, report: ModerationReport) -> None:
        """Append a timestamped moderation report to the JSON Lines log.

        Args:
            report: JSON-serializable report fields collected by the endpoint.

        Raises:
            OSError: If the report log directory or file cannot be written.
            TypeError: If ``report`` contains values that JSON cannot serialize.
        """
        timestamped_report: Dict[str, Any] = {**report, "created_at": utc_now()}
        self.reports_path.parent.mkdir(parents=True, exist_ok=True)
        line = json.dumps(timestamped_report, ensure_ascii=False, sort_keys=True)
        with self._lock:
            with self.reports_path.open("a", encoding="utf-8") as outfile:
                outfile.write(line + "\n")

    def _read_attribution(self) -> Dict[str, Dict[str, Any]]:
        """Return the private attribution mapping, reloading only when changed.

        Returns:
            The stored machine-to-content attribution mapping. A missing,
            malformed, or non-object JSON file is treated as an empty mapping.
            Repeated reads reuse an in-memory cache while the file modification
            timestamp remains unchanged.
        """
        try:
            mtime_ns = self.attribution_path.stat().st_mtime_ns
        except FileNotFoundError:
            self._attribution_cache = {}
            self._attribution_mtime_ns = None
            return self._attribution_cache

        if (
            self._attribution_cache is not None
            and self._attribution_mtime_ns == mtime_ns
        ):
            return self._attribution_cache

        try:
            with self.attribution_path.open("r", encoding="utf-8") as infile:
                value = json.load(infile)
                data = value if isinstance(value, dict) else {}
        except FileNotFoundError:
            self._attribution_cache = {}
            self._attribution_mtime_ns = None
            return self._attribution_cache
        except json.JSONDecodeError:
            data = {}

        self._attribution_cache = data
        self._attribution_mtime_ns = mtime_ns
        return data

    def _atomic_write_json(self, path: Path, value: Dict[str, Any]) -> None:
        """Replace a JSON file atomically using a sibling temporary file.

        Args:
            path: Destination JSON path.
            value: JSON-serializable object to write.

        Raises:
            OSError: If the directory, temporary file, or replacement operation
                fails.
            TypeError: If ``value`` cannot be serialized as JSON.
        """
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary_name = tempfile.mkstemp(dir=str(path.parent), prefix=path.name)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as outfile:
                json.dump(value, outfile, ensure_ascii=False, indent=2, sort_keys=True)
                outfile.write("\n")
            os.replace(temporary_name, path)
            if path == self.attribution_path:
                self._attribution_cache = value
                self._attribution_mtime_ns = path.stat().st_mtime_ns
        except Exception:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass
            raise
