## This is a new project: set it up first, with the human, now

The repository is empty. Tonight's worker cannot install packages or use the network, and a
small model does best filling in a structure that someone else chose. So before you write any
tasks, agree on the stack with the human, then build the **skeleton** yourself:

1. The manifest and lockfile for the chosen stack (for example package.json + package-lock.json,
   Gemfile + Gemfile.lock, pyproject.toml + a lockfile). Declare and install **every dependency
   the plan will need**, because the worker cannot add any.
2. The test runner, configured to pick up the acceptance tests, plus one trivial test that
   passes, so the runner is proven to work. Run it.
3. The folder layout (for example `src/`, `tests/`) with the entry point or module files the tasks
   will fill in. Folders that don't exist are a common source of path mistakes for the worker.
4. `AGENTS.md`: the stack, the layout, the exact commands to run the tests and the type checker,
   and the coding conventions. It is the worker's only map of the project.
5. Tell the human the exact lines to add to `{{CONFIG}}`:
   - `project.bootstrap`: how to reinstall dependencies (for example `npm ci`);
   - `gates.global`: the full test suite (and a type check or linter, if there is one), so every
     task has to keep the whole project green.

Keep the skeleton free of feature code. Then plan the features on top of it. The first tasks
should lay the foundations (core types, the data model, pure helper functions), with later tasks
depending on them. Prefer many small tasks over a few big ones.

