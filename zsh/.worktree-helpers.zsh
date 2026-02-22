# =============================================================================
# Git Worktree Helpers
# =============================================================================
#
# A set of shell functions for managing git worktrees with bare repositories.
#
# Directory Structure:
#   $CODE_DIR/              (~/code)
#     .bare/                Bare repositories live here
#       api.git/
#       web.git/
#     api/                  Worktrees for 'api' repo
#       master/
#       feature-branch/
#       subdir/nested-branch/
#     web/                  Worktrees for 'web' repo
#       main/
#
# Quick Reference:
#   wt                          Show help
#   wt bare <url> [name]        Clone a repo as bare for worktree usage
#   wt add <repo> <branch>      Create or checkout a worktree
#   wt rm <repo> [branch]       Remove worktree(s) + branches (fzf multi-select)
#   wt ls [repo]                List worktrees (interactive select with fzf)
#   wt prune <repo>             Clean up stale worktree references
#   wt share <repo> <file>      Share a file across all worktrees
#   wt shared <repo>            List shared files
#   wt unshare <repo> <file>    Stop sharing a file
#
# =============================================================================

export CODE_DIR="${CODE_DIR:-$HOME/code}"
export BARE_DIR="$CODE_DIR/.bare"

# -----------------------------------------------------------------------------
# _wt_default_branch_name <bare_repo>
#
# Internal helper to detect the default branch name (e.g., "main" or "master").
# Tries multiple methods in order of speed:
#   1. Local symbolic-ref (instant, if previously cached)
#   2. Remote query (slower, but authoritative)
#   3. Fallback to "main"
# -----------------------------------------------------------------------------
_wt_default_branch_name() {
  local bare_repo="$1"
  # Try symbolic-ref first (fastest)
  local ref=$(git -C "$bare_repo" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)
  if [[ -n "$ref" ]]; then
    echo "${ref#refs/remotes/origin/}"
    return
  fi
  # Fallback: query the remote
  local branch=$(git -C "$bare_repo" remote show origin 2>/dev/null | awk '/HEAD branch:/ {print $NF}')
  if [[ -n "$branch" ]]; then
    echo "$branch"
    return
  fi
  # Last resort fallback
  echo "main"
}

# -----------------------------------------------------------------------------
# _wt_default_branch <bare_repo>
#
# Internal helper returning the full remote ref (e.g., "origin/main").
# Used as the default base when creating new branches.
# -----------------------------------------------------------------------------
_wt_default_branch() {
  local bare_repo="$1"
  echo "origin/$(_wt_default_branch_name "$bare_repo")"
}

# -----------------------------------------------------------------------------
# _wt_sorted_list <bare_repo>
#
# Internal helper that lists worktrees (excluding bare) sorted by directory
# creation time (newest first). Output format matches `git worktree list`.
# -----------------------------------------------------------------------------
_wt_sorted_list() {
  local bare_repo="$1"
  git -C "$bare_repo" worktree list | grep -v '(bare)$' | while IFS= read -r line; do
    local dir=$(echo "$line" | awk '{print $1}')
    if [[ "$(uname)" == "Darwin" ]]; then
      printf '%s\t%s\n' "$(stat -f %B "$dir" 2>/dev/null || echo 0)" "$line"
    else
      printf '%s\t%s\n' "$(stat -c %W "$dir" 2>/dev/null || echo 0)" "$line"
    fi
  done | sort -rn | cut -f2-
}

# -----------------------------------------------------------------------------
# _wt_bare <url> [name]
#
# Clone a repository as a bare repo optimized for worktree usage.
#
# What it does:
#   1. Clones the repo as bare into $BARE_DIR/<name>.git
#   2. Configures fetch refspec to track all remote branches
#   3. Sets up origin/HEAD for default branch detection
#   4. Installs a pre-commit hook that blocks commits on the default branch
# -----------------------------------------------------------------------------
_wt_bare() {
  local url="$1"
  local name="$2"

  if [[ -z "$url" ]]; then
    echo "Usage: wt bare <url> [name]"
    echo "       wt bare git@github.com:user/repo.git"
    echo "       wt bare git@github.com:user/repo.git my-repo"
    return 1
  fi

  # Derive name from URL if not provided
  if [[ -z "$name" ]]; then
    name=$(basename "$url" .git)
  fi

  local bare_repo="$BARE_DIR/${name}.git"

  if [[ -d "$bare_repo" ]]; then
    echo "Error: Bare repo already exists at $bare_repo"
    return 1
  fi

  # Ensure directories exist
  mkdir -p "$BARE_DIR" "$CODE_DIR/$name"

  echo "Cloning bare repo to $bare_repo..."
  git clone --bare "$url" "$bare_repo" || return 1

  # Configure the bare repo for worktree usage
  git -C "$bare_repo" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
  git -C "$bare_repo" fetch origin

  # Remove local branch refs created by bare clone — they shadow remote tracking
  # and prevent _wt_add from setting up tracking correctly.
  git -C "$bare_repo" for-each-ref --format='%(refname:short)' refs/heads/ | \
    xargs -n1 git -C "$bare_repo" branch -D 2>/dev/null

  # Set up symbolic ref for default branch detection
  git -C "$bare_repo" remote set-head origin --auto 2>/dev/null

  # Install pre-commit hook to prevent commits on default branch
  mkdir -p "$bare_repo/hooks"
  cat > "$bare_repo/hooks/pre-commit" << 'HOOK'
#!/bin/sh
# Prevent commits on the default branch
default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
[ -z "$default_branch" ] && default_branch="main"
current_branch=$(git symbolic-ref --short HEAD 2>/dev/null)
if [ "$current_branch" = "$default_branch" ]; then
  echo "Error: Direct commits to '$default_branch' are not allowed."
  echo "Create a feature branch instead: wt add <repo> <branch>"
  exit 1
fi
HOOK
  chmod +x "$bare_repo/hooks/pre-commit"

  local default_branch=$(_wt_default_branch_name "$bare_repo")
  echo "Bare repo ready: $bare_repo"
  echo "  Default branch: $default_branch (commits blocked)"
  echo "  Create a worktree: wt add $name <branch>"
}

# -----------------------------------------------------------------------------
# _wt_add <repo> <branch> [base]
#
# Create or checkout a worktree for the given branch.
#
# Branch resolution (in order):
#   1. If local branch exists     -> checkout as-is
#   2. If remote branch exists    -> create local branch tracking remote
#   3. Otherwise                  -> create new branch from base (no tracking)
#
# Also symlinks any shared files registered in .wtshared.
# -----------------------------------------------------------------------------
_wt_add() {
  local repo="$1"
  local branch="$2"

  if [[ -z "$repo" || -z "$branch" ]]; then
    echo "Usage: wt add <repo> <branch> [base]"
    echo "       wt add api feature-auth          # new branch from default branch"
    echo "       wt add api feature-auth HEAD     # new branch from current HEAD"
    echo "       wt add api existing-branch       # checkout existing branch"
    return 1
  fi

  local bare_repo="$BARE_DIR/${repo}.git"
  local worktree_path="$CODE_DIR/${repo}/${branch}"

  if [[ ! -d "$bare_repo" ]]; then
    echo "Error: Bare repo not found at $bare_repo"
    echo "Run: wt bare <url> $repo"
    return 1
  fi

  if [[ -d "$worktree_path" ]]; then
    echo "Error: Worktree already exists at $worktree_path"
    echo "To switch to it: cd $worktree_path"
    return 1
  fi

  local base="${3:-$(_wt_default_branch "$bare_repo")}"

  git -C "$bare_repo" fetch origin

  if git -C "$bare_repo" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
    # Local branch exists
    git -C "$bare_repo" worktree add "$worktree_path" "$branch"
  elif git -C "$bare_repo" show-ref --verify --quiet "refs/remotes/origin/$branch" 2>/dev/null; then
    # Remote branch exists - track it
    git -C "$bare_repo" worktree add --track "$worktree_path" -b "$branch" "origin/$branch"
  else
    # New branch - never track
    git -C "$bare_repo" worktree add --no-track "$worktree_path" -b "$branch" "$base"
  fi

  # Link shared files (see wt share)
  local wtshared="$CODE_DIR/${repo}/.wtshared"
  if [[ -f "$wtshared" ]]; then
    while IFS= read -r file || [[ -n "$file" ]]; do
      [[ -z "$file" ]] && continue
      local shared_file="$CODE_DIR/${repo}/$file"
      if [[ -f "$shared_file" ]]; then
        mkdir -p "$worktree_path/$(dirname "$file")"
        ln -sf "$shared_file" "$worktree_path/$file"
      fi
    done < "$wtshared"
  fi

  cd "$worktree_path"
}

# -----------------------------------------------------------------------------
# _wt_rm <repo> [branch] [-f]
#
# Remove worktree(s) and delete their local branches.
#
# If branch is omitted, presents an interactive fzf picker with
# multi-select (tab to mark, ctrl-a to select all).
# -----------------------------------------------------------------------------
_wt_rm() {
  local repo="$1"
  local branch="$2"
  local force=""
  local bare_repo="$BARE_DIR/${repo}.git"

  if [[ -z "$repo" ]]; then
    echo "Usage: wt rm <repo> [branch] [-f]"
    return 1
  fi

  if [[ ! -d "$bare_repo" ]]; then
    echo "Error: Bare repo not found at $bare_repo"
    return 1
  fi

  # Parse -f flag from either position
  if [[ "$2" == "-f" ]]; then
    force="-f"
    branch=""
  elif [[ "$3" == "-f" ]]; then
    force="-f"
  fi

  # If no branch specified, use fzf to pick (multi-select supported)
  if [[ -z "$branch" ]]; then
    local list=$(_wt_sorted_list "$bare_repo")
    if [[ -z "$list" ]]; then
      echo "No worktrees for $repo"
      return 0
    fi
    if [[ -t 0 ]] && command -v fzf &>/dev/null; then
      local selected
      selected=$(echo "$list" | fzf --multi --height=~50% --reverse \
        --prompt="remove $repo worktree(s)> " \
        --header="tab: select  ctrl-a: all" \
        --bind 'ctrl-a:select-all,ctrl-d:deselect-all') || return 0

      local -a branches=()
      while IFS= read -r line; do
        local dir=$(echo "$line" | awk '{print $1}')
        branches+=("${dir#$CODE_DIR/${repo}/}")
      done <<< "$selected"

      for b in "${branches[@]}"; do
        local wt_path="$CODE_DIR/${repo}/${b}"
        print -P "%F{yellow}Deleting ${b} ...%f"
        if [[ "$force" == "-f" ]]; then
          git -C "$bare_repo" worktree remove --force "$wt_path"
          git -C "$bare_repo" branch -D "$b" 2>/dev/null
        else
          git -C "$bare_repo" worktree remove "$wt_path" || continue
          if ! git -C "$bare_repo" branch -d "$b" 2>/dev/null; then
            echo "Warning: branch '$b' has unmerged changes. Use -f to force delete."
          fi
        fi
      done
      return 0
    else
      echo "Branch required. Available worktrees:"
      echo "$list"
      return 1
    fi
  fi

  # Direct single-branch removal
  if [[ "$branch" == "$CODE_DIR/${repo}/"* ]]; then
    branch="${branch#$CODE_DIR/${repo}/}"
  fi

  local worktree_path="$CODE_DIR/${repo}/${branch}"

  print -P "%F{yellow}Deleting ${branch} ...%f"

  if [[ "$force" == "-f" ]]; then
    git -C "$bare_repo" worktree remove --force "$worktree_path"
    git -C "$bare_repo" branch -D "$branch" 2>/dev/null
  else
    git -C "$bare_repo" worktree remove "$worktree_path" || return 1
    if ! git -C "$bare_repo" branch -d "$branch" 2>/dev/null; then
      echo "Warning: branch '$branch' has unmerged changes. Use -f to force delete."
    fi
  fi
}

# -----------------------------------------------------------------------------
# _wt_ls [repo]
#
# List worktrees.
#
# With no arguments: shows summary of all repos and their worktree counts.
# With repo argument: interactive fzf picker to select and cd into a worktree.
# -----------------------------------------------------------------------------
_wt_ls() {
  local repo="$1"
  if [[ -z "$repo" ]]; then
    for bare in "$BARE_DIR"/*.git; do
      [[ -d "$bare" ]] || continue
      local name=$(basename "$bare" .git)
      local count=$(git -C "$bare" worktree list | grep -cv '(bare)$')
      echo "$name: $count worktree(s)"
    done
  else
    local bare_repo="$BARE_DIR/${repo}.git"
    if [[ ! -d "$bare_repo" ]]; then
      echo "Error: Bare repo not found at $bare_repo"
      return 1
    fi
    local list=$(_wt_sorted_list "$bare_repo")
    if [[ -z "$list" ]]; then
      echo "No worktrees for $repo"
      return 0
    fi
    if [[ -t 0 ]] && command -v fzf &>/dev/null; then
      local selected
      selected=$(echo "$list" | fzf --height=~50% --reverse --prompt="$repo worktree> ") || return 0
      local dir=$(echo "$selected" | awk '{print $1}')
      if [[ -d "$dir" ]]; then
        cd "$dir"
      fi
    else
      echo "$list"
    fi
  fi
}

# -----------------------------------------------------------------------------
# _wt_prune <repo>
#
# Clean up stale worktree references in the bare repo.
# -----------------------------------------------------------------------------
_wt_prune() {
  local repo="$1"
  if [[ -z "$repo" ]]; then
    echo "Usage: wt prune <repo>"
    return 1
  fi
  git -C "$BARE_DIR/${repo}.git" worktree prune -v
}

# -----------------------------------------------------------------------------
# _wt_share <repo> <file>
#
# Share a file across all worktrees for a repository.
#
# Behavior:
#   - If shared file already exists: just creates symlinks
#   - If one worktree has the file: moves it to shared location
#   - If multiple worktrees have different versions: prompts to choose
#   - If no worktrees have the file: tells you where to create it
#
# The file path can include subdirectories (e.g., ".claude/settings.local.json").
# Uses `git worktree list` to find all worktrees, so nested paths work.
# -----------------------------------------------------------------------------
_wt_share() {
  local repo="$1"
  local file="$2"
  local repo_dir="$CODE_DIR/$repo"
  local shared_file="$repo_dir/$file"
  local wtshared="$repo_dir/.wtshared"

  if [[ -z "$repo" || -z "$file" ]]; then
    echo "Usage: wt share <repo> <file>"
    echo "       wt share api settings.local.json"
    return 1
  fi

  if [[ ! -d "$BARE_DIR/${repo}.git" ]]; then
    echo "Error: Repo '$repo' not found"
    return 1
  fi

  # Collect all worktrees that have this file (not symlinks)
  # Uses git worktree list to handle arbitrarily nested worktree paths
  local -a sources=()
  local bare_repo="$BARE_DIR/${repo}.git"
  while IFS= read -r wt; do
    [[ "$wt" == "$bare_repo" ]] && continue
    [[ -f "$wt/$file" && ! -L "$wt/$file" ]] && sources+=("$wt/$file")
  done < <(git -C "$bare_repo" worktree list --porcelain | awk '/^worktree / {print substr($0, 10)}')

  # Determine source file
  if [[ -f "$shared_file" ]]; then
    echo "Shared file already exists: $shared_file"
  elif [[ ${#sources[@]} -eq 0 ]]; then
    echo "No existing $file found in worktrees."
    echo "Create it at: $shared_file"
    echo "Then run: wt share $repo $file"
    return 1
  elif [[ ${#sources[@]} -eq 1 ]]; then
    mkdir -p "$(dirname "$shared_file")"
    mv "${sources[1]}" "$shared_file"
    echo "Moved ${sources[1]} -> $shared_file"
  else
    # Multiple sources - check if identical
    local first="${sources[1]}"
    local differs=false
    for src in "${sources[@]:1}"; do
      if ! diff -q "$first" "$src" >/dev/null 2>&1; then
        differs=true
        break
      fi
    done

    if [[ "$differs" == true ]]; then
      echo "Multiple versions found:"
      for i in {1..${#sources[@]}}; do
        echo "  $i) ${sources[$i]}"
      done
      echo "  d) Show diffs"
      echo -n "Choose source [1-${#sources[@]}/d]: "
      read -r choice

      if [[ "$choice" == "d" ]]; then
        for src in "${sources[@]:1}"; do
          echo "=== diff ${sources[1]} $src ==="
          diff "${sources[1]}" "$src"
        done
        echo -n "Choose source [1-${#sources[@]}]: "
        read -r choice
      fi

      if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#sources[@]} )); then
        echo "Error: invalid selection '$choice'"
        return 1
      fi

      mkdir -p "$(dirname "$shared_file")"
      mv "${sources[$choice]}" "$shared_file"
      echo "Moved ${sources[$choice]} -> $shared_file"
    else
      mkdir -p "$(dirname "$shared_file")"
      mv "$first" "$shared_file"
      echo "Moved $first -> $shared_file (all copies identical)"
    fi
  fi

  # Register in .wtshared
  grep -qxF "$file" "$wtshared" 2>/dev/null || echo "$file" >> "$wtshared"

  # Create symlinks in all worktrees
  while IFS= read -r wt; do
    [[ "$wt" == "$bare_repo" ]] && continue
    mkdir -p "$wt/$(dirname "$file")"
    rm -f "$wt/$file" 2>/dev/null
    ln -sf "$shared_file" "$wt/$file"
  done < <(git -C "$bare_repo" worktree list --porcelain | awk '/^worktree / {print substr($0, 10)}')

  echo "Shared $file across all worktrees"
}

# -----------------------------------------------------------------------------
# _wt_shared <repo>
#
# List all shared files for a repository.
# Reads from $CODE_DIR/<repo>/.wtshared
# -----------------------------------------------------------------------------
_wt_shared() {
  local repo="$1"
  if [[ -z "$repo" ]]; then
    echo "Usage: wt shared <repo>"
    return 1
  fi
  cat "$CODE_DIR/$repo/.wtshared" 2>/dev/null || echo "No shared files for $repo"
}

# -----------------------------------------------------------------------------
# _wt_unshare <repo> <file>
#
# Remove a file from the shared list.
#
# Note: This only removes the entry from .wtshared. Existing symlinks in
# worktrees remain intact. New worktrees won't get the symlink automatically.
# To fully unshare, you'd need to manually replace symlinks with copies.
# -----------------------------------------------------------------------------
_wt_unshare() {
  local repo="$1"
  local file="$2"
  if [[ -z "$repo" || -z "$file" ]]; then
    echo "Usage: wt unshare <repo> <file>"
    return 1
  fi
  local wtshared="$CODE_DIR/$repo/.wtshared"
  if [[ -f "$wtshared" ]]; then
    if [[ "$(uname)" == "Darwin" ]]; then
      sed -i '' "/^${file//\//\\/}$/d" "$wtshared"
    else
      sed -i "/^${file//\//\\/}$/d" "$wtshared"
    fi
    echo "Removed $file from shared list (symlinks remain)"
  fi
}

# -----------------------------------------------------------------------------
# _wt_help
#
# Print help for all worktree helper commands.
# -----------------------------------------------------------------------------
_wt_help() {
  cat <<EOF
Git Worktree Helpers
====================

Directory layout:
  $CODE_DIR/.bare/<repo>.git    Bare repositories
  $CODE_DIR/<repo>/<branch>/    Worktree directories

Commands:

  wt bare <url> [name]
      Clone a repo as bare for worktree usage.
      Sets up fetch refspec, origin/HEAD, and a pre-commit hook that
      blocks direct commits to the default branch.
        wt bare git@github.com:company/api.git
        wt bare git@github.com:company/api.git my-api

  wt add <repo> <branch> [base]
      Create or checkout a worktree, then cd into it.
      If the branch exists locally or on the remote, it is checked out.
      Otherwise a new branch is created from base (default: origin/<default>).
        wt add api feature-auth           # new branch from default
        wt add api feature-auth HEAD      # new branch from HEAD
        wt add api existing-branch        # checkout existing branch

  wt rm <repo> [branch] [-f]
      Remove worktree(s) and delete their local branches.
      Without a branch name, shows a multi-select fzf picker
      (tab to select, ctrl-a to select all).
      Use -f to force removal with uncommitted changes.
        wt rm api                    # fzf multi-select
        wt rm api feature-auth       # direct removal
        wt rm api feature-auth -f    # force removal

  wt ls [repo]
      Without arguments: summary of all repos and worktree counts.
      With a repo: interactive fzf picker to select and cd into a worktree.
        wt ls
        wt ls api

  wt prune <repo>
      Clean up stale worktree references after manual directory deletion.
        wt prune api

  wt share <repo> <file>
      Share a file across all worktrees via symlinks. If the file exists
      in one worktree it is moved to the shared location. If multiple
      worktrees have differing copies, you are prompted to choose.
        wt share api .env.local
        wt share api .claude/settings.local.json

  wt shared <repo>
      List all shared files for a repository.
        wt shared api

  wt unshare <repo> <file>
      Remove a file from the shared list. Existing symlinks remain;
      new worktrees will no longer get the symlink automatically.
        wt unshare api .env.local

  wt help
      Show this help.
EOF
}

# =============================================================================
# wt - Main entry point
#
# Dispatches to subcommands. Running `wt` alone prints help.
# =============================================================================
wt() {
  local cmd="$1"

  case "$cmd" in
    bare)    shift; _wt_bare "$@" ;;
    add)     shift; _wt_add "$@" ;;
    rm)      shift; _wt_rm "$@" ;;
    ls)      shift; _wt_ls "$@" ;;
    prune)   shift; _wt_prune "$@" ;;
    share)   shift; _wt_share "$@" ;;
    shared)  shift; _wt_shared "$@" ;;
    unshare) shift; _wt_unshare "$@" ;;
    help|--help|-h) _wt_help ;;
    "")      _wt_help ;;
    *)
      echo "wt: unknown command '$cmd'"
      echo "Run 'wt help' for usage."
      return 1
      ;;
  esac
}
