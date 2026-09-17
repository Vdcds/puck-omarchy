#!/usr/bin/env bash
# Puck's small local data store. It intentionally keeps everything in one
# human-readable JSON file: no account, daemon, or network connection needed.
set -euo pipefail

state_root="${XDG_STATE_HOME:-$HOME/.local/state}"
state_dir="$state_root/puck"
state_file="$state_dir/data.json"
lock_file="$state_dir/.lock"
legacy_state_file="$state_root/lumi/data.json"
mkdir -p "$state_dir"

default_state='{
  "version": 1,
  "todos": [],
  "links": [],
  "activity": {"water": 0, "waterDay": "", "waterToday": 0, "walk": 0, "headphones": 0, "lastNudge": 0, "lastNudgeType": "", "lastTodoPromptDay": "", "lastNightPromptDay": "", "volumeHighSince": 0, "lastVolumeAutoLowered": 0, "lastCodexAlert": 0}
}'

ensure_state() {
  (
    flock -x 9
    if [[ ! -s "$state_file" ]] || ! jq -e . "$state_file" >/dev/null 2>&1; then
      local temporary
      temporary="$(mktemp "$state_dir/.data.json.XXXXXX")"
      if [[ ! -e "$state_file" ]] && jq -e . "$legacy_state_file" >/dev/null 2>&1; then
        jq . "$legacy_state_file" > "$temporary"
      else
        printf '%s\n' "$default_state" > "$temporary"
      fi
      mv "$temporary" "$state_file"
    fi
  ) 9>"$lock_file"
}

write_state() {
  local filter="$1"
  shift
  (
    flock -x 9
    local temporary
    temporary="$(mktemp "$state_dir/.data.json.XXXXXX")"
    jq "$filter" "$@" "$state_file" > "$temporary"
    mv "$temporary" "$state_file"
  ) 9>"$lock_file"
}

id() { printf '%s-%s' "$(date +%s%N)" "$RANDOM"; }
pick() { local options=("$@"); printf '%s' "${options[RANDOM % ${#options[@]}]}"; }

# Codex writes a rate-limit snapshot into the local session history. This is
# the same data the CLI uses for its status display, but does not require a
# network request or account token. Missing / old session history is normal.
codex_status() {
  local session_root="$HOME/.codex/sessions" candidate record=""
  [[ -d "$session_root" ]] || { printf '%s\n' '{"available":false}'; return; }
  # A newly-created session has no token-count events yet. Walk the newest
  # few histories until we find a real snapshot instead of claiming "unknown".
  while IFS= read -r candidate; do
    [[ -f "$candidate" ]] || continue
    record="$(jq -c 'select(.type == "event_msg" and .payload.type == "token_count" and .payload.rate_limits) | {recordedAt: .timestamp, limits: .payload.rate_limits}' "$candidate" 2>/dev/null | tail -n 1)"
    [[ -n "$record" ]] && break
  done < <(find "$session_root" -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 24 | cut -d' ' -f2-)
  [[ -n "$record" ]] || { printf '%s\n' '{"available":false}'; return; }
  jq -c '{
    available: true,
    recordedAt,
    primary: (.limits.primary.used_percent // 0),
    secondary: (.limits.secondary.used_percent // 0),
    primaryReset: (.limits.primary.resets_at // 0),
    secondaryReset: (.limits.secondary.resets_at // 0),
    plan: (.limits.plan_type // "")
  }' <<<"$record"
}

summary() {
  local codex screensaver_active=false
  codex="$(codex_status)"
  pgrep -f '[o]rg.omarchy.screensaver' >/dev/null 2>&1 && screensaver_active=true
  jq --arg today "$(date +%F)" --argjson codex "$codex" --argjson screensaverActive "$screensaver_active" '
    . as $state |
    ($state.todos // []) as $todos |
    ($todos | map(select(.done | not))) as $open |
    ($todos | map(select(.done == true))) as $done |
    {
      todos: $todos,
      links: ($state.links // []),
      openCount: ($open | length),
      doneCount: ($done | length),
      totalCount: ($todos | length),
      doneToday: ($done | map(select(.completedAt // "" | startswith($today))) | length),
      activity: ($state.activity // {}),
      codex: $codex,
      screensaverActive: $screensaverActive,
      now: (now | floor)
    }
  ' "$state_file"
}

volume_check() {
  local now output volume muted high_since
  command -v wpctl >/dev/null 2>&1 || exit 0
  output="$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null || true)"
  volume="$(awk '/Volume:/ { print $2; exit }' <<<"$output")"
  muted="$(grep -c '\[MUTED\]' <<<"$output" || true)"
  [[ "$volume" =~ ^[0-9]+([.][0-9]+)?$ ]] || exit 0
  now="$(date +%s)"
  if [[ "$muted" != "0" ]] || ! awk -v volume="$volume" 'BEGIN { exit !(volume >= 0.95) }'; then
    write_state '.activity.volumeHighSince = 0'
    exit 0
  fi
  high_since="$(jq -r '.activity.volumeHighSince // 0' "$state_file")"
  if [[ "$high_since" == "0" ]]; then
    write_state '.activity.volumeHighSince = $now' --argjson now "$now"
    exit 0
  fi
  (( now - high_since < 1800 )) && exit 0
  wpctl set-volume @DEFAULT_AUDIO_SINK@ 70% >/dev/null 2>&1 || exit 0
  write_state '.activity.volumeHighSince = 0 | .activity.lastVolumeAutoLowered = $now' --argjson now "$now"
  jq -n '{type:"volume", title:"Puck saved your ears", body:"You stayed near full volume for 30 minutes, so I put it back at 70%. Tiny hearing-preservation intervention."}'
}

nudge() {
  local now hour today water walk ears nudge_gap=1800
  now="$(date +%s)"
  hour="$(date +%H | sed 's/^0//')"; hour="${hour:-0}"
  today="$(date +%F)"
  water="${1:-60}"; walk="${2:-120}"; ears="${3:-90}"
  local night_hour="${4:-20}"
  local last last_type
  last="$(jq -r '.activity.lastNudge // 0' "$state_file")"
  last_type="$(jq -r '.activity.lastNudgeType // ""' "$state_file")"
  (( now - last < nudge_gap )) && exit 0

  local type="" title="" body=""
  local last_water last_walk last_ears todo_prompt night_prompt codex_alert open_count done_today codex primary secondary
  last_water="$(jq -r '.activity.water // 0' "$state_file")"
  last_walk="$(jq -r '.activity.walk // 0' "$state_file")"
  last_ears="$(jq -r '.activity.headphones // 0' "$state_file")"
  todo_prompt="$(jq -r '.activity.lastTodoPromptDay // ""' "$state_file")"
  night_prompt="$(jq -r '.activity.lastNightPromptDay // ""' "$state_file")"
  codex_alert="$(jq -r '.activity.lastCodexAlert // 0' "$state_file")"
  open_count="$(jq '[.todos[]? | select(.done | not)] | length' "$state_file")"
  done_today="$(jq --arg today "$today" '[.todos[]? | select(.done == true and ((.completedAt // "") | startswith($today)))] | length' "$state_file")"
  codex="$(codex_status)"
  primary="$(jq -r '.primary // 0' <<<"$codex")"
  secondary="$(jq -r '.secondary // 0' <<<"$codex")"

  if (( now - codex_alert >= 3600 )) && awk -v p="$primary" -v s="$secondary" 'BEGIN { exit !(p >= 80 || s >= 80) }'; then
    type="codex"; title="Puck sees the meter climbing"; body="$(pick "Codex is at ${primary}% short / ${secondary}% long. Maybe save the galaxy-sized task for after a reset." "Codex is getting peckish: ${primary}% short / ${secondary}% long. Consider fewer heroic side quests." "Your Codex meter says ${primary}% short / ${secondary}% long. I believe in you. Your allowance is less certain.")"
    write_state '.activity.lastCodexAlert = $now' --argjson now "$now"
  elif (( now - last_water >= water * 60 )) && [[ "$last_type" != "water" ]]; then
    type="water"; title="Puck says: tiny sip?"; body="$(pick "Hydration check. You are not a houseplant, but the comparison is becoming uncomfortably useful." "Go find your water bottle. Your cells filed a polite complaint." "A tiny sip now, before you become a sentient raisin.")"
  elif (( now - last_walk >= walk * 60 )) && [[ "$last_type" != "walk" ]]; then
    type="walk"; title="Puck says: stretch your world"; body="$(pick "Stand up. Your chair has seen enough of you for one century." "A two-minute walk counts. Your legs are not decorative." "Please rotate your skeleton a little. The chair is getting possessive.")"
  elif (( now - last_ears >= ears * 60 )) && [[ "$last_type" != "headphones" ]]; then
    type="headphones"; title="Puck says: ears deserve softness"; body="$(pick "Turn it down a notch. Tinnitus is a terrible personal soundtrack." "Your ears requested less concert-hall energy." "Lower it a little. We are preserving the premium audio hardware attached to your head.")"
  elif (( open_count > 0 && done_today == 0 )) && [[ "$todo_prompt" != "$today" ]]; then
    type="todos"; title="Puck is checking in"; body="$(pick "You have ${open_count} open little promise(s). Did one get done?" "${open_count} tasks are still doing the world's tiniest haunting. Pick one." "I counted ${open_count} open task(s). I am not judging. I am blinking dramatically.")"
    write_state '.activity.lastTodoPromptDay = $today' --arg today "$today"
  elif (( hour >= night_hour )) && [[ "$night_prompt" != "$today" ]]; then
    type="nightlight"; title="Puck says: evening mode"; body="$(pick "If it feels right, turn on Night Light and let your eyes unwind." "It is evening. Your eyeballs would like the warm lamp setting now." "Night Light is waiting. Be kind to tomorrow's eyeballs.")"
    write_state '.activity.lastNightPromptDay = $today' --arg today "$today"
  fi

  if [[ -n "$type" ]]; then
    write_state '.activity.lastNudge = $now | .activity.lastNudgeType = $type' --argjson now "$now" --arg type "$type"
    jq -n --arg type "$type" --arg title "$title" --arg body "$body" '{type:$type,title:$title,body:$body}'
  fi
}

toggle_screensaver() {
  if ! command -v omarchy-launch-screensaver >/dev/null 2>&1; then
    jq -n '{ok:false,error:"Omarchy’s screensaver launcher is unavailable."}'
    return 0
  fi
  if pgrep -f '[o]rg.omarchy.screensaver' >/dev/null 2>&1; then
    # This is the same process identity the Omarchy screensaver itself uses
    # when it exits on keyboard or mouse input. SIGTERM runs its cleanup trap.
    pkill -f '[o]rg.omarchy.screensaver' >/dev/null 2>&1 || true
    for _ in {1..25}; do
      if ! pgrep -f '[o]rg.omarchy.screensaver' >/dev/null 2>&1; then
        jq -n '{ok:true,active:false}'
        return 0
      fi
      sleep 0.02
    done
    jq -n '{ok:false,error:"The fullscreen screensaver did not close."}'
    return 0
  fi
  # A deliberate click should work even when automatic idle screensavers are
  # disabled. The launcher still handles terminal compatibility and reports
  # its own useful notification when the desktop cannot host one.
  # The launcher waits for the terminal window to map. Confirming the mapped
  # screensaver process here prevents the panel from reporting a false start.
  if omarchy-launch-screensaver force >/dev/null 2>&1 \
    && pgrep -f '[o]rg.omarchy.screensaver' >/dev/null 2>&1; then
    jq -n '{ok:true,active:true}'
  else
    jq -n '{ok:false,error:"Check that your default terminal supports the Omarchy screensaver."}'
  fi
}

ensure_state
command="${1:-status}"
shift || true

case "$command" in
  status) summary ;;
  add-todo)
    title="${1:?todo title is required}"
    [[ -n "${title// }" ]] || { summary; exit 0; }
    write_state '.todos += [{id:$id,title:$title,done:false,createdAt:$created}]' --arg id "$(id)" --arg title "$title" --arg created "$(date -Is)"
    summary ;;
  toggle-todo)
    todo_id="${1:?todo id is required}"
    write_state '(.todos[] | select(.id == $id)) |= (.done = (if .done then false else true end) | .completedAt = (if .done then $now else "" end))' --arg id "$todo_id" --arg now "$(date -Is)"
    summary ;;
  remove-todo)
    write_state '.todos |= map(select(.id != $id))' --arg id "${1:?todo id is required}"
    summary ;;
  add-link)
    label="${1:?link label is required}"; url="${2:?link url is required}"
    [[ -n "${url// }" ]] || { summary; exit 0; }
    [[ "$url" =~ ^https?:// ]] || url="https://$url"
    [[ -n "${label// }" ]] || label="$url"
    write_state '.links += [{id:$id,label:$label,url:$url,createdAt:$created}]' --arg id "$(id)" --arg label "$label" --arg url "$url" --arg created "$(date -Is)"
    summary ;;
  remove-link)
    write_state '.links |= map(select(.id != $id))' --arg id "${1:?link id is required}"
    summary ;;
  checkin)
    kind="${1:?check-in kind is required}"
    case "$kind" in water|walk|headphones) ;; *) exit 2 ;; esac
    now="$(date +%s)"
    if [[ "$kind" == "water" ]]; then
      today="$(date +%F)"
      write_state '.activity.water = $now | .activity.waterToday = (if .activity.waterDay == $today then ((.activity.waterToday // 0) + 1) else 1 end) | .activity.waterDay = $today' --argjson now "$now" --arg today "$today"
    else
      write_state ".activity.${kind} = \$now" --argjson now "$now"
    fi
    summary ;;
  toggle-screensaver) toggle_screensaver ;;
  volume-check) volume_check ;;
  codex-status) codex_status ;;
  nudge) nudge "$@" ;;
  *) echo "Unknown Puck command: $command" >&2; exit 2 ;;
esac
