# dotfiles

Personal shell configuration and utilities.

## Setup

Source the files you want in your `.zshrc`:

```zsh
# Optionally override the default code directory
# export CODE_DIR="$HOME/projects"

source ~/path/to/dotfiles/zsh/.worktree-helpers.zsh
```

### Dependencies

- [fzf](https://github.com/junegunn/fzf) — used for interactive worktree selection in `wt ls` and `wt rm`

## Worktree Helpers

Shell functions for managing git worktrees with bare repositories. Provides the `wt` command.

### Directory layout

```
$CODE_DIR/.bare/<repo>.git    Bare repositories
$CODE_DIR/<repo>/<branch>/    Worktree directories
```

`CODE_DIR` defaults to `~/code` and can be overridden before sourcing.

### Commands

| Command | Description |
|---|---|
| `wt bare <url> [name]` | Clone a repo as bare for worktree usage |
| `wt add <repo> <branch> [base]` | Create or checkout a worktree |
| `wt rm <repo> [branch] [-f]` | Remove worktree(s) with fzf multi-select |
| `wt ls [repo]` | List worktrees or cd into one via fzf |
| `wt prune <repo>` | Clean up stale worktree references |
| `wt share <repo> <file>` | Share a file across all worktrees via symlinks |
| `wt shared <repo>` | List shared files |
| `wt unshare <repo> <file>` | Stop sharing a file |

### Example workflow

```zsh
# Clone a repo as bare
wt bare git@github.com:acme/api.git

# Create a worktree for a new feature branch (branches from origin/main)
wt add api feature-auth

# You're now cd'd into ~/code/api/feature-auth — do your work
git commit -am "add auth middleware"
git push

# Switch to another worktree (interactive picker)
wt ls api

# Share .env.local across all worktrees so you don't duplicate config
wt share api .env.local

# Clean up when done
wt rm api feature-auth

# Or use fzf multi-select to remove several at once
wt rm api
```

### Branch resolution

`wt add` determines what to do based on whether the branch already exists:

1. **Local branch exists** — checks it out as a worktree
2. **Remote branch exists** — creates a local tracking branch
3. **New branch** — creates it from `base` (defaults to `origin/<default branch>`, or pass a custom base like `HEAD`)

```zsh
wt add api existing-branch        # checkout existing
wt add api new-feature             # new branch from origin/main
wt add api hotfix origin/release   # new branch from specific base
```

### Shared files

Some files (`.env.local`, editor config, etc.) should be the same across all worktrees. `wt share` symlinks a single copy into each worktree:

```zsh
wt share api .env.local
wt share api .claude/settings.local.json

# See what's shared
wt shared api

# Stop sharing (symlinks remain, but new worktrees won't get them)
wt unshare api .env.local
```

Run `wt help` for the full built-in reference.

## License

[MIT](LICENSE)
