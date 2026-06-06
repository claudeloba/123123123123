#!/usr/bin/env bash
printf "CODESPACE_FSMON_OK %s\n" "$(date -u +%FT%TZ)" >> /tmp/copilot-codespace-fsmon-marker
exit 0
