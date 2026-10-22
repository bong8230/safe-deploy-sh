#!/usr/bin/env bash
# safe-deploy.sh — rsync 기반 운영 배포 스크립트
#
# 흐름: 설정 로드 → 접속 IP 확인 → dry-run으로 후보 산출 → 파일 선택
#       → 미리보기 → 환경명 확인 → 원격 백업 + 검증 → 반영 → 로그 기록
#
# 사용법: ./safe-deploy.sh -c deploy.conf [-m select|full]

set -euo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"

# ------------------------------------------------------------
# 공통 유틸
# ------------------------------------------------------------
die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME -c <config> [-m select|full]

  -c  설정 파일 경로 (예시: examples/deploy.conf.example)
  -m  배포 모드
        select : 변경 파일 중 골라서 반영 (삭제 없음, 기본값)
        full   : 원본과 동일하게 동기화 (원격의 남는 파일 삭제 포함)
EOF
}

# ------------------------------------------------------------
# 설정
# ------------------------------------------------------------
CONFIG=""
MODE="select"

while getopts ":c:m:h" opt; do
  case "$opt" in
    c) CONFIG="$OPTARG" ;;
    m) MODE="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

[ -n "$CONFIG" ] || { usage; exit 1; }
[ -f "$CONFIG" ] || die "config not found: $CONFIG"
[[ "$MODE" == "select" || "$MODE" == "full" ]] || die "unknown mode: $MODE"

# shellcheck source=/dev/null
source "$CONFIG"

: "${ENV_NAME:?ENV_NAME is required}"
: "${SRC_DIR:?SRC_DIR is required}"
: "${DST_DIR:?DST_DIR is required}"
: "${INCLUDE_PATTERNS:?INCLUDE_PATTERNS is required}"
: "${BACKUP_ROOT:?BACKUP_ROOT is required}"
: "${LOG_ROOT:?LOG_ROOT is required}"
TARGET_HOST="${TARGET_HOST:-}"           # 비어 있으면 로컬 폴더로 배포(시연·테스트용)
ALLOWED_IP_PREFIXES="${ALLOWED_IP_PREFIXES:-}"
RESTART_PATTERNS="${RESTART_PATTERNS:-}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-365}"
NEW_FILE_WARN_RATIO="${NEW_FILE_WARN_RATIO:-30}"

SRC_DIR="${SRC_DIR%/}/"
DST_DIR="${DST_DIR%/}/"

if [ -n "$TARGET_HOST" ]; then
  RSYNC_DST="${TARGET_HOST}:${DST_DIR}"
else
  RSYNC_DST="$DST_DIR"
fi

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
YM="$(date '+%Y%m')"
LOG_DIR="${LOG_ROOT%/}/${YM}"
LOG_FILE="${LOG_DIR}/deploy_${ENV_NAME}_${MODE}_${TIMESTAMP}.log"
SUMMARY_FILE="${LOG_DIR}/summary_${YM}.log"
BACKUP_DIR="${BACKUP_ROOT%/}/${YM}/${ENV_NAME}_${MODE}_${TIMESTAMP}"
WORK_DIR="$(mktemp -d)"

STATE="INIT"
RESULT="UNKNOWN"
EXEC_IP="${SSH_CLIENT:-}"
EXEC_IP="${EXEC_IP%% *}"
EXEC_IP="${EXEC_IP:-LOCAL}"

CANDIDATES="$WORK_DIR/candidates.txt"
DELETES="$WORK_DIR/deletes.txt"
SELECTED="$WORK_DIR/selected.txt"

# ------------------------------------------------------------
# 대상 서버 명령 실행 (원격이면 ssh, 아니면 로컬 bash)
# ------------------------------------------------------------
run_on_target() {
  if [ -n "$TARGET_HOST" ]; then
    ssh -T "$TARGET_HOST" "bash -s" -- "$@"
  else
    bash -s -- "$@"
  fi
}

# ------------------------------------------------------------
# 로그
# ------------------------------------------------------------
log() { echo "$*" | tee -a "$LOG_FILE"; }

write_summary() {
  local changed=0 deleted=0
  [ -f "$SELECTED" ] && changed="$(grep -c . "$SELECTED" || true)"
  [ -f "$DELETES" ] && [ "$MODE" = "full" ] && deleted="$(grep -c . "$DELETES" || true)"
  {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] env=${ENV_NAME} mode=${MODE} result=${RESULT} state=${STATE} changed=${changed} deleted=${deleted} ip=${EXEC_IP}"
    [ -s "$SELECTED" ] && sed 's/^/  + /' "$SELECTED"
    [ "$MODE" = "full" ] && [ -s "$DELETES" ] && sed 's/^/  - /' "$DELETES"
    echo
  } >> "$SUMMARY_FILE"
}

cleanup_old_logs() {
  find "$LOG_ROOT" -type f -name 'deploy_*.log' -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
  find "$LOG_ROOT" -mindepth 1 -type d -empty -delete 2>/dev/null || true
}

on_exit() {
  local code=$?
  if [ "$RESULT" = "UNKNOWN" ]; then
    RESULT=$([ "$code" -eq 0 ] && echo "SUCCESS" || echo "FAILED")
  fi
  [ -d "$LOG_DIR" ] && write_summary
  rm -rf "$WORK_DIR"
}

on_interrupt() {
  RESULT="INTERRUPTED"
  echo
  log "Interrupted at state=${STATE}"
  exit 130
}

trap on_exit EXIT
trap on_interrupt INT TERM

# ------------------------------------------------------------
# 안전장치
# ------------------------------------------------------------
check_exec_ip() {
  [ -n "$ALLOWED_IP_PREFIXES" ] || return 0
  local prefix
  for prefix in $(echo "$ALLOWED_IP_PREFIXES" | tr ' ' '\n'); do
    [[ "$EXEC_IP" == "$prefix"* ]] && return 0
  done
  RESULT="BLOCKED_IP"
  die "접속 IP(${EXEC_IP})가 허용 대역이 아닙니다."
}

confirm_env_name() {
  local answer
  read -r -p "계속하려면 환경명 '${ENV_NAME}'을(를) 입력하세요: " answer
  [ "$answer" = "$ENV_NAME" ] || { RESULT="CONFIRM_FAIL"; die "환경명이 일치하지 않습니다."; }
}

confirm_delete() {
  local count="$1" answer
  echo "!! 원격에서 파일 ${count}개가 삭제됩니다. 계속하려면 DELETE 를 입력하세요."
  read -r -p "> " answer
  [ "$answer" = "DELETE" ] || { RESULT="CANCELLED"; die "삭제 확인이 일치하지 않습니다."; }
}

confirm_yes() {
  local answer
  read -r -p "$1 (y/n) " answer
  [[ "$answer" == [yY] ]] || { RESULT="CANCELLED"; echo "취소했습니다."; exit 0; }
}

# ------------------------------------------------------------
# dry-run으로 변경·삭제 후보 산출
# ------------------------------------------------------------
build_filter_args() {
  FILTER_ARGS=(--include='*/')
  local p
  for p in $(echo "$INCLUDE_PATTERNS" | tr ' ' '\n'); do
    FILTER_ARGS+=(--include="$p")
  done
  FILTER_ARGS+=(--exclude='*' --prune-empty-dirs)
}

collect_candidates() {
  build_filter_args
  local out
  out="$(rsync -a --checksum --delete --dry-run --itemize-changes "${FILTER_ARGS[@]}" "$SRC_DIR" "$RSYNC_DST")"
  echo "$out" >> "$LOG_FILE"

  # itemize: '>f' 또는 '<f' = 전송될 파일, '*deleting' = 삭제될 파일
  echo "$out" | awk '$1 ~ /^[<>]f/ {print $2}' | sort -u > "$CANDIDATES"
  echo "$out" | awk '$1 == "*deleting" && $2 !~ /\/$/ {print $2}' | sort -u > "$DELETES"
}

print_numbered() { awk '{printf "%3d) %s\n", NR, $0}' "$1"; }

# all / 3 / 1,3 / 2-5 / 1,3-5 형태의 선택을 파일 목록으로 변환
select_by_expr() {
  local list="$1" expr="$2" out="$3" token start end
  : > "$out"
  if [[ "$expr" == "all" ]]; then
    cp "$list" "$out"
    return 0
  fi
  for token in $(echo "$expr" | tr ',' '\n'); do
    token="$(echo "$token" | tr -d ' ')"
    if [[ "$token" =~ ^[0-9]+$ ]]; then
      sed -n "${token}p" "$list" >> "$out"
    elif [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
      [ "$start" -le "$end" ] || { local t="$start"; start="$end"; end="$t"; }
      sed -n "${start},${end}p" "$list" >> "$out"
    else
      return 1
    fi
  done
  sort -u -o "$out" "$out"
  [ -s "$out" ]
}

choose_files() {
  local expr
  while :; do
    read -r -p "배포할 파일 (all / 1 / 1,3 / 2-5 / list / q): " expr
    case "$expr" in
      q|Q)  RESULT="CANCELLED"; echo "취소했습니다."; exit 0 ;;
      list) print_numbered "$CANDIDATES"; continue ;;
    esac
    select_by_expr "$CANDIDATES" "$expr" "$SELECTED" && return 0
    echo "선택 형식이 올바르지 않거나 해당 번호가 없습니다."
  done
}

# ------------------------------------------------------------
# 원격 백업 + 검증
# 원격에 이미 있는 파일만 백업하고, 새 파일은 [NEW]로 표시한다.
# 백업본이 하나라도 확인되지 않으면 배포를 중단한다.
# ------------------------------------------------------------
backup_targets() {
  local list="$1"
  [ -s "$list" ] || return 0

  local report
  report="$(run_on_target "$DST_DIR" "$BACKUP_DIR" < <(
    cat <<'REMOTE'
set -euo pipefail
dst="$1"; bkp="$2"
mkdir -p "$bkp"
cd "$dst"
total=0; copied=0; new=0; failed=0
while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  total=$((total+1))
  if [ ! -f "$rel" ]; then
    echo "[NEW] $rel"; new=$((new+1)); continue
  fi
  mkdir -p "$bkp/$(dirname "$rel")"
  cp -p -- "$rel" "$bkp/$rel"
  if [ -f "$bkp/$rel" ] && cmp -s "$rel" "$bkp/$rel"; then
    copied=$((copied+1))
  else
    echo "[VERIFY_FAIL] $rel"; failed=$((failed+1))
  fi
done <<'LIST'
REMOTE
    cat "$list"
    cat <<'REMOTE'
LIST
echo "[SUMMARY] total=$total copied=$copied new=$new failed=$failed"
[ "$failed" -eq 0 ]
REMOTE
  ))" || { echo "$report" | tee -a "$LOG_FILE"; RESULT="BACKUP_FAIL"; die "백업 검증 실패로 배포를 중단합니다."; }

  echo "$report" | tee -a "$LOG_FILE"

  local total new ratio
  total="$(echo "$report" | sed -n 's/.*total=\([0-9]*\).*/\1/p')"
  new="$(echo "$report" | sed -n 's/.*new=\([0-9]*\).*/\1/p')"
  if [ "${total:-0}" -gt 0 ]; then
    ratio=$(( new * 100 / total ))
    if [ "$ratio" -ge "$NEW_FILE_WARN_RATIO" ] && [ "$MODE" = "full" ]; then
      warn "신규 파일 비율이 ${ratio}% 입니다. 원본 경로가 맞는지 확인하세요."
    fi
  fi
}

# ------------------------------------------------------------
# 재시작 필요 여부
# ------------------------------------------------------------
restart_hint() {
  [ -n "$RESTART_PATTERNS" ] || return 0
  local p
  for p in $(echo "$RESTART_PATTERNS" | tr ' ' '\n'); do
    if grep -Eq "$p" "$@" 2>/dev/null; then
      echo "!! 재시작이 필요한 파일이 포함되어 있습니다 (pattern: $p)"
      return 0
    fi
  done
}

# ------------------------------------------------------------
# main
# ------------------------------------------------------------
mkdir -p "$LOG_DIR"
: > "$LOG_FILE"
cleanup_old_logs

log "================================="
log " ENV  : ${ENV_NAME}"
log " MODE : ${MODE}"
log " SRC  : ${SRC_DIR}"
log " DST  : ${RSYNC_DST}"
log " IP   : ${EXEC_IP}"
log "================================="

STATE="CHECK_IP";   check_exec_ip
STATE="DRY_RUN";    collect_candidates

CHG_COUNT="$(grep -c . "$CANDIDATES" || true)"
DEL_COUNT="$(grep -c . "$DELETES" || true)"

if [ "$MODE" = "select" ]; then
  [ "$CHG_COUNT" -gt 0 ] || { RESULT="SKIPPED"; info "변경된 파일이 없습니다."; exit 0; }
  echo "===== 변경 후보 (${CHG_COUNT}) ====="
  print_numbered "$CANDIDATES"
  STATE="SELECT";   choose_files
else
  [ "$CHG_COUNT" -gt 0 ] || [ "$DEL_COUNT" -gt 0 ] || { RESULT="SKIPPED"; info "변경·삭제할 파일이 없습니다."; exit 0; }
  cp "$CANDIDATES" "$SELECTED"
  echo "===== 변경 (${CHG_COUNT}) ====="; print_numbered "$CANDIDATES"
  echo "===== 삭제 (${DEL_COUNT}) ====="; print_numbered "$DELETES"
fi

echo "===== 미리보기 ====="
if [ "$MODE" = "select" ]; then
  rsync -a --checksum --dry-run --itemize-changes --files-from="$SELECTED" "$SRC_DIR" "$RSYNC_DST" | sed 's/^/  /'
else
  rsync -a --checksum --delete --dry-run --itemize-changes "${FILTER_ARGS[@]}" "$SRC_DIR" "$RSYNC_DST" | sed 's/^/  /'
fi
restart_hint "$SELECTED" "$DELETES"

STATE="CONFIRM";    confirm_env_name
if [ "$MODE" = "full" ] && [ "$DEL_COUNT" -gt 0 ]; then
  confirm_delete "$DEL_COUNT"
fi

STATE="BACKUP"
log "===== 백업: ${BACKUP_DIR} ====="
backup_targets "$SELECTED"
[ "$MODE" = "full" ] && backup_targets "$DELETES"

confirm_yes "백업이 끝났습니다. 반영할까요?"

STATE="DEPLOY"
log "===== 반영 ====="
if [ "$MODE" = "select" ]; then
  rsync -av --checksum --files-from="$SELECTED" "$SRC_DIR" "$RSYNC_DST" 2>&1 | tee -a "$LOG_FILE"
else
  rsync -av --checksum --delete "${FILTER_ARGS[@]}" "$SRC_DIR" "$RSYNC_DST" 2>&1 | tee -a "$LOG_FILE"
fi

STATE="DONE"
RESULT="SUCCESS"
log "배포 완료. 백업 위치: ${BACKUP_DIR}"
