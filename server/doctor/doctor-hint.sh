#!/usr/bin/env bash
# doctor-hint.sh -- last lines of install-server.sh: while the server has no doctor, say
# so and print the commands that install it. Silent once the doctor is enabled.
# Root runs the doctor installer only from a root-owned clone, never from an agent's
# checkout (the agent can write there), so the hint never names the caller's kit dir.
# Usage: doctor-hint.sh   (any argument is ignored, kept for old callers)
set -euo pipefail
if command -v systemctl > /dev/null \
   && systemctl is-enabled --quiet agent-doctor.service 2> /dev/null; then
  exit 0
fi
echo
echo "== Agent is up. One step left: the doctor"
echo "  A second bot with root that fixes your agents. Create one more bot in @BotFather,"
echo "  then run as root:"
echo "  sudo git clone https://github.com/ussti/tg-agent-init /opt/agent-doctor/kit"
echo "  sudo bash /opt/agent-doctor/kit/install-doctor.sh"
