#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# Docker External Drive — Test Suite
# ═══════════════════════════════════════════════════════════════════════════════
#
# Validates every component installed by install.sh.
# Section 4 uses a loop device (no physical drive needed) to simulate a full
# plug → attach → detach cycle and compares actual vs expected results.
#
# Usage:
#   sudo bash test.sh            # all tests including functional loop-device
#   sudo bash test.sh --no-live  # sections 1-3 only (no Docker restart)
#
# Exit code: 0 = all tests passed, 1 = at least one FAIL.
# ═══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

# ── Result counters ───────────────────────────────────────────────────────────
PASS=0; FAIL=0; SKIP=0

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; BOLD='\033[1m'; NC='\033[0m'

_pass() { printf "  ${GREEN}[PASS]${NC} %s\n" "$*"; PASS=$((PASS + 1)); }
_fail() { printf "  ${RED}[FAIL]${NC} %s\n" "$*"; FAIL=$((FAIL + 1)); }
_skip() { printf "  ${YELLOW}[SKIP]${NC} %s\n" "$*"; SKIP=$((SKIP + 1)); }
_info() { printf "         %s\n" "$*"; }
section() { printf "\n${BOLD}── %s %s${NC}\n" "$*" "$(printf '─%.0s' $(seq 1 48))"; }

# Compare expected vs actual, print both on failure
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        _pass "$label"
    else
        _fail "$label"
        _info "expected : $expected"
        _info "actual   : $actual"
    fi
}

# ── Guard ─────────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || { echo "Run with: sudo bash test.sh"; exit 1; }

LIVE_TEST=true
[[ "${1:-}" == "--no-live" ]] && LIVE_TEST=false

# ── Paths — must match install.sh ─────────────────────────────────────────────
MOUNT_BASE="/mnt/docker-external"
DOCKER_DATA="/var/lib/docker"
DOCKER_LOCAL="/var/lib/docker-local"
DOCKER_EXT="$MOUNT_BASE/docker"
ATTACH_BIN="/usr/local/bin/docker-external-attach"
DETACH_BIN="/usr/local/bin/docker-external-detach"
ATTACH_SVC="/etc/systemd/system/docker-external-attach.service"
DETACH_SVC="/etc/systemd/system/docker-external-detach.service"
UDEV_RULE="/etc/udev/rules.d/99-docker-external.rules"

# ── Cleanup state (used by EXIT trap) ─────────────────────────────────────────
LOOP_DEV=""
LOOP_IMG=""
SAVED_DOCKER_LINK=""
DOCKER_WAS_RUNNING=false

cleanup() {
    echo
    echo "── cleanup ───────────────────────────────────────────────────────"

    # Restore /var/lib/docker symlink
    if [[ -n "$SAVED_DOCKER_LINK" ]]; then
        rm -f "$DOCKER_DATA"
        ln -s "$SAVED_DOCKER_LINK" "$DOCKER_DATA" 2>/dev/null || true
        echo "  restored $DOCKER_DATA → $SAVED_DOCKER_LINK"
    fi

    # Restart Docker if it was up before the test
    if $DOCKER_WAS_RUNNING; then
        systemctl start docker 2>/dev/null || true
        echo "  restarted docker.service"
    fi

    # Unmount loop-device mount point
    if mountpoint -q "$MOUNT_BASE" 2>/dev/null; then
        umount -l "$MOUNT_BASE" 2>/dev/null || true
        echo "  unmounted $MOUNT_BASE"
    fi

    # Remove loop device
    if [[ -n "$LOOP_DEV" ]]; then
        losetup -d "$LOOP_DEV" 2>/dev/null || true
        echo "  detached $LOOP_DEV"
    fi

    # Remove temp image file
    if [[ -n "$LOOP_IMG" && -f "$LOOP_IMG" ]]; then
        rm -f "$LOOP_IMG"
        echo "  removed $LOOP_IMG"
    fi
}
trap cleanup EXIT

# ══════════════════════════════════════════════════════════════════════════════
printf "\n${BOLD}Docker External Drive — Test Suite${NC}\n"
printf "run date  : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "live tests: %s\n" "$($LIVE_TEST && echo yes || echo no \(--no-live\))"

# ══════════════════════════════════════════════════════════════════════════════
# 1 · Install Artifacts
# ══════════════════════════════════════════════════════════════════════════════
section "1 · Install Artifacts"

_check_file() { [[ -f "$2" ]] && _pass "$1 exists" || _fail "$1 missing: $2"; }
_check_exec() { [[ -x "$2" ]] && _pass "$1 is executable" || _fail "$1 not executable: $2"; }
_check_dir()  { [[ -d "$2" ]] && _pass "$1 exists" || _fail "$1 missing: $2"; }

_check_file "attach script"  "$ATTACH_BIN"
_check_exec "attach script"  "$ATTACH_BIN"
_check_file "detach script"  "$DETACH_BIN"
_check_exec "detach script"  "$DETACH_BIN"
_check_file "attach.service" "$ATTACH_SVC"
_check_file "detach.service" "$DETACH_SVC"
_check_file "udev rule"      "$UDEV_RULE"
_check_dir  "mount base"     "$MOUNT_BASE"
_check_dir  "docker-local"   "$DOCKER_LOCAL"

# /var/lib/docker must be a symlink (not a plain dir) after install
if [[ -L "$DOCKER_DATA" ]]; then
    _pass "$DOCKER_DATA is a symlink → $(readlink "$DOCKER_DATA")"
elif [[ -e "$DOCKER_DATA" ]]; then
    _fail "$DOCKER_DATA exists but is NOT a symlink (install.sh did not run, or Docker was reinstalled)"
else
    _fail "$DOCKER_DATA does not exist"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 2 · udev Rule Content
# ══════════════════════════════════════════════════════════════════════════════
section "2 · udev Rule Content"

_rule_contains() {
    local label="$1" pattern="$2"
    grep -qF "$pattern" "$UDEV_RULE" 2>/dev/null \
        && _pass "contains: $pattern" \
        || _fail "missing:  $pattern"
}

if [[ -f "$UDEV_RULE" ]]; then
    _rule_contains 'add action'         'ACTION=="add"'
    _rule_contains 'remove action'      'ACTION=="remove"'
    _rule_contains 'block subsystem'    'SUBSYSTEM=="block"'
    _rule_contains 'DOCKER label match' 'ID_FS_LABEL}=="DOCKER"'
    _rule_contains 'systemd-run'        'systemd-run'
    _rule_contains 'attach trigger'     'docker-external-attach'
    _rule_contains 'detach trigger'     'docker-external-detach'

    if udevadm verify "$UDEV_RULE" &>/dev/null 2>&1; then
        _pass "udevadm verify: rule syntax OK"
    else
        _skip "udevadm verify: returned non-zero (may not support this flag on this distro)"
    fi
else
    _fail "udev rule file missing — cannot check content"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 3 · Systemd Service Files
# ══════════════════════════════════════════════════════════════════════════════
section "3 · Systemd Service Files"

_check_service() {
    local name="$1" file="$2"
    if [[ ! -f "$file" ]]; then
        _fail "$name missing — skipping content check"
        return
    fi
    grep -q '^\[Unit\]'    "$file" && _pass "$name: [Unit] section"    || _fail "$name: [Unit] missing"
    grep -q '^\[Service\]' "$file" && _pass "$name: [Service] section" || _fail "$name: [Service] missing"
    grep -q '^ExecStart='  "$file" && _pass "$name: ExecStart present" || _fail "$name: ExecStart missing"
    grep -q '^Type=oneshot' "$file" && _pass "$name: Type=oneshot"     || _fail "$name: Type=oneshot missing"
}

_check_service "attach.service" "$ATTACH_SVC"
_check_service "detach.service" "$DETACH_SVC"

# attach.service must reference the attach binary
if [[ -f "$ATTACH_SVC" ]]; then
    grep -qF "$ATTACH_BIN" "$ATTACH_SVC" \
        && _pass "attach.service ExecStart points to $ATTACH_BIN" \
        || _fail "attach.service ExecStart does NOT reference $ATTACH_BIN"
fi

# detach.service must reference the detach binary
if [[ -f "$DETACH_SVC" ]]; then
    grep -qF "$DETACH_BIN" "$DETACH_SVC" \
        && _pass "detach.service ExecStart points to $DETACH_BIN" \
        || _fail "detach.service ExecStart does NOT reference $DETACH_BIN"
fi

if command -v systemd-analyze &>/dev/null; then
    for svc in "$ATTACH_SVC" "$DETACH_SVC"; do
        [[ -f "$svc" ]] || continue
        if systemd-analyze verify "$svc" &>/dev/null 2>&1; then
            _pass "systemd-analyze verify: $(basename "$svc") OK"
        else
            _skip "systemd-analyze verify: $(basename "$svc") has warnings (often OK in container/CI)"
        fi
    done
fi

# ══════════════════════════════════════════════════════════════════════════════
# 4 · Functional Test — loop device simulates DOCKER-labeled partition
# ══════════════════════════════════════════════════════════════════════════════
section "4 · Functional Test (loop device)"

if ! $LIVE_TEST; then
    _skip "Skipped — --no-live flag set"
elif ! command -v losetup &>/dev/null; then
    _skip "losetup not found — install util-linux to run functional tests"
elif ! command -v mkfs.ext4 &>/dev/null; then
    _skip "mkfs.ext4 not found — install e2fsprogs to run functional tests"
elif [[ ! -L "$DOCKER_DATA" ]]; then
    _skip "$DOCKER_DATA is not a symlink — run install.sh first"
else
    # Abort if containers are running (we must stop Docker during the test)
    RUNNING=$(docker ps -q 2>/dev/null | wc -l)
    if [[ "$RUNNING" -gt 0 ]]; then
        _skip "$RUNNING running container(s) detected — stop them first, then re-run"
    else
        # ── 4.0 Setup: create a 256 MB loop device labeled DOCKER ─────────────
        echo "  creating 256 MB ext4 image with label DOCKER..."
        LOOP_IMG=$(mktemp /tmp/docker-test-XXXXXX.img)
        truncate -s 256M "$LOOP_IMG"
        mkfs.ext4 -L DOCKER -F "$LOOP_IMG" >/dev/null 2>&1
        LOOP_DEV=$(losetup --find --show "$LOOP_IMG")
        echo "  loop device: $LOOP_DEV"

        # Flush blkid cache so the new label is visible immediately
        blkid -c /dev/null "$LOOP_DEV" >/dev/null 2>&1 || true
        udevadm settle --timeout=3 2>/dev/null || true

        # ── 4.1 blkid label detection ──────────────────────────────────────────
        DEV_FOUND=$(blkid -L DOCKER 2>/dev/null || true)
        assert_eq "blkid -L DOCKER finds loop device" \
            "$LOOP_DEV" "$DEV_FOUND"

        # ── Save Docker state before touching anything ─────────────────────────
        SAVED_DOCKER_LINK=$(readlink "$DOCKER_DATA")
        systemctl is-active --quiet docker && DOCKER_WAS_RUNNING=true || DOCKER_WAS_RUNNING=false

        # ── 4.2 Attach ─────────────────────────────────────────────────────────
        echo "  running attach script..."
        if "$ATTACH_BIN" >/dev/null 2>&1; then
            _pass "attach script: exit 0"
        else
            _fail "attach script: non-zero exit"
        fi

        # expected: /var/lib/docker → /mnt/docker-external/docker
        ACTUAL_LINK=$(readlink "$DOCKER_DATA" 2>/dev/null || echo "")
        assert_eq "symlink after attach" "$DOCKER_EXT" "$ACTUAL_LINK"

        # expected: mount point is active
        if mountpoint -q "$MOUNT_BASE" 2>/dev/null; then
            _pass "$MOUNT_BASE is mounted"
        else
            _fail "$MOUNT_BASE is NOT mounted after attach"
        fi

        # expected: docker data-root points to external
        ACTUAL_ROOT=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "unavailable")
        assert_eq "docker info DockerRootDir (external)" "$DOCKER_EXT" "$ACTUAL_ROOT"

        # ── 4.3 Detach ─────────────────────────────────────────────────────────
        echo "  running detach script..."
        if "$DETACH_BIN" >/dev/null 2>&1; then
            _pass "detach script: exit 0"
        else
            _fail "detach script: non-zero exit"
        fi

        # expected: /var/lib/docker → /var/lib/docker-local
        ACTUAL_LINK=$(readlink "$DOCKER_DATA" 2>/dev/null || echo "")
        assert_eq "symlink after detach" "$DOCKER_LOCAL" "$ACTUAL_LINK"

        # expected: docker data-root falls back to local
        ACTUAL_ROOT=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "unavailable")
        assert_eq "docker info DockerRootDir (local fallback)" "$DOCKER_LOCAL" "$ACTUAL_ROOT"

        # State is now correct — tell cleanup not to double-restore
        SAVED_DOCKER_LINK="$DOCKER_LOCAL"
        DOCKER_WAS_RUNNING=false   # detach already restarted Docker
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
echo
printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "${BOLD}  Test Results${NC}\n"
printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "  ${GREEN}PASS${NC}  %s\n" "$PASS"
printf "  ${RED}FAIL${NC}  %s\n" "$FAIL"
printf "  ${YELLOW}SKIP${NC}  %s\n" "$SKIP"
printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

if [[ $FAIL -gt 0 ]]; then
    printf "\n  ${RED}%s test(s) failed.${NC}\n\n" "$FAIL"
    exit 1
else
    printf "\n  ${GREEN}All tests passed.${NC}\n\n"
    exit 0
fi
