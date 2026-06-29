#!/usr/bin/env bash

# Validate commit messages against this repo's gitmoji + Conventional Commits
# format: start-with-gitmoji, type-enum, subject-empty, subject-full-stop,
# scope-case, header-max-length, body-leading-blank.
#
# Usage:
#   lint-commit-msg.sh <commit-msg-file>      # commit-msg hook (one message)
#   lint-commit-msg.sh --range <from> <to>    # lint every commit in a range (CI)

set -euo pipefail

# Self-contained logging (no external dependency in deposited projects).
error() { printf 'lint-commit-msg: %s\n' "$*" >&2; }
log_line() { printf '%s\n' "$*" >&2; }
success() { printf '%s\n' "$*" >&2; }

# Conventional Commit types accepted (from @gitmoji/commit-types).
GITMOJI_TYPES='build ci docs feat fix perf refactor revert style test chore wip'

HEADER_MAX_LENGTH=100

# Valid gitmoji, Unicode form (variation selectors U+FE0F included).
GITMOJI_UNICODE='🎨
⚡️
🔥
🐛
🚑️
✨
📝
🚀
💄
🎉
✅
🔒️
🔐
🔖
🚨
🚧
💚
⬇️
⬆️
📌
👷
📈
♻️
➕
➖
🔧
🔨
🌐
✏️
💩
⏪️
🔀
📦️
👽️
🚚
📄
💥
🍱
♿️
💡
🍻
💬
🗃️
🔊
🔇
👥
🚸
🏗️
📱
🤡
🥚
🙈
📸
⚗️
🔍️
🏷️
🌱
🚩
🥅
💫
🗑️
🛂
🩹
🧐
⚰️
🧪
👔
🩺
🧱
🧑‍💻
💸
🧵
🦺
✈️'

# Valid gitmoji, :code: form.
GITMOJI_CODES=':art:
:zap:
:fire:
:bug:
:ambulance:
:sparkles:
:memo:
:rocket:
:lipstick:
:tada:
:white_check_mark:
:lock:
:closed_lock_with_key:
:bookmark:
:rotating_light:
:construction:
:green_heart:
:arrow_down:
:arrow_up:
:pushpin:
:construction_worker:
:chart_with_upwards_trend:
:recycle:
:heavy_plus_sign:
:heavy_minus_sign:
:wrench:
:hammer:
:globe_with_meridians:
:pencil2:
:poop:
:rewind:
:twisted_rightwards_arrows:
:package:
:alien:
:truck:
:page_facing_up:
:boom:
:bento:
:wheelchair:
:bulb:
:beers:
:speech_balloon:
:card_file_box:
:loud_sound:
:mute:
:busts_in_silhouette:
:children_crossing:
:building_construction:
:iphone:
:clown_face:
:egg:
:see_no_evil:
:camera_flash:
:alembic:
:mag:
:label:
:seedling:
:triangular_flag_on_post:
:goal_net:
:dizzy:
:wastebasket:
:passport_control:
:adhesive_bandage:
:monocle_face:
:coffin:
:test_tube:
:necktie:
:stethoscope:
:bricks:
:technologist:
:money_with_wings:
:thread:
:safety_vest:
:airplane:'

# Validate a single raw commit message. $2 is an optional label (a SHA in range
# mode) used in error output. Returns 0 when valid, 1 otherwise.
validate_message() {
  local raw="$1" label="$2"
  local -a lines=() errs=()
  local header="" header_index=-1 i h rest e prefix code type scope subject next
  local emoji_ok=0 _line

  # Drop the comment lines git adds to the commit-msg file.
  while IFS= read -r _line || [ -n "$_line" ]; do
    lines+=("$_line")
  done < <(printf '%s\n' "$raw" | grep -vE '^[[:space:]]*#' || true)

  # The header is the first line with non-whitespace content.
  for i in "${!lines[@]}"; do
    if [ -n "${lines[$i]//[[:space:]]/}" ]; then
      header="${lines[$i]}"
      header_index="$i"
      break
    fi
  done

  if [ -z "$header" ]; then
    error "invalid commit message${label:+ ($label)}: message is empty"
    return 1
  fi

  if [ "${#header}" -gt "$HEADER_MAX_LENGTH" ]; then
    errs+=("header is ${#header} characters, the maximum is $HEADER_MAX_LENGTH")
  fi

  # Strip any leading whitespace before the gitmoji (parserOpts allowed it).
  h="$header"
  h="${h#"${h%%[![:space:]]*}"}"

  # Match a leading gitmoji: Unicode form first, then the :code: form. A prefix
  # match against the exact list enforces variation-selector sensitivity
  # (e.g. the lock emoji is only valid with its U+FE0F selector).
  while IFS= read -r e; do
    [ -z "$e" ] && continue
    prefix="$e "
    if [ "${h#"$prefix"}" != "$h" ]; then
      rest="${h#"$prefix"}"
      emoji_ok=1
      break
    fi
  done <<<"$GITMOJI_UNICODE"

  if [ "$emoji_ok" -eq 0 ]; then
    code="${h%%[[:space:]]*}"
    case $'\n'"$GITMOJI_CODES"$'\n' in
    *$'\n'"$code"$'\n'*)
      prefix="$code "
      if [ "${h#"$prefix"}" != "$h" ]; then
        rest="${h#"$prefix"}"
        emoji_ok=1
      fi
      ;;
    esac
  fi

  if [ "$emoji_ok" -eq 0 ]; then
    errs+=("must start with a valid gitmoji (Unicode emoji or :code:) — see https://gitmoji.dev/")
  elif [[ "$rest" =~ ^([^(!:[:space:]]+)(\(([^)]*)\))?(!)?:[[:space:]](.*)$ ]]; then
    type="${BASH_REMATCH[1]}"
    scope="${BASH_REMATCH[3]}"
    subject="${BASH_REMATCH[5]}"

    case " $GITMOJI_TYPES " in
    *" $type "*) ;;
    *) errs+=("type \"$type\" is not allowed — use one of: $GITMOJI_TYPES") ;;
    esac

    case "$scope" in
    *[A-Z]*) errs+=("scope \"$scope\" must be lower-case") ;;
    esac

    if [ -z "${subject//[[:space:]]/}" ]; then
      errs+=("subject must not be empty")
    fi

    case "$subject" in
    *.) errs+=("subject must not end with a period") ;;
    esac
  else
    errs+=("header must match \"<emoji> <type>(<scope>): <subject>\"")
  fi

  # body-leading-blank: a body must be separated from the header by a blank line.
  next=$((header_index + 1))
  if [ "$next" -lt "${#lines[@]}" ] && [ -n "${lines[$next]//[[:space:]]/}" ]; then
    errs+=("the body must be separated from the header by a blank line")
  fi

  if [ "${#errs[@]}" -gt 0 ]; then
    error "invalid commit message${label:+ ($label)}:"
    log_line "    $header"
    for e in "${errs[@]}"; do
      log_line "    x $e"
    done
    return 1
  fi

  return 0
}

main() {
  if [ "${1:-}" = "--range" ]; then
    local from to sha body status=0
    from="${2:?--range requires <from> <to>}"
    to="${3:?--range requires <from> <to>}"
    while IFS= read -r sha; do
      [ -z "$sha" ] && continue
      body="$(git log -1 --format=%B "$sha")"
      if ! validate_message "$body" "$sha"; then
        status=1
      fi
    done < <(git rev-list --reverse "${from}..${to}")
    if [ "$status" -eq 0 ]; then
      success "all commit messages follow the gitmoji + Conventional Commits format"
    fi
    return "$status"
  fi

  local file body
  file="${1:?usage: lint-commit-msg.sh <commit-msg-file> | --range <from> <to>}"
  body="$(<"$file")"
  validate_message "$body" ""
}

main "$@"
