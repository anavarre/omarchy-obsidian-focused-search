#!/usr/bin/env bash
# Omarchy obsidian-focused-search plugin: list searchable entries across every vault.
# The output is a stream of header lines (prefixed with #) and tab-delimited
# rows. Filtering happens client-side (FuzzySearch.js), so every entry is
# emitted.
#
# Headers, one per vault, emitted before that vault's rows:
#   #vault \t <display name> \t <absolute path> \t <0|1 daily enabled> \t <obsidian vault name>
# The display name is the directory basename, disambiguated as
# "<parent>/<base>" when two vaults share a basename. The obsidian vault name
# is the plain basename, which is what obsidian:// URIs expect.
#
# Rows: Name \t Type \t Path \t Vault display name \t Tags \t Properties \t URI
#
# Tags are space-separated and come from the note's YAML frontmatter and its
# inline #tags (code fences excluded); the field is empty for canvases, bases
# and untagged notes.
#
# Properties are the note's other YAML frontmatter keys, as "key=value" pairs
# joined by \x1f (a list-valued key contributes one pair per item). Keys are
# lowercased; values keep their case and are stripped of quotes and [[ ]].
#
# The URI is the only script-generated field. It is URL-encoded, so it never
# contains literal tabs or newlines, and the client launches it with
# Util.execArgv (no shell). Display fields are stripped of tabs so a
# filename can never shift columns into the URI field.
#
# Usage: search.sh [VAULT_PATH...] [--show-daily 0|1] [--show-templates 0|1]
#   --vault PATH  same as a positional VAULT_PATH argument; repeatable
# Vault paths may be given as arguments; otherwise every vault in the Obsidian
# configuration is listed. Daily notes and templates are resolved per vault
# from its own plugin settings (.obsidian/daily-notes.json, periodic-notes
# data, .obsidian/templates.json) instead of matching the words
# "daily"/"template" in file paths.

set -euo pipefail

home="$HOME"
vault_config="$home/.config/obsidian/obsidian.json"

vault_args=()
show_daily=1
show_templates=0

while [[ $# -gt 0 ]]; do
  case "$1" in
  --vault=*)
    vault_args+=("${1#--vault=}")
    shift
    ;;
  --vault)
    [[ -n "${2:-}" ]] && vault_args+=("$2")
    shift 2
    ;;
  --show-daily=* | --show-daily-notes=*)
    show_daily="${1#*=}"
    shift
    ;;
  --show-daily | --show-daily-notes)
    show_daily="${2:-1}"
    shift 2
    ;;
  --show-templates=*)
    show_templates="${1#*=}"
    shift
    ;;
  --show-templates)
    show_templates="${2:-1}"
    shift 2
    ;;
  --*)
    shift
    ;;
  *)
    vault_args+=("$1")
    shift
    ;;
  esac
done

if [[ "$show_daily" == "1" || "$show_daily" == "true" ]]; then show_daily=1; else show_daily=0; fi
if [[ "$show_templates" == "1" || "$show_templates" == "true" ]]; then show_templates=1; else show_templates=0; fi

# Collect candidate vault paths: explicit arguments win, otherwise every vault
# known to Obsidian, most-recently-used first so the primary vault leads.
raw_paths=()
if [[ ${#vault_args[@]} -gt 0 ]]; then
  raw_paths=("${vault_args[@]}")
elif [[ -f "$vault_config" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && raw_paths+=("$line")
  done < <(jq -r '.vaults | to_entries | sort_by(-(.value.ts // 0)) | .[].value.path // empty' "$vault_config" 2>/dev/null || true)
fi

vault_paths=()
for p in "${raw_paths[@]}"; do
  p="${p#"${p%%[![:space:]]*}"}"
  p="${p%"${p##*[![:space:]]}"}"
  p="${p/#\~/$home}"
  p="${p%/}"
  [[ -n "$p" && -d "$p" ]] || continue
  dup=0
  for seen in ${vault_paths[@]+"${vault_paths[@]}"}; do
    if [[ "$seen" == "$p" ]]; then
      dup=1
      break
    fi
  done
  [[ "$dup" -eq 1 ]] || vault_paths+=("$p")
done

[[ ${#vault_paths[@]} -gt 0 ]] || exit 0

# Two vaults may share a basename (".../Work" twice). Names are the handle the
# user types after @, so disambiguate collisions with the parent directory.
declare -A basename_count=()
for p in "${vault_paths[@]}"; do
  b="$(basename "$p")"
  basename_count["$b"]=$((${basename_count["$b"]:-0} + 1))
done

is_truthy() {
  case "${1,,}" in
  1 | true | yes) return 0 ;;
  *) return 1 ;;
  esac
}

emit_vault() {
  local vault_path="$1"
  local vault_name display_name encoded_vault obsidian_dir
  vault_name="$(basename "$vault_path")"
  display_name="$vault_name"
  if [[ "${basename_count["$vault_name"]:-1}" -gt 1 ]]; then
    display_name="$(basename "$(dirname "$vault_path")")/$vault_name"
  fi
  encoded_vault="$(printf '%s' "$vault_name" | jq -sRr @uri)"
  obsidian_dir="$vault_path/.obsidian"

  local daily_dir="" daily_enabled=0
  local periodic_data="$obsidian_dir/plugins/periodic-notes/data.json"
  if [[ -f "$periodic_data" ]]; then
    local p_enabled p_folder p_format
    p_enabled="$(jq -r '.daily.enabled // true' "$periodic_data" 2>/dev/null || true)"
    p_folder="$(jq -r '.daily.folder // empty' "$periodic_data" 2>/dev/null || true)"
    p_format="$(jq -r '.daily.format // empty' "$periodic_data" 2>/dev/null || true)"
    if is_truthy "$p_enabled" && [[ -n "$p_folder" || -n "$p_format" ]]; then
      daily_enabled=1
      daily_dir="$p_folder"
    fi
  fi

  if [[ "$daily_enabled" -eq 0 ]]; then
    local core_enabled="true"
    if [[ -f "$obsidian_dir/core-plugins.json" ]]; then
      core_enabled="$(jq -r '."daily-notes" // true' "$obsidian_dir/core-plugins.json" 2>/dev/null || echo true)"
    fi
    if is_truthy "$core_enabled"; then
      daily_enabled=1
      if [[ -f "$obsidian_dir/daily-notes.json" ]]; then
        local c_folder
        c_folder="$(jq -r '.folder // empty' "$obsidian_dir/daily-notes.json" 2>/dev/null || true)"
        [[ -n "$c_folder" ]] && daily_dir="$c_folder"
      fi
    else
      daily_enabled=0
    fi
  fi

  daily_dir="${daily_dir#/}"
  daily_dir="${daily_dir%/}"

  local templates_dir=""
  if [[ -f "$obsidian_dir/templates.json" ]]; then
    templates_dir="$(jq -r '.folder // empty' "$obsidian_dir/templates.json" 2>/dev/null || true)"
  fi
  templates_dir="${templates_dir#/}"
  templates_dir="${templates_dir%/}"

  local daily_template=""
  if [[ -f "$obsidian_dir/daily-notes.json" ]]; then
    daily_template="$(jq -r '.template // empty' "$obsidian_dir/daily-notes.json" 2>/dev/null || true)"
  fi
  daily_template="${daily_template#/}"
  daily_template="${daily_template%/}"

  printf '#vault\t%s\t%s\t%s\t%s\n' "${display_name//	/ }" "$vault_path" "$daily_enabled" "$vault_name"

  # Single-pass listing: fd streams NUL-separated paths into one python3
  # process that classifies, collects tags and percent-encodes every row. The
  # previous per-file `jq -sRr @uri` spawn cost ~0.6s on a few hundred notes.
  export OBS_ENCODED_VAULT="$encoded_vault" OBS_VAULT_PATH="$vault_path" OBS_DAILY_DIR="$daily_dir" OBS_TEMPLATES_DIR="$templates_dir" OBS_DAILY_TEMPLATE="$daily_template" OBS_SHOW_DAILY="$show_daily" OBS_SHOW_TEMPLATES="$show_templates" OBS_VAULT_LABEL="$display_name"
  fd -0 -e md -e canvas -e base --type file --strip-cwd-prefix --base-directory="$vault_path" | python3 -c '
import os, re, sys, urllib.parse
evault = os.environ["OBS_ENCODED_VAULT"].encode()
vault = os.environ["OBS_VAULT_PATH"].encode()
daily = os.environ["OBS_DAILY_DIR"].encode()
tpl = os.environ["OBS_TEMPLATES_DIR"].encode()
daily_tpl = os.environ["OBS_DAILY_TEMPLATE"].encode()
label = os.environ["OBS_VAULT_LABEL"].encode().replace(b"\t", b" ")
show_daily = os.environ["OBS_SHOW_DAILY"] == "1"
show_tpl = os.environ["OBS_SHOW_TEMPLATES"] == "1"

# Tags come from YAML frontmatter (tags: a, b / a "- b" list) and from inline
# #tags in the body, skipping fenced code blocks. Obsidian requires at least
# one non-numeric character, which keeps "#1" and markdown headings out.
# Every other frontmatter key is emitted as a property so the client can offer
# ":author" style filters; a list-valued key yields one pair per item.
TAG_RE = re.compile(r"(?:^|[\s(\[>])#([A-Za-z0-9_][A-Za-z0-9_/-]*)")
KEY_RE = re.compile(r"^([A-Za-z0-9_][A-Za-z0-9 _.-]*?)\s*:\s*(.*)$")
ITEM_RE = re.compile(r"^\s+-\s*(.+?)\s*$")
NONDIGIT = re.compile(r"[A-Za-z_/-]")
CTRL = re.compile(r"[\x00-\x1f\x7f]")
TAG_KEYS = ("tag", "tags")
MAX_BYTES = 262144
MAX_TAGS = 24
MAX_PROPS = 40

def scan(path):
    try:
        with open(path, "rb") as fh:
            text = fh.read(MAX_BYTES).decode("utf-8", "replace")
    except OSError:
        return [], []
    out, seen = [], set()
    props, pseen = [], set()
    def add(raw):
        t = raw.strip().strip("\"\x27").lstrip("#").strip().rstrip("/")
        if not t or " " in t or not NONDIGIT.search(t) or len(t) > 60:
            return
        key = t.lower()
        if key not in seen and len(out) < MAX_TAGS:
            seen.add(key)
            out.append(t)
    def addprop(key, raw):
        v = CTRL.sub(" ", raw).strip().strip("\"\x27").strip()
        if v.startswith("[[") and v.endswith("]]"):
            v = v[2:-2].split("|")[-1]
        v = v.strip()
        if not v or len(v) > 120 or not key or len(key) > 40:
            return
        sig = key + "=" + v.lower()
        if sig not in pseen and len(props) < MAX_PROPS:
            pseen.add(sig)
            props.append(key + "=" + v)
    lines = text.split("\n")
    body = 0
    if lines and lines[0].strip() == "---":
        end = 0
        for i in range(1, min(len(lines), 200)):
            if lines[i].strip() in ("---", "..."):
                end = i
                break
        if end:
            cur = ""
            for ln in lines[1:end]:
                if ln[:1].strip():
                    m = KEY_RE.match(ln)
                    if not m:
                        cur = ""
                        continue
                    cur = m.group(1).strip().lower()
                    val = m.group(2).strip()
                    if cur in TAG_KEYS:
                        for part in re.split(r"[,\s]+", val.strip("[]")):
                            add(part)
                    elif val.startswith("[") and val.endswith("]"):
                        for part in val[1:-1].split(","):
                            addprop(cur, part)
                    elif val:
                        addprop(cur, val)
                else:
                    item = ITEM_RE.match(ln)
                    if item and cur:
                        if cur in TAG_KEYS:
                            add(item.group(1))
                        else:
                            addprop(cur, item.group(1))
            body = end + 1
    fenced = False
    for ln in lines[body:]:
        stripped = ln.lstrip()
        if stripped.startswith("```") or stripped.startswith("~~~"):
            fenced = not fenced
            continue
        if fenced or "#" not in ln:
            continue
        for m in TAG_RE.finditer(ln):
            add(m.group(1))
    return out, props

rows = []
for raw in sys.stdin.buffer.read().split(b"\0"):
    if not raw or b"\n" in raw or b"\r" in raw:
        continue
    in_daily = bool(daily) and raw.startswith(daily + b"/")
    in_tpl = (bool(tpl) and raw.startswith(tpl + b"/")) or (bool(daily_tpl) and raw.startswith(daily_tpl))
    if (in_daily and not show_daily) or (in_tpl and not show_tpl):
        continue
    tags = b""
    props = b""
    if raw.endswith(b".canvas"):
        sub, name = b"Canvas", raw[:-7]
    elif raw.endswith(b".base"):
        sub, name = b"Base", raw[:-5]
    else:
        name = raw[:-3] if raw.endswith(b".md") else raw
        sub = b"Daily Note" if in_daily else (b"Template" if in_tpl else b"Note")
        tag_list, prop_list = scan(os.path.join(vault, raw))
        tags = " ".join(tag_list).encode()
        props = "\x1f".join(prop_list).encode()
    uri = b"obsidian://open?vault=" + evault + b"&file=" + urllib.parse.quote_from_bytes(raw, safe=b"").encode()
    disp = raw.replace(b"\t", b" ")
    rows.append(b"\t".join([name.replace(b"\t", b" "), sub, disp, label, tags, props, uri]))
sys.stdout.buffer.write(b"\n".join(rows) + (b"\n" if rows else b""))
'
}

for vault_path in "${vault_paths[@]}"; do
  emit_vault "$vault_path"
done
