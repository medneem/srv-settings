#!/usr/bin/env bash
# Real pipe + pseudoterminal smoke test using a fake archive, no network.
# Intended only for ephemeral GitHub-hosted Ubuntu CI runners.
set -euo pipefail
BASE_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
temp="$(mktemp -d)"
target=/opt/srv-settings
if [[ -e "$target" ]]; then
  echo "Refusing to overwrite an existing $target during smoke test" >&2
  exit 1
fi
cleanup() {
  sudo rm -rf -- "$target"
  rm -rf -- "$temp"
}
trap cleanup EXIT
mkdir -p "$temp/fixture/srv-settings-main" "$temp/mock"
cat > "$temp/fixture/srv-settings-main/setup.sh" <<'SETUP'
#!/usr/bin/env bash
set -euo pipefail
IFS= read -r -p "Interactive token: " value
[[ "$value" == "tty-ok" ]]
printf 'tty-ok\n' > "$TEST_RECEIPT"
SETUP
tar -czf "$temp/fixture.tar.gz" -C "$temp/fixture" srv-settings-main
cat > "$temp/mock/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
output=''
while (( $# > 0 )); do
  case "$1" in
    -o) output="$2"; shift 2;;
    *) shift;;
  esac
done
[[ -n "$output" ]]
cp -- "$TEST_ARCHIVE" "$output"
MOCK
chmod +x "$temp/mock/curl"
receipt="$temp/receipt.txt"
# The bootstrap comes from a pipe; setup.sh must read from /dev/tty.
# 'script' creates the pseudoterminal that CI does not normally provide.
{ sleep 1; printf 'tty-ok\n'; sleep 1; } |
  script -q -e -c "cat '$BASE_DIR/bootstrap.sh' | sudo env PATH='$temp/mock:$PATH' TEST_ARCHIVE='$temp/fixture.tar.gz' TEST_RECEIPT='$receipt' bash" /dev/null \
  > "$temp/output.log" 2>&1 || {
    cat "$temp/output.log" >&2
    exit 1
  }
if [[ "$(cat "$receipt" 2>/dev/null)" != tty-ok ]]; then
  cat "$temp/output.log" >&2
  echo "Menu did not read from the tty" >&2
  exit 1
fi
printf 'bootstrap curl-pipe interactive smoke test: OK\n'
