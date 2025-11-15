#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if a branch exists
branch_exists() {
    git ls-remote --heads origin "$1" | grep -q "$1"
}

# Get all commits in main that are not in staging
get_commits_to_sync() {
    local main_branch="$1"
    local staging_branch="$2"
    
    if ! branch_exists "$staging_branch"; then
        echo ""
        return
    fi
    
    git fetch origin "$main_branch" "$staging_branch" --quiet
    git log origin/"$staging_branch"..origin/"$main_branch" --pretty=format:"%H" 2>/dev/null || echo ""
}

# Sync commits from main to staging
sync_to_staging() {
    local main_branch="$MAIN_BRANCH"
    local staging_branch="$STAGING_BRANCH"
    
    log_info "Syncing commits from $main_branch to $staging_branch..."
    
    # Fetch latest changes
    git fetch origin "$main_branch" --quiet
    
    if ! branch_exists "$staging_branch"; then
        log_info "Staging branch $staging_branch does not exist, creating it from $main_branch..."
        git checkout -b "$staging_branch" "origin/$main_branch"
        git push origin "$staging_branch" --quiet
        log_info "Created staging branch $staging_branch"
        return 0
    fi
    
    # Fetch staging branch
    git fetch origin "$staging_branch" --quiet
    
    # Get commits to sync
    local commits_to_sync=$(get_commits_to_sync "$main_branch" "$staging_branch")
    
    if [ -z "$commits_to_sync" ]; then
        log_info "No new commits to sync from $main_branch to $staging_branch"
        return 0
    fi
    
    # Checkout staging branch
    git checkout "$staging_branch" --quiet
    git reset --hard "origin/$staging_branch" --quiet
    
    # Merge main into staging
    local merge_output=$(git merge "origin/$main_branch" --no-edit 2>&1)
    if [ $? -ne 0 ]; then
        log_warn "Merge conflict detected when syncing $main_branch to $staging_branch"
        git merge --abort 2>/dev/null || true
        
        # Find PRs that might be affected (PRs with staged label)
        if [ "$ENABLE_PR_LABELING" = "true" ]; then
            local affected_prs=$(get_prs_with_staged_label)
            if [ -n "$affected_prs" ]; then
                local comment="⚠️ **Auto-sync from \`$main_branch\` to \`$staging_branch\` failed**\n\n"
                comment+="A merge conflict occurred while syncing commits from \`$main_branch\` to \`$staging_branch\`. "
                comment+="This may affect staged PRs. The staging branch will need to be manually updated or reset.\n\n"
                comment+="You may need to:\n"
                comment+="1. Manually resolve conflicts in \`$staging_branch\`\n"
                comment+="2. Or reset \`$staging_branch\` to \`$main_branch\` (this will remove all staged changes)"
                
                while IFS= read -r pr_number; do
                    if [ -n "$pr_number" ]; then
                        post_pr_comment "$pr_number" "$comment"
                        log_info "Posted sync failure comment to PR #$pr_number"
                    fi
                done <<< "$affected_prs"
            fi
        fi
        
        return 1
    fi
    
    # Push changes
    git push origin "$staging_branch" --quiet
    log_info "Successfully synced commits from $main_branch to $staging_branch"
    
    # Update PR labels after sync
    if [ "$ENABLE_PR_LABELING" = "true" ]; then
        update_pr_labels_after_sync
    fi
    
    return 0
}

# Reset staging branch to main
reset_staging() {
    local main_branch="$MAIN_BRANCH"
    local staging_branch="$STAGING_BRANCH"
    
    log_info "Resetting $staging_branch to $main_branch..."
    
    git fetch origin "$main_branch" --quiet
    
    if ! branch_exists "$staging_branch"; then
        log_info "Staging branch $staging_branch does not exist, creating it from $main_branch..."
        git checkout -b "$staging_branch" "origin/$main_branch"
        git push origin "$staging_branch" --quiet
        log_info "Created staging branch $staging_branch"
        return 0
    fi
    
    # Get PRs that will be affected by reset
    local affected_prs=""
    if [ "$ENABLE_PR_LABELING" = "true" ]; then
        affected_prs=$(get_prs_with_staged_label)
    fi
    
    # Reset staging to main
    git checkout "$staging_branch" --quiet
    git reset --hard "origin/$main_branch" --quiet
    git push origin "$staging_branch" --force --quiet
    
    log_info "Successfully reset $staging_branch to $main_branch"
    
    # Remove staged labels from affected PRs
    if [ "$ENABLE_PR_LABELING" = "true" ] && [ -n "$affected_prs" ]; then
        while IFS= read -r pr_number; do
            if [ -n "$pr_number" ]; then
                remove_label "$pr_number" "$STAGED_LABEL"
                log_info "Removed $STAGED_LABEL label from PR #$pr_number (reset)"
            fi
        done <<< "$affected_prs"
    fi
    
    return 0
}

# Get PRs with staged label
get_prs_with_staged_label() {
    local response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$GITHUB_REPOSITORY/pulls?state=all&per_page=100")
    
    echo "$response" | jq -r ".[] | select(.labels[]?.name == \"$STAGED_LABEL\") | .number" 2>/dev/null || echo ""
}

# Check if a commit exists in a branch
commit_exists_in_branch() {
    local commit_sha="$1"
    local branch="$2"
    
    git fetch origin "$branch" --quiet
    git branch -r --contains "$commit_sha" | grep -q "origin/$branch" 2>/dev/null
}

# Add label to PR
add_label() {
    local pr_number="$1"
    local label="$2"
    
    curl -s -X POST \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$GITHUB_REPOSITORY/issues/$pr_number/labels" \
        -d "{\"labels\":[\"$label\"]}" > /dev/null
}

# Remove label from PR
remove_label() {
    local pr_number="$1"
    local label="$2"
    
    curl -s -X DELETE \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$GITHUB_REPOSITORY/issues/$pr_number/labels/$label" > /dev/null
}

# Post comment to PR
post_pr_comment() {
    local pr_number="$1"
    local comment="$2"
    
    local comment_json=$(jq -n --arg body "$comment" '{body: $body}')
    
    curl -s -X POST \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$GITHUB_REPOSITORY/issues/$pr_number/comments" \
        -d "$comment_json" > /dev/null
}

# Get PR commits
get_pr_commits() {
    local pr_number="$1"
    
    local response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$GITHUB_REPOSITORY/pulls/$pr_number/commits")
    
    echo "$response" | jq -r ".[].sha" 2>/dev/null || echo ""
}

# Check if all PR commits are in staging
all_pr_commits_in_staging() {
    local pr_number="$1"
    local staging_branch="$STAGING_BRANCH"
    
    local commits=$(get_pr_commits "$pr_number")
    
    if [ -z "$commits" ]; then
        return 1
    fi
    
    while IFS= read -r commit_sha; do
        if [ -n "$commit_sha" ]; then
            if ! commit_exists_in_branch "$commit_sha" "$staging_branch"; then
                return 1
            fi
        fi
    done <<< "$commits"
    
    return 0
}

# Handle PR labeled event
handle_pr_labeled() {
    # Handle both pull_request and issues events
    local pr_number=$(jq -r '.pull_request.number // .issue.number' "$GITHUB_EVENT_PATH")
    local label_added=$(jq -r '.label.name' "$GITHUB_EVENT_PATH")
    
    if [ "$pr_number" = "null" ] || [ -z "$pr_number" ]; then
        log_error "Could not determine PR number from event"
        return 1
    fi
    
    # Get current PR details from API (labels may have changed since PR was opened)
    local pr_response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$GITHUB_REPOSITORY/pulls/$pr_number")
    
    local base_branch=$(echo "$pr_response" | jq -r '.base.ref')
    local pr_state=$(echo "$pr_response" | jq -r '.state')
    
    # Only process PRs targeting the main branch
    if [ "$base_branch" != "$MAIN_BRANCH" ]; then
        log_info "PR #$pr_number targets branch '$base_branch', not '$MAIN_BRANCH'. Skipping."
        return 0
    fi
    
    if [ "$pr_state" != "open" ]; then
        log_warn "PR #$pr_number is not open (state: $pr_state), skipping staging"
        return 0
    fi
    
    # Check if the PR currently has the to-stage label (get current labels from API)
    local current_labels=$(echo "$pr_response" | jq -r '.labels[].name' | tr '\n' ' ')
    local has_to_stage_label=false
    
    if echo "$current_labels" | grep -q "\b$TO_STAGE_LABEL\b"; then
        has_to_stage_label=true
    fi
    
    # Only process if the label that was just added is to-stage, or if PR currently has to-stage label
    if [ "$label_added" != "$TO_STAGE_LABEL" ] && [ "$has_to_stage_label" != "true" ]; then
        log_info "Label added '$label_added' is not '$TO_STAGE_LABEL' and PR doesn't have '$TO_STAGE_LABEL', skipping"
        return 0
    fi
    
    if [ "$has_to_stage_label" != "true" ]; then
        log_info "PR #$pr_number doesn't currently have '$TO_STAGE_LABEL' label, skipping"
        return 0
    fi
    
    log_info "PR #$pr_number has $TO_STAGE_LABEL label, staging PR..."
    
    # Use the PR response we already fetched
    local pr_head=$(echo "$pr_response" | jq -r '.head.ref')
    local pr_sha=$(echo "$pr_response" | jq -r '.head.sha')
    
    if [ -z "$pr_head" ] || [ "$pr_head" = "null" ]; then
        log_error "Could not determine PR head branch"
        return 1
    fi
    
    # Fetch PR branch
    git fetch origin "$pr_head" --quiet
    
    # Ensure staging branch exists
    if ! branch_exists "$STAGING_BRANCH"; then
        git fetch origin "$MAIN_BRANCH" --quiet
        git checkout -b "$STAGING_BRANCH" "origin/$MAIN_BRANCH"
        git push origin "$STAGING_BRANCH" --quiet
    else
        git fetch origin "$STAGING_BRANCH" --quiet
        git checkout "$STAGING_BRANCH" --quiet
        git reset --hard "origin/$STAGING_BRANCH" --quiet
    fi
    
    # Merge PR into staging
    local merge_output=$(git merge "$pr_sha" --no-edit 2>&1)
    local merge_status=$?
    
    if [ $merge_status -eq 0 ]; then
        git push origin "$STAGING_BRANCH" --quiet
        log_info "Successfully merged PR #$pr_number into $STAGING_BRANCH"
        
        # Add staged label
        add_label "$pr_number" "$STAGED_LABEL"
        log_info "Added $STAGED_LABEL label to PR #$pr_number"
    else
        log_error "Failed to merge PR #$pr_number into $STAGING_BRANCH"
        git merge --abort 2>/dev/null || true
        
        # Post comment to PR about the failure
        local comment="❌ **Failed to stage this PR**\n\n"
        comment+="The merge into \`$STAGING_BRANCH\` failed. "
        
        if echo "$merge_output" | grep -qi "CONFLICT\|conflict"; then
            comment+="**Merge conflict detected.**\n\n"
            comment+="Please resolve the conflicts and try again. You may need to:\n"
            comment+="1. Update your branch with the latest changes from \`$STAGING_BRANCH\`\n"
            comment+="2. Resolve any conflicts\n"
            comment+="3. Remove and re-add the \`$TO_STAGE_LABEL\` label to retry staging"
        else
            comment+="**Merge error occurred.**\n\n"
            comment+="Please check your PR and try again. You can remove and re-add the \`$TO_STAGE_LABEL\` label to retry staging."
        fi
        
        post_pr_comment "$pr_number" "$comment"
        log_info "Posted failure comment to PR #$pr_number"
        return 1
    fi
}

# Handle PR unlabeled event
handle_pr_unlabeled() {
    # Handle both pull_request and issues events
    local pr_number=$(jq -r '.pull_request.number // .issue.number' "$GITHUB_EVENT_PATH")
    local label=$(jq -r '.label.name' "$GITHUB_EVENT_PATH")
    
    if [ "$label" = "$STAGED_LABEL" ]; then
        log_info "PR #$pr_number had $STAGED_LABEL label removed"
        # The label removal is already done, we just log it
    fi
}

# Handle PR reopened/synchronized event
handle_pr_reopened() {
    local pr_number=$(jq -r '.pull_request.number' "$GITHUB_EVENT_PATH")
    
    log_info "PR #$pr_number updated, checking if commits are still staged..."
    
    # Get current PR labels via API
    local pr_response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$GITHUB_REPOSITORY/pulls/$pr_number")
    
    local has_staged_label=$(echo "$pr_response" | jq -r '.labels[]?.name' | grep -q "^$STAGED_LABEL$" && echo "true" || echo "false")
    
    if [ "$has_staged_label" = "true" ]; then
        # Check if all commits are still in staging
        if ! all_pr_commits_in_staging "$pr_number"; then
            log_info "PR #$pr_number commits are no longer in staging, removing $STAGED_LABEL label..."
            remove_label "$pr_number" "$STAGED_LABEL"
        fi
    fi
}

# Update PR labels after sync
update_pr_labels_after_sync() {
    # Get all PRs and check their current labels from API
    local response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$GITHUB_REPOSITORY/pulls?state=all&per_page=100")
    
    echo "$response" | jq -r ".[] | select(.labels[]?.name == \"$STAGED_LABEL\") | .number" | while read -r pr_number; do
        if [ -n "$pr_number" ]; then
            # Check if all commits are still in staging (using current PR state from API)
            if ! all_pr_commits_in_staging "$pr_number"; then
                log_info "PR #$pr_number commits are no longer in staging, removing $STAGED_LABEL label..."
                remove_label "$pr_number" "$STAGED_LABEL"
            fi
        fi
    done
}

# Handle push event (sync main to staging, or check if manual staging needs sync)
handle_push() {
    local ref="$GITHUB_REF"
    local branch="${ref#refs/heads/}"
    
    if [ "$branch" = "$MAIN_BRANCH" ]; then
        # Push to main - always sync to staging
        log_info "Push detected to $MAIN_BRANCH, syncing to $STAGING_BRANCH..."
        sync_to_staging
    elif [ "$branch" = "$STAGING_BRANCH" ]; then
        # Push to staging - check if there are commits in main that aren't in staging
        log_info "Push detected to $STAGING_BRANCH, checking if sync is needed..."
        
        local commits_to_sync=$(get_commits_to_sync "$MAIN_BRANCH" "$STAGING_BRANCH")
        
        if [ -n "$commits_to_sync" ]; then
            log_info "Found commits in $MAIN_BRANCH that aren't in $STAGING_BRANCH, syncing..."
            sync_to_staging
        fi
    fi
}

# Main execution
main() {
    log_info "Starting auto-staging action..."
    log_info "Event: $GITHUB_EVENT_NAME"
    log_info "Repository: $GITHUB_REPOSITORY"
    log_info "Main branch: $MAIN_BRANCH"
    log_info "Staging branch: $STAGING_BRANCH"
    
    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        log_warn "jq is required but not installed. Attempting to install..."
        if command -v apt-get &> /dev/null; then
            sudo apt-get update -qq && sudo apt-get install -y jq > /dev/null 2>&1 || {
                log_error "Failed to install jq. Please ensure jq is available in your runner."
                exit 1
            }
        elif command -v brew &> /dev/null; then
            brew install jq > /dev/null 2>&1 || {
                log_error "Failed to install jq. Please ensure jq is available in your runner."
                exit 1
            }
        else
            log_error "jq is not installed and no package manager found. Please install jq manually."
            exit 1
        fi
    fi
    
    # Configure git
    git config --global --add safe.directory "$(pwd)"
    
    # Handle different events
    case "$GITHUB_EVENT_NAME" in
        "schedule")
            if [ "$ENABLE_SCHEDULED_RESET" = "true" ]; then
                reset_staging
            else
                log_info "Scheduled reset is disabled"
            fi
            ;;
        "pull_request")
            local action=$(jq -r '.action' "$GITHUB_EVENT_PATH")
            if [ "$ENABLE_PR_LABELING" = "true" ]; then
                case "$action" in
                    "opened"|"reopened"|"synchronize")
                        handle_pr_reopened
                        ;;
                esac
            fi
            ;;
        "issues")
            local action=$(jq -r '.action' "$GITHUB_EVENT_PATH")
            log_info "Issues event detected with action: $action"
            log_info "Event payload preview:"
            jq '{action, issue: {number: .issue.number, pull_request: .issue.pull_request}, label: .label.name}' "$GITHUB_EVENT_PATH" || true
            
            if [ "$ENABLE_PR_LABELING" = "true" ]; then
                # Check if this is actually a PR (not just an issue)
                local is_pr=$(jq -r '.issue.pull_request' "$GITHUB_EVENT_PATH")
                if [ "$is_pr" != "null" ] && [ -n "$is_pr" ]; then
                    if [ "$action" = "labeled" ]; then
                        log_info "Handling PR labeled event via issues webhook"
                        handle_pr_labeled
                    elif [ "$action" = "unlabeled" ]; then
                        log_info "Handling PR unlabeled event via issues webhook"
                        handle_pr_unlabeled
                    fi
                else
                    log_info "Event is for an issue, not a PR, skipping"
                fi
            fi
            ;;
        "push")
            if [ "$ENABLE_AUTO_SYNC" = "true" ]; then
                handle_push
            fi
            ;;
        "workflow_dispatch")
            # Manual trigger - sync staging
            if [ "$ENABLE_AUTO_SYNC" = "true" ]; then
                sync_to_staging
            fi
            ;;
        *)
            log_warn "Unhandled event: $GITHUB_EVENT_NAME"
            ;;
    esac
    
    log_info "Auto-staging action completed"
}

# Run main function
main "$@"

