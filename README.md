# riskcheck-practice

A tiny Python project for practising **Git flow and GitHub Actions**. The code is
small on purpose: `riskcheck/score.py` gives a transaction a risk score from 0 to 1
using four plain rules (big amount, money leaving the system, account emptied,
amount larger than the balance). The code does not matter in this class. What matters is
what happens around it: pull requests, checks, environments and promotion.

Nothing here touches AWS, and nothing is really deployed. The "deploy" in lab 6 only
prints what a real deploy would do.

## The code in one minute

```python
from riskcheck import score_transaction

score, reasons = score_transaction(250_000, 300_000, 50_000, "TRANSFER")
# score = 0.5, reasons = ["large amount (>= 200,000)", "risky transaction type (TRANSFER)"]
```

```bash
python -m pip install -r requirements.txt
python -m pytest -q          # 8 tests, well under a second
```

## The branch model

Four long-lived branches. Each one is an **environment**: a push to it deploys there.

```
feature/*  --PR-->  develop  --PR-->  sit  --PR-->  release  --PR-->  main
                     (dev)            (sit)        (pre-prod)        (prod)

hotfix/*  starts from main, is BUILT on its own branch  --PR-->  main,  then main --PR--> develop (merge back)
```

| Branch | Environment | Who may open a PR into it |
| --- | --- | --- |
| `develop` | dev | any branch (`feature/*`, a hotfix merge-back) |
| `sit` | sit | `develop` only |
| `release` | pre-prod | `sit` only |
| `main` | prod | `release`, or `hotfix/*` in an emergency |

Rules of the road:

- Nobody pushes straight to the four branches. Everything arrives by pull request.
- Code moves **one step at a time**. A change reaches prod only after dev, sit and pre-prod.
- **Build once.** The artifact is built on `develop` and named after the *tree hash*
  (`git rev-parse HEAD^{tree}`, the fingerprint of the exact files). Promoting by merge
  leaves the files identical, so `sit`, `release` and `main` find the **same** artifact.
  If nobody built that tree on `develop`, the deploy fails.
- **A hotfix never passes through `develop`**, so it is built on its own `hotfix/*` branch
  (build only, no deploy). After the merge into `main` the tree is the same, so prod deploys
  that build, after approval.
- Merge with **merge commits** (the setup script allows nothing else by default). Squash
  merges make the environment branches drift apart, and later promotion PRs show old
  changes again.

## The labs

The workflow files are in `labs/`. When a lab adds one, you **copy it into
`.github/workflows/`** and push, so you watch each piece arrive. The file name matches the
workflow name.

```bash
mkdir -p .github/workflows
cp labs/hello.yml .github/workflows/
```

| Lab | What you do | Workflow file | You will see |
| --- | --- | --- | --- |
| 1 | Set up the repo: push `main`, run the setup script | none | branches, Environments and rulesets in Settings |
| 2 | Your first workflow | `hello.yml` | a run in the Actions tab: branch, commit, tree hash, runner OS |
| 3 | CI on pull requests | `ci.yml` (**ci / test**) | a red X when a test breaks, green when fixed |
| 4 | The ruleset makes a red check block the merge | none (rerun the setup script) | the Merge button locked until `test` is green |
| 5 | The promotion path | `promotion-path.yml` (**promotion-path / check**) | a PR `feature/x` into `sit` that fails with a clear message |
| 6 | Deliver on `develop` | `deliver.yml` | build once, deploy (simulated) to dev; the tree-named artifact |
| 7 | `develop` to `sit` | none | the same tree hash, the same artifact, deployed to sit |
| 8 | `sit` to `release` to `main`, with approvals | none | pre-prod and prod wait for a reviewer, then deploy the same build |
| 9 | A hotfix | none | `hotfix/*` built on its own branch, then merged to `main` and `develop` |

Where each idea lives:

| Idea | Where |
| --- | --- |
| CI (test every change) | lab 3 |
| Required checks and protected branches (**rulesets**) | `scripts/setup_repo.sh` (instructor), labs 4 and 5 |
| Promotion rules | lab 5 |
| CD, build once, same artifact everywhere | labs 6 to 8 |
| GitHub **Environments** (branch rule, approval) | labs 6 to 8, created by `scripts/setup_repo.sh` |
| Emergency fix | lab 9 |

## Setting the repo up (instructor)

1. Create the public repo, push `main` with these files (first commit on `main`).
2. **Lab 1:** `scripts/setup_repo.sh <owner>/<repo> --checks none` creates the branches
   `develop`, `sit` and `release`, the four Environments, and the rulesets.
3. **Lab 4:** run it again with `--checks ci`, the moment a red `test` check should block merging.
4. **Lab 5:** run it again with `--checks all` to also require the promotion check.

A required check that no workflow reports blocks every pull request, so the rulesets ask only
for checks that exist. The script allows only merge commits; add `--allow-squash` to opt out.
The rulesets have no bypass list, so the instructor also goes through pull requests.

Two more instructor tools are **not part of this repo** and are never pushed to students' repos. They live in
the course folder next to the deck, in `class_pack/live/`:

- `live_run.sh <org>/<repo> <workdir> <logdir>` rehearses labs 1-9 against a real repo and records each lab's
  commands and real output (restartable with `--from labN`).
- `live_to_deck.py <logdir>` turns those logs into `class_pack/live_run.cjs`, the real terminal output the
  deck builder quotes on its lab slides.

## What is in the folder

```
riskcheck/        the package (score.py)
tests/            test_score.py
labs/             the four workflow files (hello, ci, promotion-path, deliver), copied into .github/workflows/ as the labs ask
scripts/          setup_repo.sh (instructor only)
pyproject.toml    package info and pytest settings (Python 3.11 or newer)
requirements.txt  pytest
```
