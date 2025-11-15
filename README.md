<img width="4096" height="843" alt="Github Repository Header" src="https://github.com/user-attachments/assets/71d7ccef-892c-4d08-8a18-a94fcb25cce3" />
</br>
</br>

A powerful GitHub Action for automatically managing staging branches with configurable sync, reset, and PR labeling functionality.

## Features

- ✅ **Auto-sync staging branch** - Automatically syncs commits from main branch to staging branch
- ✅ **Scheduled reset** - Resets staging branch to main on a configurable schedule (default: every Sunday at midnight)
- ✅ **PR labeling** - Automatically stage PRs when labeled with `to-stage`, and mark them as `staged` when complete
- ✅ **Smart label management** - Removes `staged` labels when PRs are removed from staging or when commits are no longer staged
- ✅ **Manual sync detection** - Detects when commits are manually added to staging and syncs if needed
- ✅ **Fully configurable** - All branch names, labels, and behaviors are configurable

## Usage

Create a workflow file (e.g., `.github/workflows/auto-staging.yml`) in your repository:

```yaml
name: Auto Staging

on:
  # Scheduled reset every Sunday at midnight
  schedule:
    - cron: '0 0 * * 0'  # Sunday midnight UTC
  # Trigger on push to main or staging
  push:
    branches:
      - main
      - staging
  # Trigger on PR events (including label events)
  pull_request:
    branches:
      - main
    types: [opened, reopened, synchronize, labeled, unlabeled]
  # Allow manual triggering
  workflow_dispatch:

jobs:
  auto-staging:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
      issues: write
    
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          token: ${{ secrets.GITHUB_TOKEN }}
      
      - name: Run Auto Staging
        uses: Plexverse/auto-staging@v1
        with:
          main_branch: 'main'
          staging_branch: 'staging'
          to_stage_label: 'to-stage'
          staged_label: 'staged'
          github_token: ${{ secrets.GITHUB_TOKEN }}
          enable_auto_sync: 'true'
          enable_scheduled_reset: 'true'
          enable_pr_labeling: 'true'
```

## Configuration Options

All inputs are optional and have sensible defaults:

| Input | Description | Default | Required |
|-------|-------------|---------|----------|
| `main_branch` | Name of the main branch | `main` | No |
| `staging_branch` | Name of the staging branch | `staging` | No |
| `to_stage_label` | Label to trigger staging a PR | `to-stage` | No |
| `staged_label` | Label to mark a PR as staged | `staged` | No |
| `github_token` | GitHub token for API calls | - | Yes |
| `reset_schedule` | Cron schedule for resetting staging branch | `0 0 * * 0` | No |
| `enable_auto_sync` | Enable auto-sync of main branch commits to staging | `true` | No |
| `enable_scheduled_reset` | Enable scheduled reset of staging branch | `true` | No |
| `enable_pr_labeling` | Enable PR labeling functionality | `true` | No |

## How It Works

### Auto-Sync

When commits are pushed to the `main` branch, the action automatically:
1. Checks if there are new commits in `main` that aren't in `staging`
2. Merges those commits into `staging`
3. Updates PR labels if any staged PRs are affected

### Scheduled Reset

On the configured schedule (default: Sunday midnight UTC), the action:
1. Resets the `staging` branch to match `main` exactly
2. Removes `staged` labels from all PRs that were affected by the reset

### PR Labeling

When a PR is labeled with the `to-stage` label:
1. The action merges the PR into the `staging` branch
2. Adds the `staged` label to the PR
3. If the merge fails (e.g., due to conflicts), the action posts a comment on the PR explaining the issue and doesn't add the `staged` label

When a PR is reopened or synchronized:
1. The action checks if the PR has the `staged` label
2. Verifies if all PR commits are still in the `staging` branch
3. Removes the `staged` label if commits are no longer staged

### Manual Sync Detection

When commits are manually pushed to the `staging` branch:
1. The action detects the push event
2. Checks if there are commits in `main` that aren't in `staging`
3. Automatically syncs those commits if found

## Examples

### Custom Branch Names

```yaml
- name: Run Auto Staging
  uses: Plexverse/auto-staging@v1
  with:
    main_branch: 'master'
    staging_branch: 'develop'
    github_token: ${{ secrets.GITHUB_TOKEN }}
```

### Custom Labels

```yaml
- name: Run Auto Staging
  uses: Plexverse/auto-staging@v1
  with:
    to_stage_label: 'ready-for-staging'
    staged_label: 'in-staging'
    github_token: ${{ secrets.GITHUB_TOKEN }}
```

### Disable Scheduled Reset

```yaml
- name: Run Auto Staging
  uses: Plexverse/auto-staging@v1
  with:
    enable_scheduled_reset: 'false'
    github_token: ${{ secrets.GITHUB_TOKEN }}
```

### Custom Reset Schedule

```yaml
- name: Run Auto Staging
  uses: Plexverse/auto-staging@v1
  with:
    reset_schedule: '0 2 * * 1'  # Every Monday at 2 AM UTC
    github_token: ${{ secrets.GITHUB_TOKEN }}
```

### Disable PR Labeling

```yaml
- name: Run Auto Staging
  uses: Plexverse/auto-staging@v1
  with:
    enable_pr_labeling: 'false'
    github_token: ${{ secrets.GITHUB_TOKEN }}
```

## Permissions

The action requires the following permissions:

- `contents: write` - To push changes to the staging branch
- `pull-requests: write` - To add/remove labels on PRs
- `issues: write` - To post comments on PRs (PRs are treated as issues in the GitHub API)

## Requirements

- `jq` - The action will automatically install `jq` if it's not available
- Git with proper authentication configured
- A GitHub token with appropriate permissions

## Troubleshooting

### Staging branch doesn't exist

The action will automatically create the staging branch from the main branch if it doesn't exist.

### Merge conflicts

If a merge conflict occurs when syncing or staging a PR, the action will:
- Log a warning
- Abort the merge
- Not push any changes
- Post a comment on affected PRs explaining the conflict and how to resolve it
- For PR staging, not add the `staged` label

### PR labels not updating

Ensure that:
- The `enable_pr_labeling` input is set to `true`
- The GitHub token has `pull-requests: write` permission
- The labels (`to-stage` and `staged`) exist in your repository

## License

This action is provided as-is. Modify as needed for your use case.
