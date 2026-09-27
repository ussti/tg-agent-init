# Bash conventions (optional coder overlay)

- `set -euo pipefail` at the top of every script
- Quote every variable: `"$var"`, `"${arr[@]}"`
- Prefer `[[ ]]` over `[ ]`; prefer `$(...)` over backticks
- Check commands exist before use; fail loud with a clear message
- No secrets in scripts — read from `secrets/` or env
