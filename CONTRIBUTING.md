# Contributing Guide

Thank you for considering contributing to this project. Contributions of all sizes are welcome, from documentation improvements to infrastructure and reliability enhancements.

Please read [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) before participating.

---

## 1. Branch Workflow

This repository follows a **main / develop** branching model:

- **main**: always stable and production-ready.
- **develop**: active development branch. **All merge requests should target this branch.**
- **feature/**: new features (example: `feature/add-db-healthcheck`).
- **fix/**: bug fixes (example: `fix/restore-script-path-check`).
- **hotfix/**: urgent fixes to main (example: `hotfix/compose-startup-failure`).

### Example Feature Workflow

```bash
# 1. Start on develop and pull latest changes
git checkout develop
git pull

# 2. Create a new branch for your feature
git checkout -b feature/awesome-improvement

# 3. Work and commit using Conventional Commits
# work...
git commit -m "feat: add awesome improvement"

# 4. Push your branch
git push origin feature/awesome-improvement

# 5. Open a Merge Request targeting develop
```

---

## 2. Code Style and Tooling

Consistency is key. Keep changes focused, readable, and aligned with repository conventions.

### Formatting and Linting

Use the tooling already defined in the repository. If a linter/formatter is introduced for a specific stack area, ensure your changes pass before opening a merge request.

### Conventional Commits

Use [Conventional Commits](https://www.conventionalcommits.org/) for commit messages.

- `feat:` new feature
- `fix:` bug fix
- `chore:` maintenance/tooling
- `docs:` documentation changes only
- `test:` adding/updating tests
- `refactor:` internal code changes without behavior change

Examples:

- Good: `fix: handle relative dump paths in restore script`
- Bad: `update stuff`

---

## 3. Testing

Run relevant checks locally before submitting a merge request.

Recommended baseline checks for this repository:

```bash
# Validate compose configuration
docker compose config

# Start services
docker compose up -d --build

# Verify database access
./scripts/backup-db.sh
```

Optional additional validation in a disposable environment:

```bash
# Seed demo data (destructive to target DB)
./scripts/seed-demo-db.sh --yes
```

If your change affects scripts, infrastructure, or CI behavior, include the exact commands you ran in the merge request description.

---

## 4. Merge Request Checklist

Please include the following in your merge request:

- **Summary**: brief description of the change and scope.
- **Type**: for example `feat`, `fix`, `refactor`, `docs`, `chore`.
- **Testing**: what you ran and observed.

Checklist:

- [ ] My code follows existing style and formatting rules.
- [ ] I performed a self-review of my changes.
- [ ] I updated documentation where needed.
- [ ] Relevant checks/tests pass locally.
- [ ] My commit messages use Conventional Commits.

---

## 5. Reporting Issues and Proposing Changes

When opening an issue or merge request, provide:

- Steps to reproduce (for bugs)
- Expected behavior
- Actual behavior
- Environment details (OS, Docker/Compose versions)

Clear reports help maintainers review and respond quickly.
