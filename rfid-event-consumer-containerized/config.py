"""
Configuration for the RFID event consumer worker.

Reads everything from environment variables so the same container
image runs unmodified locally (docker run --env-file ...) and in
Azure Container Apps (env vars set on the container app / revision).

Required env vars:
    SERVICEBUS_CONNECTION_STR   Service Bus namespace connection string
    TABLE_CONNECTION_STR        Storage account connection string

Optional env vars (sensible defaults match the existing deployment):
    QUEUE_NAME    default: rfid-events
    TABLE_NAME    default: rfidevents
"""

import os
from dataclasses import dataclass


class ConfigError(RuntimeError):
    """Raised when a required environment variable is missing."""


def _require(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise ConfigError(
            f"required environment variable '{name}' is not set. "
            f"Set it before starting the worker (see README / Dockerfile ENV)."
        )
    return value


@dataclass(frozen=True)
class Config:
    servicebus_connection_str: str
    table_connection_str: str
    queue_name: str = "rfid-events"
    table_name: str = "rfidevents"

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            servicebus_connection_str=_require("SERVICEBUS_CONNECTION_STR"),
            table_connection_str=_require("TABLE_CONNECTION_STR"),
            queue_name=os.environ.get("QUEUE_NAME", cls.queue_name),
            table_name=os.environ.get("TABLE_NAME", cls.table_name),
        )
