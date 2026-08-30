#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu
TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)

"$TEST_DIR/common.sh"
"$TEST_DIR/config_library.sh"
"$TEST_DIR/config_cli.sh"
"$TEST_DIR/status_cli.sh"
"$TEST_DIR/hardware_library.sh"
"$TEST_DIR/config.sh"
"$TEST_DIR/algorithms.sh"
"$TEST_DIR/history.sh"
"$TEST_DIR/event_logging.sh"
sh "$TEST_DIR/runtime_health.sh"
"$TEST_DIR/lifecycle_modes.sh"
"$TEST_DIR/lifecycle_modem.sh"
"$TEST_DIR/lifecycle_reload.sh"
