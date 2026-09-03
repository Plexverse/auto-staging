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

# ---------------------------------------------------------------------------
# Failure reporting
#
# Anything that goes wrong while staging a PR has to end up as a comment on
# that PR, not just as red text in the job log. STAGE_PR_NUMBER is set as soon
# as we know which PR we are staging so that the EXIT trap below can still
# report a failure from a place we did not explicitly guard.
# ---------------------------------------------------------------------------

# Honours GITHUB_API_URL so the action also works on GitHub Enterprise.
API_URL="${GITHUB_API_URL:-https://api.github.com}"

STAGE_PR_NUMBER=""        # PR currently being staged, empty when not staging
FAILURE_REPORTED="false"  # set once we have commented about a failure
CURRENT_STEP="starting up"

# Record what we are doing, so an unexpected failure can say where it happened.
set_step() {
    CURRENT_STEP="$1"
}

# Link back to the run that produced the failure.
run_url() {
    if [ -n "$GITHUB_SERVER_URL" ] && [ -n "$GITHUB_RUN_ID" ]; then
        echo "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
    else
        echo "https://github.com/$GITHUB_REPOSITORY/actions"
    fi
}

# Render command output inside a collapsed block, or nothing when there is none.
details_block() {
    local summary="$1"
    local content="$2"

    if [ -z "$content" ]; then
        return 0
    fi

    printf '<details><summary>%s</summary>\n\n```\n%s\n```\n\n</details>' \
        "$summary" "$content"
}

# Post a failure comment on the PR being staged. Only the first failure of a
# run is reported, so the trap does not double up on an already-reported error.
report_staging_failure() {
    local pr_number="$1"
    local body="$2"

    if [ -z "$pr_number" ]; then
        log_warn "Failure is not associated with a PR, cannot post a comment"
        return 0
    fi

    if [ "$FAILURE_REPORTED" = "true" ]; then
        return 0
    fi

    FAILURE_REPORTED="true"

    if post_pr_comment "$pr_number" "$body"; then
        log_info "Posted failure comment to PR #$pr_number"
    else
        log_error "Could not post failure comment to PR #$pr_number"
    fi
}

# Report a staging failure on the current PR. Always returns non-zero so the
# caller can `return 1` straight after it and the job goes red.
# Usage: stage_failed <what went wrong> <what to do about it> [command output]
stage_failed() {
    local reason="$1"
    local remedy="$2"
    local output="${3:-}"
    local body

    body="❌ **Failed to stage this PR**"$'\n\n'
    body+="$reason"$'\n\n'
    body+="$remedy"$'\n\n'

    local details
    details=$(details_block "git output" "$output")
    if [ -n "$details" ]; then
        body+="$details"$'\n\n'
    fi

    body+="[View the action run]($(run_url))"

    report_staging_failure "$STAGE_PR_NUMBER" "$body"
    return 1
}

# Post a comment on every PR that currently carries the staged label. Used for
# failures that affect staging as a whole rather than one specific PR.
comment_on_staged_prs() {
    local body="$1"
    local affected_prs
    affected_prs=$(get_prs_with_staged_label)

    if [ -z "$affected_prs" ]; then
        log_warn "No staged PRs to notify about this failure"
        return 0
    fi

    local pr_number
    while IFS= read -r pr_number; do
        if [ -n "$pr_number" ]; then
            if post_pr_comment "$pr_number" "$body"; then
                log_info "Posted failure comment to PR #$pr_number"
            else
                log_error "Could not post failure comment to PR #$pr_number"
            fi
        fi
    done <<< "$affected_prs"
}

# Runs on every exit. Guarantees that an unexpected non-zero exit while staging
# a PR still reaches the PR instead of dying quietly in the job log.
on_exit() {
    local status=$?
    trap - EXIT

    if [ "$status" -ne 0 ] && [ "$FAILURE_REPORTED" != "true" ] && [ -n "$STAGE_PR_NUMBER" ]; then
        log_error "Unexpected failure (exit code $status) while $CURRENT_STEP"
        stage_failed \
            "The staging action exited unexpectedly (exit code \`$status\`) while $CURRENT_STEP, so \`$STAGING_BRANCH\` may not contain this PR." \
            "Check the action run for details, then remove and re-add the \`$TO_STAGE_LABEL\` label to retry." \
            "" || true
    fi

    exit "$status"
}

trap on_exit EXIT

# Check if a branch exists
branch_exists() {
    git ls-remote --heads origin "$1" | grep -q "$1"
}

# Ensure the staging branch exists and matches the current remote tip. Safe to
# call again on a retry, which is why it resets rather than assuming a fresh
# checkout.
prepare_staging_branch() {
    if ! branch_exists "$STAGING_BRANCH"; then
        git fetch origin "$MAIN_BRANCH" --quiet
        git checkout -B "$STAGING_BRANCH" "origin/$MAIN_BRANCH" --quiet
        git push origin "$STAGING_BRANCH" --quiet
    else
        git fetch origin "$STAGING_BRANCH" --quiet
        git checkout -B "$STAGING_BRANCH" "origin/$STAGING_BRANCH" --quiet
    fi
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
    
    # Merge main into staging.
    #
    # NOTE: the declaration and the assignment are deliberately split. In
    # `local x=$(cmd)` the exit status belongs to `local`, which is always 0,
    # so `$?` never saw the failure and conflicts were treated as successes.
    local merge_output=""
    local merge_status=0
    merge_output=$(git merge "origin/$main_branch" --no-edit 2>&1) || merge_status=$?

    if [ "$merge_status" -ne 0 ]; then
        log_warn "Merge conflict detected when syncing $main_branch to $staging_branch"
        git merge --abort 2>/dev/null || true
        
        # Tell the PRs that are sitting in staging that the sync broke
        if [ "$ENABLE_PR_LABELING" = "true" ]; then
            local comment
            comment="⚠️ **Auto-sync from \`$main_branch\` to \`$staging_branch\` failed**"$'\n\n'
            comment+="A merge conflict occurred while syncing commits from \`$main_branch\` to \`$staging_branch\`. This may affect staged PRs, and \`$staging_branch\` will need to be manually updated or reset."$'\n\n'
            comment+="You may need to:"$'\n'
            comment+="1. Manually resolve conflicts in \`$staging_branch\`"$'\n'
            comment+="2. Or reset \`$staging_branch\` to \`$main_branch\` (this will remove all staged changes)"$'\n\n'

            local details
            details=$(details_block "git output" "$merge_output")
            if [ -n "$details" ]; then
                comment+="$details"$'\n\n'
            fi

            comment+="[View the action run]($(run_url))"

            comment_on_staged_prs "$comment"
        fi
        
        return 1
    fi
    
    # Push changes. A rejected push used to kill the script under `set -e`
    # without a word to anyone, leaving staging silently behind main.
    local push_output=""
    local push_status=0
    push_output=$(git push origin "$staging_branch" 2>&1) || push_status=$?

    if [ "$push_status" -ne 0 ]; then
        log_error "Failed to push $staging_branch after syncing $main_branch"

        if [ "$ENABLE_PR_LABELING" = "true" ]; then
            local comment
            comment="⚠️ **Auto-sync from \`$main_branch\` to \`$staging_branch\` failed**"$'\n\n'
            comment+="The merge succeeded but pushing \`$staging_branch\` was rejected, so \`$staging_branch\` is still behind \`$main_branch\`."$'\n\n'

            local details
            details=$(details_block "git output" "$push_output")
            if [ -n "$details" ]; then
                comment+="$details"$'\n\n'
            fi

            comment+="[View the action run]($(run_url))"

            comment_on_staged_prs "$comment"
        fi

        return 1
    fi

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
        "$API_URL/repos/$GITHUB_REPOSITORY/pulls?state=all&per_page=100")
    
    echo "$response" | jq -r ".[] | select(.labels[]?.name == \"$STAGED_LABEL\") | .number" 2>/dev/null || echo ""
}

# Check if a commit exists in a branch
commit_exists_in_branch() {
    local commit_sha="$1"
    local branch="$2"
    
    git fetch origin "$branch" --quiet
    git branch -r --contains "$commit_sha" | grep -q "origin/$branch" 2>/dev/null
}

# Add label to PR. Label problems are warnings, not run-stopping failures.
add_label() {
    local pr_number="$1"
    local label="$2"
    local http_code

    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "$API_URL/repos/$GITHUB_REPOSITORY/issues/$pr_number/labels" \
        -d "{\"labels\":[\"$label\"]}") || http_code="000"

    if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
        log_warn "Could not add label '$label' to PR #$pr_number (HTTP $http_code)"
    fi

    return 0
}

# Remove label from PR. A 404 just means the label was not there.
remove_label() {
    local pr_number="$1"
    local label="$2"
    local http_code

    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "$API_URL/repos/$GITHUB_REPOSITORY/issues/$pr_number/labels/$label") || http_code="000"

    if [ "$http_code" != "200" ] && [ "$http_code" != "404" ]; then
        log_warn "Could not remove label '$label' from PR #$pr_number (HTTP $http_code)"
    fi

    return 0
}

# Post comment to PR. Returns non-zero if GitHub did not accept the comment, so
# a failure to report a failure is itself visible in the log.
post_pr_comment() {
    local pr_number="$1"
    local comment="$2"

    local comment_json
    comment_json=$(jq -n --arg body "$comment" '{body: $body}')

    local response_file
    response_file=$(mktemp)

    local http_code
    http_code=$(curl -s -o "$response_file" -w "%{http_code}" -X POST \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "$API_URL/repos/$GITHUB_REPOSITORY/issues/$pr_number/comments" \
        -d "$comment_json") || http_code="000"

    if [ "$http_code" != "201" ]; then
        log_error "GitHub rejected the comment on PR #$pr_number (HTTP $http_code): $(head -c 500 "$response_file")"
        rm -f "$response_file"
        return 1
    fi

    rm -f "$response_file"
    return 0
}

# Get PR commits
get_pr_commits() {
    local pr_number="$1"
    
    local response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "$API_URL/repos/$GITHUB_REPOSITORY/pulls/$pr_number/commits")
    
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
    local pr_number=$(jq -r '.pull_request.number' "$GITHUB_EVENT_PATH")
    local label_added=$(jq -r '.label.name' "$GITHUB_EVENT_PATH")
    
    if [ "$pr_number" = "null" ] || [ -z "$pr_number" ]; then
        log_error "Could not determine PR number from event"
        return 1
    fi
    
    # Get current PR details from API (labels may have changed since PR was opened)
    local pr_response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "$API_URL/repos/$GITHUB_REPOSITORY/pulls/$pr_number")
    
    # A failed API read used to leave base_branch as "null", which fell through
    # to the "targets another branch, skipping" path and reported success.
    if [ -z "$pr_response" ] || [ "$(echo "$pr_response" | jq -r '.number // "null"')" = "null" ]; then
        log_error "Could not read PR #$pr_number from the GitHub API"
        STAGE_PR_NUMBER="$pr_number"
        stage_failed \
            "Could not read this PR from the GitHub API, so it was not staged." \
            "This is usually a transient API error. Remove and re-add the \`$TO_STAGE_LABEL\` label to retry." \
            "$(echo "$pr_response" | head -c 500)"
        return 1
    fi

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
        STAGE_PR_NUMBER="$pr_number"
        stage_failed \
            "Could not determine the head branch of this PR, so it was not staged." \
            "Remove and re-add the \`$TO_STAGE_LABEL\` label to retry." \
            ""
        return 1
    fi
    
    # From here on we know which PR we are staging. Every failure below - the
    # ones handled explicitly and the ones we did not think of - now reaches
    # the PR, via stage_failed or via the EXIT trap.
    STAGE_PR_NUMBER="$pr_number"
    
    # Fetch PR branch
    set_step "fetching the PR branch \`$pr_head\`"
    local fetch_output=""
    if ! fetch_output=$(git fetch origin "$pr_head" 2>&1); then
        log_error "Could not fetch PR branch $pr_head"
        stage_failed \
            "Could not fetch the PR branch \`$pr_head\`, so \`$STAGING_BRANCH\` was not updated." \
            "This usually means the branch was deleted, or it lives on a fork this action cannot read. Push the branch to this repository, then remove and re-add the \`$TO_STAGE_LABEL\` label to retry." \
            "$fetch_output"
        return 1
    fi
    
    # Merge into staging and push. A concurrent push to the staging branch
    # rejects ours, so re-sync and retry a few times before giving up - that
    # race used to drop the merge without telling anyone.
    local max_attempts=3
    local attempt=1
    local merge_output=""
    local merge_status=0
    local push_output=""
    local push_status=0
    local prep_output=""
    
    while true; do
        set_step "updating \`$STAGING_BRANCH\` (attempt $attempt of $max_attempts)"
        
        if ! prep_output=$(prepare_staging_branch 2>&1); then
            log_error "Could not prepare $STAGING_BRANCH for the merge"
            stage_failed \
                "Could not prepare \`$STAGING_BRANCH\` for the merge, so it was not updated." \
                "Check the action run, then remove and re-add the \`$TO_STAGE_LABEL\` label to retry." \
                "$prep_output"
            return 1
        fi
        
        # NOTE: the declaration and the assignment are deliberately split. In
        # `local x=$(cmd)` the exit status belongs to `local`, which is always
        # 0, so a conflicted merge used to take the success path - pushing
        # nothing, logging "Successfully merged", and labelling the PR staged.
        merge_status=0
        merge_output=$(git merge "$pr_sha" --no-edit 2>&1) || merge_status=$?
        
        if [ "$merge_status" -ne 0 ]; then
            log_error "Failed to merge PR #$pr_number into $STAGING_BRANCH"
            git merge --abort 2>/dev/null || true
            
            if echo "$merge_output" | grep -qi "conflict"; then
                stage_failed \
                    "Merging this PR into \`$STAGING_BRANCH\` hit a **merge conflict**, so \`$STAGING_BRANCH\` was not updated." \
                    "$(printf '%s\n%s\n%s\n%s' \
                        "To retry:" \
                        "1. Merge the latest \`$STAGING_BRANCH\` into your branch" \
                        "2. Resolve the conflicts and push" \
                        "3. Remove and re-add the \`$TO_STAGE_LABEL\` label")" \
                    "$merge_output"
            else
                stage_failed \
                    "Merging this PR into \`$STAGING_BRANCH\` failed, so \`$STAGING_BRANCH\` was not updated." \
                    "Check the git output below, then remove and re-add the \`$TO_STAGE_LABEL\` label to retry." \
                    "$merge_output"
            fi
            return 1
        fi
        
        push_status=0
        push_output=$(git push origin "$STAGING_BRANCH" 2>&1) || push_status=$?
        
        if [ "$push_status" -eq 0 ]; then
            break
        fi
        
        log_warn "Push to $STAGING_BRANCH was rejected (attempt $attempt of $max_attempts)"
        
        if [ "$attempt" -ge "$max_attempts" ]; then
            stage_failed \
                "The merge succeeded but pushing \`$STAGING_BRANCH\` was rejected $max_attempts times, so this PR is **not** staged." \
                "Something else is pushing to \`$STAGING_BRANCH\` at the same time. Remove and re-add the \`$TO_STAGE_LABEL\` label to retry." \
                "$push_output"
            return 1
        fi
        
        attempt=$((attempt + 1))
        sleep $(( attempt * 5 ))
    done
    
    # Do not trust the push on its own - confirm the PR head really is an
    # ancestor of the remote staging branch before reporting success.
    set_step "verifying \`$STAGING_BRANCH\` contains this PR"
    git fetch origin "$STAGING_BRANCH" --quiet
    
    if ! git merge-base --is-ancestor "$pr_sha" "origin/$STAGING_BRANCH"; then
        log_error "PR #$pr_number is not contained in origin/$STAGING_BRANCH after pushing"
        stage_failed \
            "\`$STAGING_BRANCH\` was pushed but does not contain \`$pr_sha\`, so this PR is **not** staged." \
            "Something else moved \`$STAGING_BRANCH\` at the same time. Remove and re-add the \`$TO_STAGE_LABEL\` label to retry." \
            ""
        return 1
    fi
    
    log_info "Successfully merged PR #$pr_number into $STAGING_BRANCH"
    
    # Add staged label
    add_label "$pr_number" "$STAGED_LABEL"
    log_info "Added $STAGED_LABEL label to PR #$pr_number"
    
    # Remove to-stage label since staging is complete
    remove_label "$pr_number" "$TO_STAGE_LABEL"
    log_info "Removed $TO_STAGE_LABEL label from PR #$pr_number (staging complete)"
    
    STAGE_PR_NUMBER=""
    return 0
}

# Handle PR unlabeled event
handle_pr_unlabeled() {
    local pr_number=$(jq -r '.pull_request.number' "$GITHUB_EVENT_PATH")
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
    
    # Get current PR details from API (labels may have changed)
    local pr_response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "$API_URL/repos/$GITHUB_REPOSITORY/pulls/$pr_number")
    
    # Get current labels from API response (not from event payload)
    local current_labels=$(echo "$pr_response" | jq -r '.labels[].name')
    local has_staged_label=false
    
    if echo "$current_labels" | grep -q "^$STAGED_LABEL$"; then
        has_staged_label=true
    fi
    
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
        "$API_URL/repos/$GITHUB_REPOSITORY/pulls?state=all&per_page=100")
    
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
            log_info "Pull request event detected with action: $action"
            if [ "$ENABLE_PR_LABELING" = "true" ]; then
                case "$action" in
                    "opened"|"reopened"|"synchronize")
                        handle_pr_reopened
                        ;;
                    "labeled")
                        log_info "Handling PR labeled event"
                        handle_pr_labeled
                        ;;
                    "unlabeled")
                        log_info "Handling PR unlabeled event"
                        handle_pr_unlabeled
                        ;;
                esac
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

