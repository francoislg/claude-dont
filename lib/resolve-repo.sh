#!/usr/bin/env bash
# Sourced by dont.sh. Resolves, from $DONT_CWD, using only bash builtins:
#   DONT_REPO_KEY     normalized remote URL of the enclosing git repo
#                     (e.g. github.com/owner/repo), or empty
#   DONT_PROJECT_CFG  nearest .claude/dont-config.json among: the cwd, the
#                     repo/worktree root, and (inside a worktree) the main checkout
# Worktrees resolve to their main checkout's remote and config, so every
# worktree of a repo behaves like the main checkout.

dont_abs_path() {
  local path rest part out=""
  case "$2" in
    /*) path="$2" ;;
    *) path="${1%/}/$2" ;;
  esac
  rest="${path#/}/"
  while [[ -n "$rest" ]]; do
    part="${rest%%/*}"
    rest="${rest#*/}"
    case "$part" in
      ''|.) ;;
      ..) out="${out%/*}" ;;
      *) out="$out/$part" ;;
    esac
  done
  DONT_ABS="${out:-/}"
}

dont_normalize_remote() {
  local url="$1"
  case "$url" in
    *://*)
      url="${url#*://}"
      url="${url#*@}"
      case "$url" in
        *:*) url="${url%%:*}/${url#*/}" ;;
      esac
      ;;
    *)
      url="${url#*@}"
      case "$url" in
        *:*) url="${url%%:*}/${url#*:}" ;;
      esac
      ;;
  esac
  url="${url%/}"
  DONT_REPO_KEY="${url%.git}"
}

dont_read_remote() {
  local line section="" first_url="" origin_url="" value
  [[ -f "$1" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      '['*) section="$line" ;;
      url*=*)
        case "$section" in
          '[remote '*)
            value="${line#*=}"
            value="${value#"${value%%[![:space:]]*}"}"
            [[ -z "$first_url" ]] && first_url="$value"
            [[ "$section" == '[remote "origin"]' ]] && origin_url="$value"
            ;;
        esac
        ;;
    esac
  done < "$1"
  value="${origin_url:-$first_url}"
  [[ -n "$value" ]] && dont_normalize_remote "$value"
}

dont_resolve_repo() {
  local dir="$DONT_CWD" root="" gitdir="" common="" main="" line candidate
  DONT_REPO_KEY=""
  DONT_PROJECT_CFG="$DONT_CWD/.claude/dont-config.json"

  while [[ -n "$dir" ]]; do
    if [[ -e "$dir/.git" ]]; then
      root="$dir"
      break
    fi
    [[ "$dir" == "/" ]] && break
    dir="${dir%/*}"
    [[ -z "$dir" ]] && dir="/"
  done
  [[ -z "$root" ]] && return 0

  if [[ -d "$root/.git" ]]; then
    common="$root/.git"
    main="$root"
  else
    line=""
    IFS= read -r line < "$root/.git"
    line="${line%$'\r'}"
    case "$line" in
      'gitdir: '*) dont_abs_path "$root" "${line#gitdir: }"; gitdir="$DONT_ABS" ;;
      *) return 0 ;;
    esac
    common="$gitdir"
    if [[ -f "$gitdir/commondir" ]]; then
      line=""
      IFS= read -r line < "$gitdir/commondir"
      dont_abs_path "$gitdir" "${line%$'\r'}"
      common="$DONT_ABS"
    fi
    common="${common%/}"
    case "$common" in
      */.git) main="${common%/.git}" ;;
    esac
  fi

  dont_read_remote "$common/config"

  for candidate in "$DONT_CWD" "$root" "$main"; do
    if [[ -n "$candidate" && -f "$candidate/.claude/dont-config.json" ]]; then
      DONT_PROJECT_CFG="$candidate/.claude/dont-config.json"
      return 0
    fi
  done
}
