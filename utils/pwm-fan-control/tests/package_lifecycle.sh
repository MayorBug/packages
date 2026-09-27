#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$TEST_DIR/.." && pwd)
LIFECYCLE=$ROOT/files/usr/lib/pwm-fan/package-lifecycle.sh
MAKEFILE=$ROOT/Makefile
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT INT TERM
LOG=$TEST_TMP/init.log
PID_FILE=$TEST_TMP/pid

fail()
{
	printf 'not ok - %s\n' "$1" >&2
	exit 1
}

pass()
{
	printf 'ok - %s\n' "$1"
}

cat > "$TEST_TMP/init" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >> "$TEST_INIT_LOG"
EOF
chmod +x "$TEST_TMP/init"

grep -Fq 'define Package/pwm-fan-control/postinst' "$MAKEFILE" ||
	fail 'package post-install hook is not defined'
grep -Fq '/usr/lib/pwm-fan/package-lifecycle.sh' "$MAKEFILE" ||
	fail 'package post-install hook is not wired to lifecycle helper'
grep -Fq '$(INSTALL_BIN) ./files/usr/lib/pwm-fan/package-lifecycle.sh' "$MAKEFILE" ||
	fail 'package lifecycle helper is not installed executable'
pass 'package post-install hook installs and invokes lifecycle helper'

: > "$LOG"
TEST_INIT_LOG=$LOG PWM_FAN_PACKAGE_INIT=$TEST_TMP/init \
PWM_FAN_PACKAGE_PID_FILE=$PID_FILE "$LIFECYCLE"
[ "$(cat "$LOG")" = "enable
start" ] || fail 'first installation did not enable and start the controller'
pass 'first installation enables and starts the controller'

: > "$LOG"
printf '%s\n' "$$" > "$PID_FILE"
TEST_INIT_LOG=$LOG PWM_FAN_PACKAGE_INIT=$TEST_TMP/init \
PWM_FAN_PACKAGE_PID_FILE=$PID_FILE PKG_UPGRADE=1 "$LIFECYCLE"
[ "$(cat "$LOG")" = restart ] || fail 'running upgrade did not restart the controller'
pass 'upgrade restarts the already-running controller'

: > "$LOG"
printf '99999999\n' > "$PID_FILE"
TEST_INIT_LOG=$LOG PWM_FAN_PACKAGE_INIT=$TEST_TMP/init \
PWM_FAN_PACKAGE_PID_FILE=$PID_FILE PKG_UPGRADE=1 "$LIFECYCLE"
[ ! -s "$LOG" ] || fail 'upgrade started an intentionally stopped controller'
pass 'upgrade preserves an intentionally stopped controller'

: > "$LOG"
TEST_INIT_LOG=$LOG PWM_FAN_PACKAGE_INIT=$TEST_TMP/init \
PWM_FAN_PACKAGE_PID_FILE=$PID_FILE IPKG_INSTROOT=$TEST_TMP/root "$LIFECYCLE"
[ ! -s "$LOG" ] || fail 'image-root installation attempted to manage a host service'
pass 'image-root installation performs no service action'
