#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DBLP_URL="${DBLP_URL:-https://dblp.org/pid/20/2537.bib?param=1}"
TARGET_BIB="${TARGET_BIB:-${REPO_ROOT}/_bibliography/2537_name.bib}"

if [[ ! -f "${TARGET_BIB}" ]]; then
  echo "Target bibliography not found: ${TARGET_BIB}" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

downloaded_bib="${tmp_dir}/dblp.bib"
new_entries_bib="${tmp_dir}/new_entries.bib"

curl -fsSL "${DBLP_URL}" -o "${downloaded_bib}"

awk -v out="${new_entries_bib}" '
function extract_key(line, key) {
  key = line
  sub(/^[^{]*\{/, "", key)
  sub(/,.*/, "", key)
  return key
}

function normalize_newlines(text) {
  sub(/\n+$/, "", text)
  return text
}

function maybe_mark_skip(entry,   line_count, lines, i, is_article, is_corr, has_skip, prev_idx, rebuilt) {
  line_count = split(entry, lines, /\n/)
  is_article = (lines[1] ~ /^@article\{/)
  is_corr = 0
  has_skip = 0

  for (i = 1; i <= line_count; i++) {
    if (lines[i] ~ /^[[:space:]]*journal[[:space:]]*=[[:space:]]*\{CoRR\},?[[:space:]]*$/) {
      is_corr = 1
    }
    if (lines[i] ~ /^[[:space:]]*note[[:space:]]*=[[:space:]]*\{skip\},?[[:space:]]*$/) {
      has_skip = 1
    }
  }

  if (!(is_article && is_corr) || has_skip) {
    return entry
  }

  prev_idx = 0
  for (i = line_count - 1; i >= 1; i--) {
    if (lines[i] ~ /^[[:space:]]*$/) {
      continue
    }
    prev_idx = i
    break
  }

  if (prev_idx == 0) {
    return entry
  }

  if (lines[prev_idx] !~ /,[[:space:]]*$/) {
    lines[prev_idx] = lines[prev_idx] ","
  }

  rebuilt = ""
  for (i = 1; i <= line_count; i++) {
    if (i == line_count) {
      rebuilt = rebuilt "  note         = {skip}\n"
    }
    rebuilt = rebuilt lines[i]
    if (i < line_count) {
      rebuilt = rebuilt "\n"
    }
  }

  return rebuilt
}

function flush_entry(   lines, key, entry_to_write) {
  if (entry == "") {
    return
  }

  split(entry, lines, /\n/)
  key = extract_key(lines[1])

  if (!(key in existing_keys)) {
    entry_to_write = maybe_mark_skip(normalize_newlines(entry))
    print entry_to_write >> out
    print "" >> out
  }

  entry = ""
}

FNR == NR {
  if ($0 ~ /^@/) {
    existing_keys[extract_key($0)] = 1
  }
  next
}

{
  if ($0 ~ /^@/) {
    flush_entry()
  }

  if (entry == "") {
    entry = $0
  } else {
    entry = entry "\n" $0
  }
}

END {
  flush_entry()
}
' "${TARGET_BIB}" "${downloaded_bib}"

if [[ ! -s "${new_entries_bib}" ]]; then
  echo "No new entries found."
  exit 0
fi

python3 - "${TARGET_BIB}" "${new_entries_bib}" <<'PY'
import re
import sys
from pathlib import Path

target_path = Path(sys.argv[1])
new_entries_path = Path(sys.argv[2])

target_text = target_path.read_text()
new_entries_text = new_entries_path.read_text().strip()

if target_text.startswith("---\n"):
    parts = target_text.split("---\n", 2)
    if len(parts) == 3:
        front_matter = "---\n---\n\n"
        body = parts[2].lstrip("\n")
    else:
        front_matter = ""
        body = target_text
else:
    front_matter = ""
    body = target_text

def split_entries(text: str):
    text = text.strip()
    if not text:
        return []
    parts = re.split(r'(?m)(?=^@)', text)
    return [part.strip() for part in parts if part.strip()]

def entry_year(entry: str):
    match = re.search(r'\byear\s*=\s*[{" ]*(\d{4})', entry, re.IGNORECASE)
    return int(match.group(1)) if match else -1

entries = split_entries(new_entries_text)
entries = sorted(enumerate(entries), key=lambda item: (-entry_year(item[1]), item[0]))
sorted_entries_text = "\n\n".join(entry for _, entry in entries)

existing_body = body.strip()
sections = [section for section in (sorted_entries_text, existing_body) if section]
new_body = "\n\n".join(sections)

target_path.write_text(front_matter + new_body + "\n")
PY

new_count="$(grep -c '^@' "${new_entries_bib}" || true)"
echo "Prepended ${new_count} new entr$( [[ "${new_count}" == "1" ]] && printf 'y' || printf 'ies' ) to ${TARGET_BIB}."
