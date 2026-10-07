#!/usr/bin/env bash
# doctor-hint.sh -- last lines of install-server.sh: while the server has no doctor, say
# so and print the one command that installs it. Silent once the doctor is enabled.
# Usage: doctor-hint.sh <KIT_DIR>
set -euo pipefail
KIT_DIR="${1:?usage: doctor-hint.sh <KIT_DIR>}"
if command -v systemctl > /dev/null \
   && systemctl is-enabled --quiet agent-doctor.service 2> /dev/null; then
  exit 0
fi
echo
echo "== Agent is up. One step left: the doctor"
echo "  A second bot with root that fixes your agents. Create one more bot in @BotFather,"
echo "  then run as root:"
echo "  sudo bash $KIT_DIR/install-doctor.sh"
