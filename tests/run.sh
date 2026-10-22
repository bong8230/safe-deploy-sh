#!/usr/bin/env bash
# 로컬 폴더 두 개를 개발/운영 서버로 가정하고 safe-deploy.sh를 끝까지 실행해 본다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/safe-deploy.sh"
PASS=0
FAIL=0

setup() {
  T="$(mktemp -d)"
  mkdir -p "$T/src/js" "$T/src/classes" "$T/dst/js" "$T/dst/classes"
  echo "v1" > "$T/dst/js/app.js"
  echo "v1" > "$T/dst/classes/Order.class"
  echo "old" > "$T/dst/js/legacy.js"
  echo "v2" > "$T/src/js/app.js"
  echo "v1" > "$T/src/classes/Order.class"
  echo "new" > "$T/src/js/feature.js"
  echo "ignored" > "$T/src/README.txt"
  cat > "$T/deploy.conf" <<EOF
ENV_NAME="TEST"
SRC_DIR="$T/src"
DST_DIR="$T/dst"
INCLUDE_PATTERNS="*.js *.class"
BACKUP_ROOT="$T/backup"
LOG_ROOT="$T/logs"
RESTART_PATTERNS="[.]class$"
EOF
}

check() {
  local name="$1"; shift
  if "$@"; then
    echo "  ok   - $name"; PASS=$((PASS+1))
  else
    echo "  FAIL - $name"; FAIL=$((FAIL+1))
  fi
}

echo "# select 모드: 1번 파일만 골라 반영"
setup
printf '1\nTEST\ny\n' | "$SCRIPT" -c "$T/deploy.conf" -m select > "$T/out.txt"
check "app.js가 v2로 바뀜"            grep -qx v2 "$T/dst/js/app.js"
check "선택 안 한 feature.js는 없음"   test ! -e "$T/dst/js/feature.js"
check "legacy.js는 삭제되지 않음"      test -e "$T/dst/js/legacy.js"
check "기존 app.js(v1)가 백업됨"       bash -c "grep -rqx v1 '$T/backup' --include=app.js"
check "요약 로그에 SUCCESS 기록"       grep -q "result=SUCCESS" "$T"/logs/*/summary_*.log
rm -rf "$T"

echo "# full 모드: 삭제 포함 동기화"
setup
printf 'TEST\nDELETE\ny\n' | "$SCRIPT" -c "$T/deploy.conf" -m full > "$T/out.txt"
check "feature.js 추가됨"             test -e "$T/dst/js/feature.js"
check "legacy.js 삭제됨"              test ! -e "$T/dst/js/legacy.js"
check "삭제된 legacy.js가 백업됨"      bash -c "find '$T/backup' -name legacy.js | grep -q ."
check "포함 패턴 밖 파일은 무시"        test ! -e "$T/dst/README.txt"
rm -rf "$T"

echo "# 환경명을 틀리면 아무것도 바뀌지 않음"
setup
if printf '1\nPROD\n' | "$SCRIPT" -c "$T/deploy.conf" -m select > "$T/out.txt" 2>&1; then
  check "비정상 종료" false
else
  check "비정상 종료" true
fi
check "app.js 그대로 v1"              grep -qx v1 "$T/dst/js/app.js"
check "요약 로그에 CONFIRM_FAIL 기록"  grep -q "result=CONFIRM_FAIL" "$T"/logs/*/summary_*.log
rm -rf "$T"

echo "# 허용되지 않은 접속 IP는 차단"
setup
echo 'ALLOWED_IP_PREFIXES="10.0."' >> "$T/deploy.conf"
if SSH_CLIENT="192.168.0.5 50000 22" "$SCRIPT" -c "$T/deploy.conf" < /dev/null > "$T/out.txt" 2>&1; then
  check "차단됨" false
else
  check "차단됨" true
fi
check "app.js 그대로 v1"              grep -qx v1 "$T/dst/js/app.js"
rm -rf "$T"

echo "# 번호 선택 형식 오류는 다시 묻기"
setup
printf 'abc\n9\n1-2\nTEST\ny\n' | "$SCRIPT" -c "$T/deploy.conf" -m select > "$T/out.txt"
check "재입력 안내 출력"               grep -q "올바르지 않거나" "$T/out.txt"
check "1-2 범위 선택으로 두 파일 반영"   bash -c "grep -qx v2 '$T/dst/js/app.js' && test -e '$T/dst/js/feature.js'"
rm -rf "$T"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
