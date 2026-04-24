# BBS Repository Inventory Report

Shell tooling to generate repository inventory data from Bitbucket Server (BBS), including repository size, attachment size, last commit date, archive status, and pull request count.

## Contents

- `bbs_repo_inventory.sh` - Main script that processes a project range and writes inventory reports.
- `batch_runner.sh` - Wrapper script that runs the main script in batches.

## Prerequisites

- Bash
- `curl`
- `jq`
- `bc` (used for summary size conversion)
- Network access to your Bitbucket Server instance
- BBS credentials with access to project and repository APIs

## Authentication

The scripts use Basic Auth.

You can authenticate in either way:

1. Pass credentials directly:
   - `-u "username:password"` (main script)
2. Set environment variables:
   - `BBS_USER`
   - `BBS_PASSWORD`

Example:

```bash
export BBS_USER="your_username"
export BBS_PASSWORD="your_password"
```

## Input File Format

Provide a CSV (or tab-delimited file) with a header and these columns:

- `project-key`
- `project-name`
- `url`
- `repo-count`
- `pr-count`

Only `project-key`, `project-name`, and `url` are used for API processing; the remaining columns are tolerated for compatibility.

## Main Script

`bbs_repo_inventory.sh` processes a range of projects by row index (excluding header), fetches repo metadata, and writes report files.

### Usage

```bash
./bbs_repo_inventory.sh -f <projects.csv> -s <start> -e <end> [options]
```

### Required arguments

- `-f, --file <path>`: input projects file
- `-s, --start <num>`: start index (1-based, data rows only)
- `-e, --end <num>`: end index

### Common options

- `-u, --user <user:pass>`: inline credentials
- `-b, --base-url <url>`: override base URL parsed from project URL
- `-o, --output <dir>`: output directory (default `./output`)
- `-l, --limit <num>`: API page limit (default `100`)
- `-p, --parallel <num>`: max parallel repo workers when parallel mode is active (default `5`)
- `--parallel-threshold <num>`: switch to parallel mode when repo count is above this value (default `10`)
- `-r, --retry <num>`: retry count for API failures (default `3`)
- `--resume <file>`: resume from a prior progress JSON
- `--dry-run`: validate setup and print intended API calls without executing
- `-v, --verbose`: verbose logs
- `-h, --help`: help text

### Example commands

```bash
# Process projects 1-20 using explicit credentials
./bbs_repo_inventory.sh -f projects.csv -s 1 -e 20 -u "user:password"

# Use environment-based credentials
./bbs_repo_inventory.sh -f projects.csv -s 21 -e 50 -v

# Resume a prior run
./bbs_repo_inventory.sh -f projects.csv -s 1 -e 100 -u "user:password" --resume output/progress_YYYYMMDD_HHMMSS.json

# Validate only
./bbs_repo_inventory.sh -f projects.csv -s 1 -e 5 -u "user:password" --dry-run
```

## Batch Runner

`batch_runner.sh` splits a larger run into batches and calls the main script repeatedly.

### Usage

```bash
./batch_runner.sh <projects.csv> [options]
```

### Options

- `-b, --batch-size <num>`: projects per batch (default `50`)
- `-w, --wait <seconds>`: sleep between batches (default `30`)
- `-s, --start <num>`: first project index to process (default `1`)
- `-e, --end <num>`: last project index (default: total rows)
- `--dry-run`: print planned batch commands only
- `-v, --verbose`: pass verbose mode to the main script
- `-h, --help`: help text

### Example commands

```bash
# Run entire file with defaults
./batch_runner.sh projects.csv

# Run in larger batches
./batch_runner.sh projects.csv -b 100

# Run a subset
./batch_runner.sh projects.csv -s 101 -e 500 -b 50

# Show batch plan only
./batch_runner.sh projects.csv --dry-run
```

## Generated Output

By default, artifacts are created under:

- `output/reports/`
- `logs/`

Primary files:

- `output/reports/repo_inventory_<timestamp>.csv`
- `output/reports/errors_<timestamp>.csv`
- `output/reports/summary_<timestamp>.txt`
- `output/progress_<timestamp>.json`
- `logs/bbs_inventory_<timestamp>.log`

## Report Schema

The inventory report CSV uses this header:

`project-key,project-name,repo,url,last-commit-date,repo-size-in-bytes,attachments-size-in-bytes,is-archived,pr-count`

## Notes

- The script auto-detects comma vs tab delimiters in the input file.
- For repos where size lookup fails, size fields are written as `0` and a row is added to `errors_*.csv`.
- Parallel mode is enabled per project only when that project's repository count exceeds `--parallel-threshold`.
