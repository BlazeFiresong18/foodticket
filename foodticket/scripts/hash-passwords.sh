#!/usr/bin/env bash
# Compile and run the one-off plaintext-password hashing migration.
set -euo pipefail
cd "$(dirname "$0")/.."
eval "$(opam env 2>/dev/null)" || true
if [ -f .env ]; then set -a; . ./.env; set +a; fi
mkdir -p _tools
ocamlfind ocamlopt -package unix,safepass,mysql -linkpkg \
  tools/hash_passwords.ml -o _tools/hash_passwords
rm -f tools/hash_passwords.cm* tools/hash_passwords.o
./_tools/hash_passwords
