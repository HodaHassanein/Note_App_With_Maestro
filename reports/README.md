# Maestro test reports

Editable test strings are in `maestro/data/test-data.yaml`. They are passed into Maestro by `collect-report.ps1` as `-e` flags.

## What is saved (last run only)

`collect-report.ps1` deletes **every folder** under `reports/` (not files like this README), then creates **`reports/latest/`** with:

| Outcome | On disk under `reports/latest/` |
|--------|----------------------------------------|
| Any run | **`report.txt`** — counts, exit code, and if anything failed, the `[Failed] ...` lines from the console |
| Failed run | **`maestro-artifacts/`** — copy of the Maestro run folder (screenshots, etc.) |
| All passed | **No** `maestro-artifacts/` — attachments are not kept |

There is **no** full console log file, no separate summary/failed files. Output still streams to the terminal while the run executes.

`%USERPROFILE%\.maestro\tests` is emptied after every collect-report run (artifacts are copied first **only** when the run failed or exit code ≠ 0).

## Run from repo root (PowerShell)

```powershell
.\maestro\collect-report.ps1
```

Run specific flows:

```powershell
.\maestro\collect-report.ps1 -Flows "maestro\flows\01_new_note.yaml","maestro\flows\02_undo_in_editor.yaml"
```

**Maestro Studio:** Running flows only from Studio does not create `reports/latest`; Studio may keep its own history under `%USERPROFILE%\.maestro\`. Use `collect-report.ps1` for this reporting model.

**If you still see extra folders:** they are usually (1) old `reports/runs/...` from before this layout — run `collect-report.ps1` once to wipe them, or (2) paths outside `reports/` (e.g. Maestro Studio), which this script does not delete.
