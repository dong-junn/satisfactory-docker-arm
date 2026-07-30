#!/bin/bash

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

COMPOSE_FILE=${COMPOSE_FILE:-docker-compose.yml}
IMAGE=''
CONTAINER_NAME=''
IMAGE_EXISTS=false
CONTAINER_EXISTS=false
CONTAINER_RUNNING=false
MENU_ACTIONS=(status start stop restart logs delete exit)
DELETE_ACTIONS=(full container back)
MENU_LABELS=(
  '상태'
  '시작'
  '중지'
  '재시작'
  '로그'
  '삭제'
  '새티스팩토리 서버 실행 도우미 종료'
)
DELETE_LABELS=(
  '이미지 삭제 & 컨테이너 정지 및 삭제'
  '컨테이너 정지 및 삭제'
  '돌아가기'
)
SELECTED_ACTION=''
MENU_NOTICE=''
SPINNER_INTERVAL=0.1
READY_CHECK_INTERVAL=1
STATUS_LOG_INTERVAL=30
READY_PATTERN="Server API listening on '?0[.]0[.]0[.]0:7777([^0-9]|$)"
SPINNER_FRAMES=('|' '/' '─' '\')
ORIGINAL_STTY=''
CURSOR_HIDDEN=false
ACTIVE_CHILD_PID=''
ACTIVE_OUTPUT_FILE=''
ALT_SCREEN=false
UI_COLS=80
UI_ROWS=24
UI_COMPACT=false
UI_TINY=false
UI_OPERATION_ROW=0
UI_LOG_ROW=0
UI_AMBER=$'\033[38;5;214m'
UI_GREEN=$'\033[38;5;78m'
UI_YELLOW=$'\033[38;5;220m'
UI_RED=$'\033[38;5;203m'
UI_DIM=$'\033[2m'
UI_BOLD=$'\033[1m'
UI_RESET=$'\033[0m'

load_compose_config() {
  local file=$1

  if [[ ! -r $file ]]; then
    printf 'docker-compose.yml 파일을 읽을 수 없습니다.\n' >&2
    return 1
  fi

  IMAGE=$(
    sed -nE "s/^[[:space:]]*image:[[:space:]]*['\"]([^'\"]+)['\"][[:space:]]*$/\1/p" \
      "$file"
  )
  CONTAINER_NAME=$(
    sed -nE "s/^[[:space:]]*container_name:[[:space:]]*['\"]([^'\"]+)['\"][[:space:]]*$/\1/p" \
      "$file"
  )

  if [[ -z $IMAGE ]]; then
    printf 'docker-compose.yml에서 이미지 이름을 가져오지 못했습니다.\n' >&2
    return 1
  fi
  if [[ -z $CONTAINER_NAME ]]; then
    printf 'docker-compose.yml에서 container_name을 가져오지 못했습니다.\n' >&2
    return 1
  fi
}

refresh_state() {
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    IMAGE_EXISTS=true
  else
    IMAGE_EXISTS=false
  fi

  if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    CONTAINER_EXISTS=true
    if [[ $(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME") == true ]]; then
      CONTAINER_RUNNING=true
    else
      CONTAINER_RUNNING=false
    fi
  else
    CONTAINER_EXISTS=false
    CONTAINER_RUNNING=false
  fi
}

action_enabled() {
  case "$1" in
    status|exit) return 0 ;;
    start) [[ $CONTAINER_EXISTS == true && $CONTAINER_RUNNING == false ]] ;;
    stop|restart) [[ $CONTAINER_RUNNING == true ]] ;;
    logs) [[ $CONTAINER_EXISTS == true ]] ;;
    delete) [[ $IMAGE_EXISTS == true || $CONTAINER_EXISTS == true ]] ;;
    *) return 1 ;;
  esac
}

disabled_reason() {
  case "$1" in
    start|stop|restart|logs)
      if [[ $CONTAINER_EXISTS == false ]]; then
        printf '[컨테이너 없음]'
      elif [[ $1 == start ]]; then
        printf '[이미 실행 중]'
      else
        printf '[컨테이너 중지됨]'
      fi
      ;;
    delete) printf '[삭제할 리소스 없음]' ;;
  esac
}

ui_refresh_dimensions() {
  local cols
  local rows

  cols=$(tput cols 2>/dev/null || printf '80')
  rows=$(tput lines 2>/dev/null || printf '24')
  [[ $cols =~ ^[0-9]+$ && $cols -gt 0 ]] || cols=80
  [[ $rows =~ ^[0-9]+$ && $rows -gt 0 ]] || rows=24
  UI_COLS=$cols
  UI_ROWS=$rows
  UI_COMPACT=false
  UI_TINY=false
  if ((UI_COLS < 68 || UI_ROWS < 22)); then
    UI_COMPACT=true
  fi
  if ((UI_COLS < 42 || UI_ROWS < 16)); then
    UI_TINY=true
  fi
}

ui_rule() {
  local width=$1
  local line

  printf -v line '%*s' "$width" ''
  printf '%s' "${line// /─}"
}

ui_trim() {
  local text=$1
  local max=$2

  if ((max > 3 && ${#text} > max)); then
    printf '%s...' "${text:0:max - 3}"
  else
    printf '%s' "$text"
  fi
}

ui_begin_screen() {
  ui_refresh_dimensions
  printf '\033[2J\033[H\033[r'
}

ui_header() {
  local rule_width=$((UI_COLS - 2))

  ((rule_width > 0)) || rule_width=1
  printf '%b 새티스팩토리 서버 실행 도우미%b\n' "$UI_AMBER$UI_BOLD" "$UI_RESET"
  printf '%b ' "$UI_AMBER"
  ui_rule "$rule_width"
  printf '%b\n' "$UI_RESET"
}

ui_state_line() {
  local label=$1
  local exists=$2
  local detail=$3
  local color=$UI_YELLOW
  local state='NOT FOUND'

  if [[ $exists == true ]]; then
    color=$UI_GREEN
    state='READY'
  fi
  printf '  %-10s %b● %-10s%b ' "$label" "$color" "$state" "$UI_RESET"
  ui_trim "$detail" $((UI_COLS - 30))
  printf '\n'
}

ui_container_state_line() {
  local color=$UI_YELLOW
  local state='NOT FOUND'

  if [[ $CONTAINER_RUNNING == true ]]; then
    color=$UI_GREEN
    state='RUNNING'
  elif [[ $CONTAINER_EXISTS == true ]]; then
    state='STOPPED'
  fi
  printf '  %-10s %b● %-10s%b ' 'CONTAINER' "$color" "$state" "$UI_RESET"
  ui_trim "$CONTAINER_NAME" $((UI_COLS - 30))
  printf '\n'
}

ui_compact_state() {
  local image_state='없음'
  local container_state='없음'

  [[ $IMAGE_EXISTS == true ]] && image_state='준비됨'
  if [[ $CONTAINER_RUNNING == true ]]; then
    container_state='실행 중'
  elif [[ $CONTAINER_EXISTS == true ]]; then
    container_state='중지됨'
  fi
  printf '%bIMAGE%b: %s  %bCONTAINER%b: %s\n' \
    "$UI_DIM" "$UI_RESET" "$image_state" "$UI_DIM" "$UI_RESET" "$container_state"
}

ui_menu_item() {
  local index=$1
  local selected=$2
  local action=$3
  local label=$4
  local reason

  if action_enabled "$action"; then
    if [[ $index -eq $selected ]]; then
      printf '%b ▌ %s%b\n' "$UI_AMBER$UI_BOLD" "$label" "$UI_RESET"
    else
      printf '   %s\n' "$label"
    fi
  else
    reason=$(disabled_reason "$action")
    printf '%b   %s  %s%b\n' "$UI_DIM" "$label" "$reason" "$UI_RESET"
  fi
}

ui_footer() {
  local message=$1
  local row=$UI_ROWS

  printf '\033[%d;1H\033[2K%b %s%b' "$row" "$UI_DIM" "$message" "$UI_RESET"
}

ui_notice() {
  local message=$1
  local row=$((UI_ROWS - 1))

  ((row > 0)) || return 0
  printf '\033[%d;1H\033[2K%b ! %s%b' "$row" "$UI_YELLOW" "$message" "$UI_RESET"
}

ui_main_footer() {
  if [[ $UI_TINY == true ]]; then
    ui_footer '↑↓ Enter q'
  elif [[ $UI_COMPACT == true ]]; then
    ui_footer '↑↓ 이동  •  Enter 선택  •  q 종료'
  else
    ui_footer '↑/k 이동  •  ↓/j 이동  •  Enter 선택  •  q 종료'
  fi
}

ui_delete_footer() {
  if [[ $UI_TINY == true ]]; then
    ui_footer '↑↓ Enter q'
  elif [[ $UI_COMPACT == true ]]; then
    ui_footer '↑↓ 이동  •  Enter 선택  •  q 뒤로'
  else
    ui_footer '↑/k 이동  •  ↓/j 이동  •  Enter 선택  •  q 메인 메뉴'
  fi
}

ui_operation_screen() {
  local title=$1
  local message=$2

  ui_begin_screen
  if [[ $UI_TINY == true ]]; then
    printf '%b SATISFACTORY CONTROL%b\n\n' "$UI_AMBER$UI_BOLD" "$UI_RESET"
  elif [[ $UI_COMPACT == true ]]; then
    printf '%b SATISFACTORY // SERVER CONTROL%b\n\n' "$UI_AMBER$UI_BOLD" "$UI_RESET"
  else
    ui_header
    printf '\n'
  fi
  printf '%b %s%b\n\n' "$UI_AMBER$UI_BOLD" "$title" "$UI_RESET"
  UI_OPERATION_ROW=6
  if [[ $UI_TINY == true || $UI_COMPACT == true ]]; then
    UI_OPERATION_ROW=4
  fi
  printf '\033[%d;1H  %s\n' "$UI_OPERATION_ROW" "$message"
  UI_LOG_ROW=$((UI_OPERATION_ROW + 3))
  ui_footer 'q 현재 작업 중단'
}

ui_operation_update() {
  local message=$1

  printf '\033[%d;1H\033[2K  %b%s%b' "$UI_OPERATION_ROW" "$UI_AMBER" "$message" "$UI_RESET"
}

ui_prompt_screen() {
  local message=$1
  local color=$UI_AMBER
  local title='CONFIRM OPERATION'

  if [[ $message == *삭제* ]]; then
    color=$UI_RED
    title='DELETE RESOURCES'
  fi
  ui_begin_screen
  if [[ $UI_COMPACT == false ]]; then
    ui_header
    printf '\n'
  else
    printf '%b SATISFACTORY // SERVER CONTROL%b\n\n' "$UI_AMBER$UI_BOLD" "$UI_RESET"
  fi
  printf '%b %s%b\n\n' "$color$UI_BOLD" "$title" "$UI_RESET"
  printf '  %s\n' "$message"
  ui_footer 'y 확인  •  n/q 취소'
}

ui_reset_scroll_region() {
  printf '\033[r'
}

next_enabled_index() {
  local index=$1
  local direction=$2
  local count=${#MENU_ACTIONS[@]}
  local candidate=$index

  while true; do
    candidate=$(((candidate + direction + count) % count))
    if action_enabled "${MENU_ACTIONS[$candidate]}"; then
      printf '%s\n' "$candidate"
      return 0
    fi
    if [[ $candidate -eq $index ]]; then
      printf '%s\n' "$index"
      return 0
    fi
  done
}

render_main_menu() {
  local selected=$1
  local index
  local action

  ui_begin_screen

  if [[ $UI_TINY == true ]]; then
    printf '%b SATISFACTORY CONTROL%b\n\n' "$UI_AMBER$UI_BOLD" "$UI_RESET"
  elif [[ $UI_COMPACT == true ]]; then
    printf '%b SATISFACTORY // SERVER CONTROL%b\n\n' "$UI_AMBER$UI_BOLD" "$UI_RESET"
    ui_compact_state
    printf '\n%bOPERATIONS%b\n\n' "$UI_AMBER$UI_BOLD" "$UI_RESET"
  else
    ui_header
    printf '\n%b SYSTEM STATUS%b\n\n' "$UI_AMBER$UI_BOLD" "$UI_RESET"
    ui_state_line 'IMAGE' "$IMAGE_EXISTS" "$IMAGE"
    ui_container_state_line
    printf '\n%b OPERATIONS%b\n\n' "$UI_AMBER$UI_BOLD" "$UI_RESET"
  fi

  for ((index = 0; index < ${#MENU_ACTIONS[@]}; index++)); do
    action=${MENU_ACTIONS[$index]}
    ui_menu_item "$index" "$selected" "$action" "${MENU_LABELS[$index]}"
  done

  if [[ -n $MENU_NOTICE ]]; then
    ui_notice "$MENU_NOTICE"
    MENU_NOTICE=''
  fi
  ui_main_footer
}

choose_main_action() {
  local selected=0
  local key=''
  local sequence=''
  local action

  while true; do
    refresh_state
    if ! action_enabled "${MENU_ACTIONS[$selected]}"; then
      selected=$(next_enabled_index "$selected" 1)
    fi
    render_main_menu "$selected"
    IFS= read -rsn1 key || return 130
    case "$key" in
      $'\033')
        sequence=''
        IFS= read -rsn2 -t 0.05 sequence || true
        case "$sequence" in
          '[A') selected=$(next_enabled_index "$selected" -1) ;;
          '[B') selected=$(next_enabled_index "$selected" 1) ;;
        esac
        ;;
      k) selected=$(next_enabled_index "$selected" -1) ;;
      j) selected=$(next_enabled_index "$selected" 1) ;;
      '')
        action=${MENU_ACTIONS[$selected]}
        refresh_state
        if action_enabled "$action"; then
          SELECTED_ACTION=$action
          return 0
        fi
        MENU_NOTICE='현재 상태에서는 실행할 수 없습니다.'
        selected=0
        ;;
      q|Q)
        return 130
        ;;
    esac
  done
}

require_command() {
  command -v "$1" >/dev/null 2>&1
}

validate_runtime() {
  [[ -t 0 && -t 1 ]] || {
    printf '이 실행 도우미는 대화형 터미널에서 실행해야 합니다.\n' >&2
    return 1
  }
  require_command docker || {
    printf 'docker 명령을 찾을 수 없습니다.\n' >&2
    return 1
  }
  docker compose version >/dev/null 2>&1 || {
    printf 'Docker Compose v2를 사용할 수 없습니다.\n' >&2
    return 1
  }
}

setup_terminal() {
  ORIGINAL_STTY=$(stty -g)
  ALT_SCREEN=true
  printf '\033[?1049h\033[H'
  CURSOR_HIDDEN=true
  printf '\033[?25l'
}

restore_terminal() {
  if [[ -n $ORIGINAL_STTY ]]; then
    stty "$ORIGINAL_STTY" 2>/dev/null || true
    ORIGINAL_STTY=''
  fi
  if [[ $CURSOR_HIDDEN == true ]]; then
    printf '\033[?25h'
    CURSOR_HIDDEN=false
  fi
  if [[ $ALT_SCREEN == true ]]; then
    printf '\033[r\033[?1049l'
    ALT_SCREEN=false
  fi
}

active_child_is_running() {
  local child_pid=$1
  local key
  local parent_pid

  kill -0 "$child_pid" 2>/dev/null || return 1

  if [[ -r /proc/$child_pid/status ]]; then
    while read -r key parent_pid _; do
      if [[ $key == 'PPid:' ]]; then
        [[ $parent_pid == "$BASHPID" ]]
        return
      fi
    done <"/proc/$child_pid/status"
    return 1
  fi

  return 0
}

cleanup_active_child() {
  local child_pid=${ACTIVE_CHILD_PID:-}
  local output_file=${ACTIVE_OUTPUT_FILE:-}
  local attempt

  ACTIVE_CHILD_PID=''
  ACTIVE_OUTPUT_FILE=''

  if [[ -n $child_pid ]]; then
    if active_child_is_running "$child_pid"; then
      kill -INT "$child_pid" 2>/dev/null || true
    fi
    for ((attempt = 0; attempt < 10; attempt++)); do
      active_child_is_running "$child_pid" || break
      sleep 0.05
    done
    if active_child_is_running "$child_pid"; then
      kill -TERM "$child_pid" 2>/dev/null || true
    fi
    for ((attempt = 0; attempt < 10; attempt++)); do
      active_child_is_running "$child_pid" || break
      sleep 0.05
    done
    if active_child_is_running "$child_pid"; then
      kill -KILL "$child_pid" 2>/dev/null || true
    fi
    wait "$child_pid" 2>/dev/null || true
  fi

  if [[ -n $output_file ]]; then
    rm -f -- "$output_file"
  fi
}

cleanup_on_exit() {
  cleanup_active_child
  restore_terminal
}

handle_interrupt() {
  cleanup_active_child
  restore_terminal
  printf '\n새티스팩토리 서버 실행 도우미를 종료합니다.\n'
  exit 130
}

pause_for_key() {
  local ignored=''

  ui_footer '아무 키나 누르면 메인 메뉴로 돌아갑니다'
  IFS= read -rsn1 ignored || true
}

prompt_yes_no() {
  local message=$1
  local key=''

  while true; do
    ui_prompt_screen "$message"
    IFS= read -rsn1 key || return 1
    case "$key" in
      y|Y)
        return 0
        ;;
      n|N|q|Q)
        return 1
        ;;
      *) ;;
    esac
  done
}

delete_action_enabled() {
  case "$1" in
    full) [[ $IMAGE_EXISTS == true || $CONTAINER_EXISTS == true ]] ;;
    container) [[ $CONTAINER_EXISTS == true ]] ;;
    back) return 0 ;;
    *) return 1 ;;
  esac
}

next_enabled_delete_index() {
  local index=$1
  local direction=$2
  local count=${#DELETE_ACTIONS[@]}
  local candidate=$index

  while true; do
    candidate=$(((candidate + direction + count) % count))
    if delete_action_enabled "${DELETE_ACTIONS[$candidate]}"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
}

render_delete_menu() {
  local selected=$1
  local index
  local action

  ui_begin_screen
  if [[ $UI_COMPACT == false ]]; then
    ui_header
    printf '\n'
  else
    printf '%b SATISFACTORY // SERVER CONTROL%b\n\n' "$UI_AMBER$UI_BOLD" "$UI_RESET"
  fi
  printf '%b DELETE RESOURCES%b\n\n' "$UI_RED$UI_BOLD" "$UI_RESET"
  printf '%b  컨테이너를 정지한 뒤 선택한 리소스를 삭제합니다.%b\n\n' "$UI_DIM" "$UI_RESET"
  for ((index = 0; index < ${#DELETE_ACTIONS[@]}; index++)); do
    action=${DELETE_ACTIONS[$index]}
    if delete_action_enabled "$action"; then
      if [[ $index -eq $selected ]]; then
        printf '%b ▌ %s%b\n' "$UI_RED$UI_BOLD" "${DELETE_LABELS[$index]}" "$UI_RESET"
      else
        printf '   %s\n' "${DELETE_LABELS[$index]}"
      fi
    else
      printf '%b   %s  [컨테이너 없음]%b\n' \
        "$UI_DIM" "${DELETE_LABELS[$index]}" "$UI_RESET"
    fi
  done
  ui_delete_footer
}

delete_container() {
  local status

  refresh_state
  [[ $CONTAINER_EXISTS == true ]] || return 0
  prompt_yes_no '컨테이너를 정지하고 삭제하시겠습니까? (y/n)' || return 0
  if run_with_spinner '컨테이너 정지 및 삭제 중' docker compose down; then
    status=0
  else
    status=$?
  fi
  refresh_state
  [[ $status -eq 130 ]] || pause_for_key
  return "$status"
}

delete_image_and_container() {
  local status

  refresh_state
  [[ $IMAGE_EXISTS == true || $CONTAINER_EXISTS == true ]] || return 0
  prompt_yes_no '이미지와 컨테이너를 삭제하시겠습니까? (y/n)' || return 0
  if [[ $CONTAINER_EXISTS == true ]]; then
    if run_with_spinner '컨테이너 정지 및 삭제 중' docker compose down; then
      status=0
    else
      status=$?
    fi
    if [[ $status -ne 0 ]]; then
      refresh_state
      [[ $status -eq 130 ]] || pause_for_key
      return "$status"
    fi
  fi
  if [[ $IMAGE_EXISTS == true ]]; then
    if run_with_spinner 'Docker 이미지 삭제 중' docker image rm "$IMAGE"; then
      status=0
    else
      status=$?
    fi
    refresh_state
    [[ $status -eq 130 ]] || pause_for_key
    return "$status"
  fi
  refresh_state
  pause_for_key
}

show_delete_menu() {
  local selected=0
  local key=''
  local sequence=''
  local action

  while true; do
    refresh_state
    if ! delete_action_enabled "${DELETE_ACTIONS[$selected]}"; then
      selected=$(next_enabled_delete_index "$selected" 1)
    fi
    render_delete_menu "$selected"
    IFS= read -rsn1 key || return 0
    case "$key" in
      $'\033')
        sequence=''
        IFS= read -rsn2 -t 0.05 sequence || true
        case "$sequence" in
          '[A') selected=$(next_enabled_delete_index "$selected" -1) ;;
          '[B') selected=$(next_enabled_delete_index "$selected" 1) ;;
        esac
        ;;
      k) selected=$(next_enabled_delete_index "$selected" -1) ;;
      j) selected=$(next_enabled_delete_index "$selected" 1) ;;
      '')
        action=${DELETE_ACTIONS[$selected]}
        refresh_state
        delete_action_enabled "$action" || continue
        case "$action" in
          full) delete_image_and_container || true; return 0 ;;
          container) delete_container || true; return 0 ;;
          back) return 0 ;;
        esac
        ;;
      q|Q) return 0 ;;
    esac
  done
}

execute_action() {
  local action=$1
  local status

  refresh_state
  if ! action_enabled "$action"; then
    printf '현재 상태에서는 실행할 수 없습니다.\n'
    pause_for_key
    return 1
  fi
  case "$action" in
    status)
      ui_operation_screen 'CONTAINER STATUS' 'Docker 컨테이너 상태를 표시합니다'
      printf '\033[%d;1H' "$((UI_OPERATION_ROW + 2))"
      docker ps -a --filter "name=$CONTAINER_NAME"
      pause_for_key
      ;;
    start)
      if run_with_spinner '컨테이너 시작 중' docker compose start; then
        status=0
      else
        status=$?
      fi
      refresh_state
      [[ $status -eq 130 ]] || pause_for_key
      return "$status"
      ;;
    stop)
      if run_with_spinner '컨테이너 중지 중' docker compose stop; then
        status=0
      else
        status=$?
      fi
      refresh_state
      [[ $status -eq 130 ]] || pause_for_key
      return "$status"
      ;;
    restart)
      if run_with_spinner '컨테이너 재시작 중' docker compose restart; then
        status=0
      else
        status=$?
      fi
      refresh_state
      [[ $status -eq 130 ]] || pause_for_key
      return "$status"
      ;;
    logs)
      if show_live_logs; then
        status=0
      else
        status=$?
      fi
      [[ $status -eq 130 ]] || pause_for_key
      return "$status"
      ;;
    delete) show_delete_menu ;;
  esac
}

run_initial_audit() {
  local status

  refresh_state

  if [[ $IMAGE_EXISTS == false ]]; then
    if prompt_yes_no 'Docker 이미지가 없습니다. 설치 및 실행하시겠습니까? (y/n)'; then
      if run_with_spinner 'Docker 이미지 내려받는 중' docker pull "$IMAGE"; then
        status=0
      else
        status=$?
      fi
      if [[ $status -ne 0 ]]; then
        [[ $status -eq 130 ]] || pause_for_key
        return 0
      fi

      if run_with_spinner '컨테이너 생성 및 실행 중' docker compose up -d; then
        status=0
      else
        status=$?
      fi
      if [[ $status -ne 0 ]]; then
        [[ $status -eq 130 ]] || pause_for_key
        return 0
      fi

      SECONDS=0
      if wait_for_server_ready; then
        status=0
      else
        status=$?
      fi
      [[ $status -eq 130 ]] || pause_for_key
    fi
    return 0
  fi

  if [[ $CONTAINER_EXISTS == false ]]; then
    if prompt_yes_no '컨테이너가 없습니다. 생성 및 실행하시겠습니까? (y/n)'; then
      if run_with_spinner '컨테이너 생성 및 실행 중' docker compose up -d; then
        status=0
      else
        status=$?
      fi
      if [[ $status -ne 0 ]]; then
        [[ $status -eq 130 ]] || pause_for_key
        return 0
      fi

      SECONDS=0
      if wait_for_server_ready; then
        status=0
      else
        status=$?
      fi
      [[ $status -eq 130 ]] || pause_for_key
    fi
    return 0
  fi

  if [[ $CONTAINER_RUNNING == false ]] &&
    prompt_yes_no '컨테이너가 중지되어 있습니다. 시작하시겠습니까? (y/n)'; then
    if run_with_spinner '컨테이너 시작 중' docker compose start; then
      status=0
    else
      status=$?
    fi
    [[ $status -eq 130 ]] || pause_for_key
  fi
}

run_with_spinner() {
  local label=$1
  shift
  local output_file
  local child_pid
  local key=''
  local frame=0
  local status
  local max_output_lines

  if ! ACTIVE_OUTPUT_FILE=$(mktemp); then
    printf '임시 출력 파일을 만들 수 없습니다.\n' >&2
    return 1
  fi
  output_file=$ACTIVE_OUTPUT_FILE
  ui_operation_screen 'COMMAND IN PROGRESS' "$label"
  "$@" >"$output_file" 2>&1 &
  ACTIVE_CHILD_PID=$!
  child_pid=$ACTIVE_CHILD_PID

  while kill -0 "$child_pid" 2>/dev/null; do
    ui_operation_update "${SPINNER_FRAMES[$frame]}  $label"
    frame=$(((frame + 1) % ${#SPINNER_FRAMES[@]}))
    if IFS= read -rsn1 -t "$SPINNER_INTERVAL" key && [[ $key == q ]]; then
      cleanup_active_child
      ui_operation_update '작업 화면을 종료하고 메인 메뉴로 돌아갑니다'
      return 130
    fi
  done

  if wait "$child_pid"; then
    status=0
  else
    status=$?
  fi
  ACTIVE_CHILD_PID=''
  if [[ $status -ne 0 ]]; then
    ui_operation_update "✕ Docker 명령이 실패했습니다 (종료 코드: $status)"
    printf '\033[%d;1H%b  COMMAND OUTPUT%b\n' "$UI_LOG_ROW" "$UI_DIM" "$UI_RESET"
    max_output_lines=$((UI_ROWS - UI_LOG_ROW - 2))
    ((max_output_lines > 0)) || max_output_lines=1
    sed -n "1,${max_output_lines}p" "$output_file"
  else
    ui_operation_update "✓ $label 완료"
  fi
  rm -f -- "$output_file"
  ACTIVE_OUTPUT_FILE=''
  return "$status"
}

wait_for_server_ready() {
  local started_at
  local key=''
  local frame=0
  local now
  local next_check=0
  local next_status=$STATUS_LOG_INTERVAL
  local logs

  started_at=$(docker inspect --format '{{.State.StartedAt}}' "$CONTAINER_NAME") ||
    return 1

  ui_operation_screen 'WAITING FOR SERVER' '서버가 준비될 때까지 상태를 확인합니다'
  printf '\033[%d;1H%b  LATEST LOG%b' "$UI_LOG_ROW" "$UI_DIM" "$UI_RESET"

  while true; do
    now=$SECONDS
    ui_operation_update "${SPINNER_FRAMES[$frame]}  서버 준비 중"
    frame=$(((frame + 1) % ${#SPINNER_FRAMES[@]}))

    if IFS= read -rsn1 -t "$SPINNER_INTERVAL" key && [[ $key == q ]]; then
      ui_operation_update '서버 준비 감시를 종료하고 메인 메뉴로 돌아갑니다'
      return 130
    fi

    if ((now >= next_check)); then
      logs=$(docker logs --since "$started_at" "$CONTAINER_NAME" 2>&1)
      if grep -Eq "$READY_PATTERN" <<<"$logs"; then
        ui_operation_update '✓ 새티스팩토리 서버가 준비되었습니다'
        return 0
      fi
      if [[ $(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME") != true ]]; then
        ui_operation_update '✕ 새티스팩토리 서버 컨테이너가 중지되었습니다'
        return 1
      fi
      next_check=$((now + READY_CHECK_INTERVAL))
    fi

    if ((now >= next_status)); then
      printf '\033[%d;1H\033[2K  ' "$((UI_LOG_ROW + 1))"
      ui_trim "$(docker logs --tail 1 "$CONTAINER_NAME" 2>&1)" $((UI_COLS - 4))
      next_status=$((now + STATUS_LOG_INTERVAL))
    fi
  done
}

show_live_logs() {
  local child_pid
  local key=''
  local status

  ui_operation_screen 'LIVE LOG STREAM' '최근 서버 로그를 표시합니다'
  if ((UI_ROWS > UI_OPERATION_ROW + 4)); then
    printf '\033[%d;%dr\033[%d;1H' \
      "$((UI_OPERATION_ROW + 2))" "$((UI_ROWS - 1))" "$((UI_OPERATION_ROW + 2))"
  else
    printf '\n'
  fi
  docker logs --follow --tail 100 "$CONTAINER_NAME" &
  ACTIVE_CHILD_PID=$!
  child_pid=$ACTIVE_CHILD_PID

  while kill -0 "$child_pid" 2>/dev/null; do
    if IFS= read -rsn1 -t 0.1 key && [[ $key == q ]]; then
      cleanup_active_child
      ui_reset_scroll_region
      ui_operation_update '로그 화면을 종료하고 메인 메뉴로 돌아갑니다'
      return 130
    fi
  done

  if wait "$child_pid"; then
    status=0
  else
    status=$?
  fi
  ACTIVE_CHILD_PID=''
  ui_reset_scroll_region

  if [[ $status -eq 0 ]]; then
    ui_operation_update '실시간 로그가 종료되었습니다'
  else
    ui_operation_update "✕ Docker 로그 명령이 실패했습니다 (종료 코드: $status)"
  fi
  return "$status"
}

main() (
  set +e
  set -u

  validate_runtime || return 1
  load_compose_config "$COMPOSE_FILE" || return 1

  trap cleanup_on_exit EXIT
  trap handle_interrupt INT TERM
  setup_terminal

  run_initial_audit

  while true; do
    if ! choose_main_action; then
      printf '\n새티스팩토리 서버 실행 도우미를 종료합니다.\n'
      return 0
    fi

    if [[ $SELECTED_ACTION == exit ]]; then
      printf '\n새티스팩토리 서버 실행 도우미를 종료합니다.\n'
      return 0
    fi

    execute_action "$SELECTED_ACTION" || true
  done
)

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
