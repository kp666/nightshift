# Trade-offs

Design choices in nightshift that cost something: what each side gives you, why the default is
the default, and when to pick the other side.

## 1. Where the worker works: a clone (default) or your repo in place

### What nightshift does to that folder

Whatever folder the worker edits, nightshift treats everything in it that is not committed as
disposable:

- before each attempt, and after each failed one, it runs `git reset --hard <last good commit>`
  and `git clean -fd`. Tracked edits and untracked files are gone; ignored files (`node_modules`,
  build output, `.env`) stay;
- the worker has a shell and runs for minutes per attempt, for hours per night, with nobody
  watching;
- after a crash, the next `ns run` resets the folder before it starts.

That is what makes runs repeatable and attempts independent. It is also why the choice of folder
matters.

### The default: a dedicated clone

`ns init <state> --source <repo>` clones your repo into `<state>/repo`, checks out a new branch
there and removes every remote.

What it gives you:

1. **Your folder is never touched.** You can keep editing, switch branches and build in your
   repo while a run is going.
2. **A push has nowhere to go.** The clone has no remotes, so a stray `git push` fails. A worker
   would have to type a URL on purpose (and the pi guard blocks `git push` and `git remote`).
3. **Ignored files stay behind.** `git clone` copies only committed files, so `.env`, local
   credentials and caches are not in the worker's folder, and pi's read/edit/write tools cannot
   leave that folder.
4. **Recovery can be blunt.** Anything uncommitted in the clone came from the worker, so a reset
   never loses your work.

This is not a sandbox. The worker runs as you, so a shell command can still read any file by
its absolute path. Only the Docker adapter (`pi-local-docker`) actually isolates the worker.

What it costs:

- **Disk for a second checkout.** The history is almost free: cloning from a local path
  hard-links git's object files when the state dir is on the same drive as your repo. On another
  drive they are copied. The checked-out files are a full second copy.
- **One more dependency install.** `project.bootstrap` (e.g. `npm ci`) runs once in the clone.
  Its output is ignored by git, so it survives every reset after that.
- **A fetch in the morning.** `ns land` prints a `git fetch` from the clone, then the review and
  merge commands.

### The option: in place

`ns init <state> --source <repo> --in-place` creates the branch in your repo, checks it out
there, and the worker edits your repo. The state dir (config, plan, hidden tests, logs) is still
a separate folder, and it must be outside the repo.

What it gives you:

- no second checkout and no second dependency install: your `node_modules` and build caches are
  reused;
- the night's commits are already on a branch of your repo, so `ns land` only prints the review
  and merge commands.

What it gives up, and what nightshift does about each:

| You give up | What nightshift does | What is left to you |
|---|---|---|
| Using the folder during a run | `ns init` and `ns run` refuse to start if the repo has uncommitted or untracked files, or is on another branch. Between attempts, the run stops if the branch, its commits or the files changed. If the branch changes during an attempt, the run stops before it stages or commits anything. Ignored files are never deleted. | Don't touch the repo while a run is active. A tracked file you edit during an attempt becomes part of the worker's diff, and is committed or discarded with it. After a crash, the next run resets the leftovers of the interrupted attempt, which would include any edit you made in that window. |
| The no-push guarantee | `ns doctor` lists your remotes. The pi guard blocks `git push` and `git remote`, and the `claude-code` adapter disallows `git push`. | The guard is a pattern match, not a sandbox, and the other adapters rely on their own rules. To make pushing fail, disable the push URL for the run: `git remote set-url --push origin no-push`, and restore it with `git remote set-url --push origin <url>`. |
| Secrets out of reach | The pi guard blocks edits to `.env` files. | `.env` and every other ignored file are inside the worker's folder, and it can read them. If you escalate to a cloud adapter, what it reads goes to that provider. Don't run in place on a repo whose ignored files hold secrets the model should not see. |

### Why the clone is the default

nightshift runs unattended, so its default has to be safe without the user following rules. A
clone's failures are cheap and visible: some disk, a second `npm ci`, one fetch in the morning.
In-place failures are expensive and silent: lost work, a push, or a secret read into a prompt,
all happening while nobody is watching. nightshift's checks narrow these down but cannot rule
them out. And because git hard-links the history, the clone is cheap for most repos: only the
working files are duplicated.

### When to choose in place

Choose `--in-place` when all of these hold:

- a second checkout or dependency install is too big or too slow (a large monorepo, a huge
  `node_modules`, long-to-rebuild caches);
- you won't use that folder while the run is going, for example overnight;
- its ignored files hold nothing you'd mind the model (or a cloud escalation provider) reading;
- you are fine with its remotes being there, or you disable the push URL as shown above.

If you need the folder while the run is going, use the clone and keep the state dir on the same
drive as the repo.

### Alternatives that were considered

- **`git worktree`.** It shares your repo's `.git`, but it still checks out a full copy of the
  files, which is the same cost as a clone whose history is hard-linked. It also shares your
  branches, remotes, hooks and config with the worker. It costs as much as a clone and protects
  less.
- **Sparse checkout in the clone.** Check out only the folders the tasks need, which cuts the
  second copy to a fraction for a large monorepo. Not implemented yet. It would need
  `ns check` to confirm that every task's files, checks, protected paths and hidden tests fall
  inside the sparse set.
