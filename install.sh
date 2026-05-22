#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# Docker External Drive — Auto-routing Setup
# ═══════════════════════════════════════════════════════════════════════════════
#
# What this does:
#   • Routes Docker's data-dir to any drive labeled "DOCKER" automatically.
#   • Plug the drive in  → udev fires → Docker switches to external.
#   • Unplug the drive   → udev fires → Docker falls back to local.
#   • Works with any device path (/dev/sdb, /dev/sdc, /dev/nvme0n1p2, …).
#   • No path hardcoding — detection is purely label-based.
#
# Usage:
#   sudo bash docker-external-install.sh
#
# To label an existing partition (if not already labeled):
#   sudo e2label /dev/sdXN DOCKER
#
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Paths (edit only if you want a different layout) ──────────────────────────
MOUNT_BASE="/mnt/docker-external"       # where the DOCKER partition is mounted
DOCKER_DATA="/var/lib/docker"           # Docker's expected data dir (symlink)
DOCKER_LOCAL="/var/lib/docker-local"    # local fallback when drive is absent
DOCKER_EXT="$MOUNT_BASE/docker"        # actual data dir on the external drive

ATTACH_BIN="/usr/local/bin/docker-external-attach"
DETACH_BIN="/usr/local/bin/docker-external-detach"
ATTACH_SVC="/etc/systemd/system/docker-external-attach.service"
DETACH_SVC="/etc/systemd/system/docker-external-detach.service"
UDEV_RULE="/etc/udev/rules.d/99-docker-external.rules"

# ── Helpers ───────────────────────────────────────────────────────────────────
step()  { echo; echo "══> $*"; }
ok()    { echo "    ✓  $*"; }
skip()  { echo "    –  $*"; }
warn()  { echo "    ⚠  $*"; }

[[ $EUID -eq 0 ]] || { echo "Run with: sudo bash docker-external-install.sh"; exit 1; }

# ── Step 1: Mount point ───────────────────────────────────────────────────────
step "[1/7] Mount point"
mkdir -p "$MOUNT_BASE"
ok "$MOUNT_BASE ready"

# ── Step 2: Optional — format a partition with DOCKER label ───────────────────
step "[2/7] Detect or create DOCKER-labeled partition"
CURRENT_DEV=$(blkid -L DOCKER 2>/dev/null || true)

if [[ -n "$CURRENT_DEV" ]]; then
    ok "Found DOCKER partition: $CURRENT_DEV  (no format needed)"
else
    warn "No partition with label DOCKER found."
    echo
    echo "    Available block devices:"
    lsblk -p -e 7 -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT
    echo
    read -r -p "    Partition to format as DOCKER drive (blank to skip): " TARGET_DEV

    if [[ -n "$TARGET_DEV" && -b "$TARGET_DEV" ]]; then
        echo
        warn "This will ERASE all data on $TARGET_DEV."
        read -r -p "    Type YES to confirm: " CONFIRM
        if [[ "$CONFIRM" == "YES" ]]; then
            mkfs.ext4 -L DOCKER -F "$TARGET_DEV"
            ok "Formatted $TARGET_DEV (label=DOCKER, ext4)"
        else
            skip "Format cancelled — label your drive manually with:"
            echo "       sudo e2label /dev/sdXN DOCKER"
        fi
    else
        skip "No partition chosen — you can label a drive later and hot-plug it"
    fi
fi

# ── Step 3: Migrate existing Docker data to local fallback ────────────────────
step "[3/7] Migrate current Docker data → local fallback"
systemctl stop docker 2>/dev/null || true

if [[ -d "$DOCKER_DATA" && ! -L "$DOCKER_DATA" ]]; then
    echo "    Moving $DOCKER_DATA → $DOCKER_LOCAL ..."
    mv "$DOCKER_DATA" "$DOCKER_LOCAL"
    ok "Migrated (images/containers preserved in local fallback)"
elif [[ -L "$DOCKER_DATA" ]]; then
    skip "$DOCKER_DATA is already a symlink — nothing to migrate"
    mkdir -p "$DOCKER_LOCAL"
else
    mkdir -p "$DOCKER_LOCAL"
    ok "Created empty local fallback at $DOCKER_LOCAL"
fi

# ── Step 4: Attach script (embedded) ─────────────────────────────────────────
step "[4/7] Install attach/detach scripts"

cat > "$ATTACH_BIN" << 'ATTACH_SCRIPT'
#!/usr/bin/env bash
# docker-external-attach
# Mounts the DOCKER-labeled partition and routes Docker to it.
set -euo pipefail

LABEL="DOCKER"
MOUNT_BASE="/mnt/docker-external"
DOCKER_DATA="/var/lib/docker"
DOCKER_EXT="$MOUNT_BASE/docker"

log() { echo "[docker-external] $*" | systemd-cat -t docker-external -p info; echo "[docker-external] $*"; }

DEV=$(blkid -L "$LABEL" 2>/dev/null || true)
if [[ -z "$DEV" ]]; then
    log "ERROR: no partition labeled $LABEL found — aborting attach"
    exit 1
fi

log "Attaching $DEV → $MOUNT_BASE"
mkdir -p "$MOUNT_BASE"

if ! mountpoint -q "$MOUNT_BASE"; then
    mount -o defaults,nofail "$DEV" "$MOUNT_BASE"
    log "Mounted $DEV at $MOUNT_BASE"
else
    log "$MOUNT_BASE already mounted"
fi

mkdir -p "$DOCKER_EXT"

systemctl stop docker 2>/dev/null || true

rm -f "$DOCKER_DATA"
ln -s "$DOCKER_EXT" "$DOCKER_DATA"
log "Symlink: $DOCKER_DATA → $DOCKER_EXT"

systemctl start docker
log "✓ Docker is now running on external drive ($DEV)"
ATTACH_SCRIPT
chmod +x "$ATTACH_BIN"
ok "Installed $ATTACH_BIN"

cat > "$DETACH_BIN" << 'DETACH_SCRIPT'
#!/usr/bin/env bash
# docker-external-detach
# Switches Docker back to local fallback when the DOCKER drive is removed.
set -euo pipefail

MOUNT_BASE="/mnt/docker-external"
DOCKER_DATA="/var/lib/docker"
DOCKER_LOCAL="/var/lib/docker-local"

log() { echo "[docker-external] $*" | systemd-cat -t docker-external -p info; echo "[docker-external] $*"; }

log "Drive removed — falling back to $DOCKER_LOCAL"
systemctl stop docker 2>/dev/null || true

rm -f "$DOCKER_DATA"
mkdir -p "$DOCKER_LOCAL"
ln -s "$DOCKER_LOCAL" "$DOCKER_DATA"
log "Symlink: $DOCKER_DATA → $DOCKER_LOCAL"

# Lazy unmount — safe even if the drive was yanked without proper ejection
umount -l "$MOUNT_BASE" 2>/dev/null || true
log "Unmounted $MOUNT_BASE"

systemctl start docker
log "✓ Docker is now running on local fallback ($DOCKER_LOCAL)"
DETACH_SCRIPT
chmod +x "$DETACH_BIN"
ok "Installed $DETACH_BIN"

# ── Step 5: Systemd services ──────────────────────────────────────────────────
step "[5/7] Systemd services"

cat > "$ATTACH_SVC" << 'EOF'
[Unit]
Description=Attach DOCKER external drive and route Docker to it
After=local-fs.target udev.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/docker-external-attach
RemainAfterExit=yes
TimeoutSec=30

[Install]
WantedBy=multi-user.target
EOF

cat > "$DETACH_SVC" << 'EOF'
[Unit]
Description=Detach DOCKER external drive and restore local Docker storage
DefaultDependencies=no
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/docker-external-detach
TimeoutSec=30
EOF

systemctl daemon-reload
ok "Services installed and daemon reloaded"

# ── Step 6: udev rules ────────────────────────────────────────────────────────
step "[6/7] udev rules"

cat > "$UDEV_RULE" << 'EOF'
# ── Docker External Drive — Auto-routing ──────────────────────────────────────
# Fires on ANY block device with filesystem label == DOCKER.
# Device path doesn't matter: /dev/sdb1, /dev/sdc3, /dev/nvme0n1p2, etc.

# Drive plugged in → attach and switch Docker to it
ACTION=="add", SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="DOCKER", \
    RUN+="/usr/bin/systemd-run --no-block --unit=docker-external-attach \
    /usr/local/bin/docker-external-attach"

# Drive removed → detach and fall back to local storage
ACTION=="remove", SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="DOCKER", \
    RUN+="/usr/bin/systemd-run --no-block --unit=docker-external-detach \
    /usr/local/bin/docker-external-detach"
EOF

udevadm control --reload-rules
ok "udev rules loaded — $UDEV_RULE"

# ── Step 7: Activate now ──────────────────────────────────────────────────────
step "[7/7] Activate"

NOW_DEV=$(blkid -L DOCKER 2>/dev/null || true)
if [[ -n "$NOW_DEV" ]]; then
    echo "    DOCKER drive is already connected ($NOW_DEV) — switching now..."
    "$ATTACH_BIN"
    ok "Docker routed to external drive"
else
    # No drive connected — set up local fallback symlink and start Docker
    rm -f "$DOCKER_DATA"
    ln -s "$DOCKER_LOCAL" "$DOCKER_DATA"
    systemctl start docker 2>/dev/null || warn "Could not start Docker (check systemctl status docker)"
    ok "Docker running on local fallback — plug DOCKER drive to auto-switch"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Docker External Drive — Installed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Plug any drive labeled DOCKER  →  auto-switches to it"
echo "  Unplug that drive              →  auto-falls back to local"
echo
echo "  External data : $DOCKER_EXT"
echo "  Local data    : $DOCKER_LOCAL"
echo "  Active link   : $DOCKER_DATA → $(readlink $DOCKER_DATA 2>/dev/null || echo '?')"
echo "  udev rule     : $UDEV_RULE"
echo "  Attach script : $ATTACH_BIN"
echo "  Detach script : $DETACH_BIN"
echo
echo "  To label an existing partition manually:"
echo "    sudo e2label /dev/sdXN DOCKER"
echo "  To check logs:"
echo "    journalctl -t docker-external -f"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
