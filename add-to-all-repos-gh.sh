#!/bin/bash
# Script to add auto-staging workflow to all Plexverse repositories using GitHub CLI

set -e

ORG="Plexverse"
WORKFLOW_FILE=".github/workflows/auto-staging.yml"

# Function to convert repo name to display name
get_display_name() {
    local repo_name="$1"
    # Convert kebab-case to Title Case
    echo "$repo_name" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2));}1'
}

# Function to get workflow content for a repo
get_workflow_content() {
    local repo_name="$1"
    local display_name=$(get_display_name "$repo_name")
    local workflow_name="${display_name} 🔁 Auto Staging"
    
    cat <<EOF
name: $workflow_name

on:
  # Scheduled reset every Sunday at midnight
  schedule:
    - cron: '0 0 * * 0'  # Sunday midnight UTC
  # Trigger on push to main or staging (to sync to staging)
  push:
    branches:
      - main
      - staging
  # Trigger on PR events (including label events)
  pull_request:
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
          token: \${{ secrets.GITHUB_TOKEN }}
      
      - name: Run Auto Staging
        uses: Plexverse/auto-staging@v1
        with:
          main_branch: 'main'
          staging_branch: 'staging'
          to_stage_label: 'to-stage'
          staged_label: 'staged'
          github_token: \${{ secrets.GITHUB_TOKEN }}
          reset_schedule: '0 0 * * 0'
          enable_auto_sync: 'true'
          enable_scheduled_reset: 'true'
          enable_pr_labeling: 'true'
EOF
}

# Function to add workflow to a repository
add_workflow_to_repo() {
    local repo="$1"
    local temp_file=$(mktemp)
    
    # Get workflow content
    get_workflow_content "$repo" > "$temp_file"
    
    # Base64 encode the content
    local encoded_content
    if [[ "$OSTYPE" == "darwin"* ]]; then
        encoded_content=$(base64 < "$temp_file")
    else
        encoded_content=$(base64 -w 0 < "$temp_file")
    fi
    
    # Check if file exists
    if gh api "repos/$ORG/$repo/contents/$WORKFLOW_FILE" > /dev/null 2>&1; then
        # File exists, get SHA and update
        local sha=$(gh api "repos/$ORG/$repo/contents/$WORKFLOW_FILE" --jq '.sha')
        echo "Updating workflow in $repo..."
        
        gh api -X PUT "repos/$ORG/$repo/contents/$WORKFLOW_FILE" \
            -f message="Update auto-staging workflow" \
            -f content="$encoded_content" \
            -f sha="$sha" > /dev/null
        
        echo "✓ Updated workflow in $repo"
    else
        # File doesn't exist, create it
        echo "Creating workflow in $repo..."
        
        gh api -X PUT "repos/$ORG/$repo/contents/$WORKFLOW_FILE" \
            -f message="Add auto-staging workflow" \
            -f content="$encoded_content" > /dev/null
        
        echo "✓ Created workflow in $repo"
    fi
    
    rm -f "$temp_file"
}

# Get all repositories
echo "Fetching repositories from $ORG..."
repos=$(gh repo list "$ORG" --limit 100 --json name --jq '.[].name')

if [ -z "$repos" ]; then
    echo "Error: No repositories found"
    exit 1
fi

echo "Found repositories:"
echo "$repos" | while read -r repo; do
    echo "  - $repo"
done

echo ""

# Check for -y flag or AUTO_YES environment variable
if [[ "$1" == "-y" ]] || [[ "$AUTO_YES" == "true" ]]; then
    echo "Auto-confirming (non-interactive mode)..."
else
    read -p "Add auto-staging workflow to all repositories? (y/N) " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 0
    fi
fi

echo ""
echo "Adding workflows to repositories..."
echo ""

success_count=0
fail_count=0

while IFS= read -r repo; do
    if [ -n "$repo" ]; then
        if add_workflow_to_repo "$repo"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
            echo "✗ Failed to process $repo"
        fi
        sleep 0.5  # Rate limiting
    fi
done <<< "$repos"

echo ""
echo "Summary:"
echo "  Success: $success_count"
echo "  Failed: $fail_count"

