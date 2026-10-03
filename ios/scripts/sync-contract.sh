#!/bin/sh
# Regenerates api/openapi.json from api/openapi.yaml, so the app and its tests
# can read the contract (and its examples) without a YAML parser.
#
#   ios/scripts/sync-contract.sh           # rewrite api/openapi.json
#   ios/scripts/sync-contract.sh --check   # fail if it's out of date (CI)
#
# Uses the system Ruby (YAML and JSON are in its standard library); nothing to install.
set -eu

root="$(cd "$(dirname "$0")/../.." && pwd)"
yaml="$root/api/openapi.yaml"
json="$root/api/openapi.json"

# Loads the YAML with safe_load (plain data only: an unquoted timestamp would load as
# a Time and fail here, rather than silently becoming a differently formatted string).
ruby -ryaml -rjson -e '
  yaml_path, json_path, mode = ARGV
  doc = YAML.safe_load(File.read(yaml_path))
  case mode
  when "--check"
    # Compare as data, so differences in JSON formatting between Ruby versions do not matter.
    current = (JSON.parse(File.read(json_path)) rescue nil)
    if current != doc
      warn "api/openapi.json is out of date with api/openapi.yaml."
      warn "Run ios/scripts/sync-contract.sh and commit the result."
      exit 1
    end
    puts "api/openapi.json is up to date."
  when nil
    File.write(json_path, JSON.pretty_generate(doc) + "\n")
    puts "Wrote api/openapi.json"
  else
    warn "usage: sync-contract.sh [--check]"
    exit 2
  end
' "$yaml" "$json" "$@"
