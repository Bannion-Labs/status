#!/usr/bin/env bash
#
# heartbeat-age.sh: opens or closes the "Scheduled work" incident from the age of heartbeat.json
# (observability spec #1, section 1.8, card O7).
#
# Upptime only checks that a URL answers. This reads the file and judges how old it is. The file is
# {"at":"<RFC 3339 UTC>"}, written by the agent after each schedule tick that finished without error (I10).
# Older than MAX_AGE_SECONDS (300), missing, or with an `at` it cannot read: the work is not running, so open
# the incident. Fresh: close it. An incident that is already open is never opened twice.
#
# Upptime touches this incident only when its own probe of the file changes state (it reads that the file
# answers, not how old it is). A file that went missing and came back stale is one such change: Upptime closes
# the incident because the file answers again, and the work is still down. So a stale file reopens an incident
# closed in the last REOPEN_SECONDS instead of opening a second one, and the outage stays one incident.
#
# It needs no secret beyond the workflow's own GITHUB_TOKEN, which gh reads.
#
# Inputs (environment):
#   HEARTBEAT_URL       where the file lives (required unless HEARTBEAT_FILE is set)
#   HEARTBEAT_FILE      read this local file instead of the URL; a path that does not exist means "missing" (tests)
#   MAX_AGE_SECONDS     default 300
#   REOPEN_SECONDS      reopen an incident closed this recently instead of opening a new one; default 900
#   NOW_EPOCH           the clock, in epoch seconds; default is the real one (tests)
#   GH                  the gh command; default gh (tests)
#   GITHUB_REPOSITORY   owner/name, which gh also reads itself
set -euo pipefail
# jq 1.6 reads an ISO time through the local zone, daylight saving and all, on some systems. UTC makes it exact.
export TZ=UTC

GH="${GH:-gh}"
MAX_AGE_SECONDS="${MAX_AGE_SECONDS:-300}"
REOPEN_SECONDS="${REOPEN_SECONDS:-900}"
NOW_EPOCH="${NOW_EPOCH:-$(date -u +%s)}"
SLUG="scheduled-work"
TITLE="🛑 Scheduled work is down"

# reason is empty when the file is fresh. Otherwise it is one plain sentence.
reason=""
body=""
if [ -n "${HEARTBEAT_FILE:-}" ]; then
  [ -f "$HEARTBEAT_FILE" ] && body="$(cat "$HEARTBEAT_FILE")" || reason="I could not find the heartbeat file."
else
  : "${HEARTBEAT_URL:?set HEARTBEAT_URL or HEARTBEAT_FILE}"
  # The query string keeps a cache from answering for the file. The agent also writes it with no-store.
  body="$(curl -fsS --max-time 20 "$HEARTBEAT_URL?t=$NOW_EPOCH" 2>/dev/null)" || reason="I could not find the heartbeat file."
fi

if [ -z "$reason" ]; then
  at="$(printf '%s' "$body" | jq -r '.at // empty' 2>/dev/null || true)"
  # jq reads whole seconds only, so drop any fraction. Java writes one when the instant has it.
  trimmed="$(printf '%s' "$at" | sed -E 's/\.[0-9]+Z$/Z/')"
  at_epoch="$(printf '%s' "$trimmed" | jq -R 'try fromdateiso8601 catch empty' 2>/dev/null || true)"
  if [ -z "$at_epoch" ]; then
    reason="I could not read the time in the heartbeat file."
  else
    age=$((NOW_EPOCH - at_epoch))
    if [ "$age" -gt "$MAX_AGE_SECONDS" ]; then
      reason="The last heartbeat is $((age / 60)) minutes old. It should be under $((MAX_AGE_SECONDS / 60))."
    elif [ "$age" -lt "-$MAX_AGE_SECONDS" ]; then
      reason="The heartbeat file says a time that has not happened yet."
    fi
  fi
fi

open_number="$("$GH" issue list --label status --label "$SLUG" --state open --json number --jq '.[0].number // empty')"

if [ -n "$reason" ]; then
  if [ -n "$open_number" ]; then
    echo "Scheduled work is still down. Incident #$open_number is already open. $reason"
  else
    # The newest closed incident, as "<number> <closedAt>", or nothing.
    last_closed="$("$GH" issue list --label status --label "$SLUG" --state closed --limit 1 --json number,closedAt \
      --jq '.[0] // empty | "\(.number) \(.closedAt)"')"
    closed_number="${last_closed%% *}"
    closed_epoch=""
    [ -n "$last_closed" ] && closed_epoch="$(printf '"%s"' "${last_closed#* }" | jq 'try fromdateiso8601 catch empty' 2>/dev/null || true)"
    if [ -n "$closed_epoch" ] && [ $((NOW_EPOCH - closed_epoch)) -le "$REOPEN_SECONDS" ]; then
      "$GH" issue reopen "$closed_number" --comment "Scheduled work is still not running. $reason"
      echo "Scheduled work is still down. I reopened incident #$closed_number. $reason"
    else
      "$GH" issue create --title "$TITLE" --label status --label "$SLUG" \
        --body "Scheduled work is not running. $reason"
      echo "Scheduled work is down. I opened an incident. $reason"
    fi
  fi
else
  if [ -n "$open_number" ]; then
    "$GH" issue close "$open_number" --comment "Scheduled work is running again. The heartbeat is fresh."
    echo "Scheduled work is back. I closed incident #$open_number."
  else
    echo "Scheduled work is running. The heartbeat is fresh."
  fi
fi
