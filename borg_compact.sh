#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Borg Repository Compaction Script
# 
# Performs health-checked compaction of all Borg repositories
# in a Docker container, with automatic quota adjustment
# when used space exceeds configured quota.
#
# Healthcheck Levels:
#   1. Start: status=up&msg=OK
#   2. Per-repo: status=up/down&msg=<repo_id>
#   3. Finish: status=up&msg=finish or status=down&msg=fail
#
# Usage:
#   ./borg_compact.sh              # Normal mode with auto-detect verbosity
#   ./borg_compact.sh --dry-run   # Dry-run mode (no changes, no healthchecks)
#   ./borg_compact.sh -n           # Dry-run mode (short form)
#   VERBOSE=true ./borg_compact.sh # Force verbose output
#   VERBOSE=false ./borg_compact.sh # Force quiet output
#
# Verbosity:
#   VERBOSE=true  - Force verbose output (show all command output)
#   VERBOSE=false - Force quiet output (suppress command output)
#   VERBOSE unset - Auto-detect: verbose in terminal, quiet otherwise
# ============================================================

# ------------------------------------------------------------------
# CONFIGURATION (Environment variables with defaults)
# ------------------------------------------------------------------

UPTIMEKUMA_DOMAIN=${UPTIMEKUMA_DOMAIN:-example.com}
HEALTHCHECK_ID=${HEALTHCHECK_ID:-qwerty123}
CONTAINER_NAME=${CONTAINER_NAME:-borgwarehouse-borgwarehouse-1}
REPO_DIR=${REPO_DIR:-/home/borgwarehouse/repos}
EXTRA_QUOTA_G=${EXTRA_QUOTA_G:-10}

# Retry configuration for lock contention
RETRY_INTERVAL_SECONDS=${RETRY_INTERVAL_SECONDS:-300}
RETRY_MAX_ATTEMPTS=${RETRY_MAX_ATTEMPTS:-5}

# Constants
BYTES_PER_G=1073741824
BYTES_PER_M=1048576
BYTES_PER_K=1024
BYTES_PER_T=1099511627776

# ------------------------------------------------------------------
# VERBOSITY CONTROL
# ------------------------------------------------------------------

# Auto-detect interactive mode if VERBOSE not explicitly set
if [[ -z "${VERBOSE:-}" ]]; then
    if [[ $- == *i* ]] || [[ -t 0 ]]; then
        VERBOSE=true
    else
        VERBOSE=false
    fi
fi

# ------------------------------------------------------------------
# LOGGING FUNCTIONS
# ------------------------------------------------------------------

# Always log essential messages
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# Log verbose messages only when VERBOSE=true
log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')]   $*"
    fi
}

# Execute command with conditional output based on VERBOSE
verbose_exec() {
    if [ "$VERBOSE" = true ]; then
        "$@"
    else
        "$@" > /dev/null 2>&1
    fi
}

# ------------------------------------------------------------------
# RETRY HELPER FUNCTIONS
# ------------------------------------------------------------------

# Execute borg config command with retry logic
# Returns:
#   0 - Success
#   1 - Permanent failure (non-lock error)
#   2 - Lock contention failure (after all retries exhausted)
execute_borg_config() {
    local repo_path="$1"
    local key="$2"
    local value="${3:-}"
    local attempt=1
    local output
    local borg_command
    
    if [ -n "$value" ]; then
        borg_command="borg config $repo_path $key $value"
    else
        borg_command="borg config $repo_path $key"
    fi
    
    while [ $attempt -le $RETRY_MAX_ATTEMPTS ]; do
        output=$(docker exec "$CONTAINER_NAME" bash -c "$borg_command" 2>&1)
        local exit_code=$?
        
        if [ $exit_code -eq 0 ]; then
            echo "$output"
            return 0
        fi
        
        # Check if error is due to lock
        if echo "$output" | grep -qi "lock"; then
            log_verbose "Lock detected on attempt $attempt/$RETRY_MAX_ATTEMPTS for borg config on $repo_path, retrying..."
        else
            log_verbose "Non-lock error on attempt $attempt/$RETRY_MAX_ATTEMPTS for borg config on $repo_path"
        fi
        
        if [ $attempt -lt $RETRY_MAX_ATTEMPTS ]; then
            sleep $RETRY_INTERVAL_SECONDS
        fi
        attempt=$((attempt + 1))
    done
    
    # After all retries, check if it was a lock issue
    if echo "$output" | grep -qi "lock"; then
        return 2
    fi
    return 1
}

# Execute borg compact command with retry logic
# Returns:
#   0 - Success
#   1 - Permanent failure (non-lock error)
#   2 - Lock contention failure (after all retries exhausted)
execute_borg_compact() {
    local repo_path="$1"
    local attempt=1
    local output
    
    while [ $attempt -le $RETRY_MAX_ATTEMPTS ]; do
        output=$(docker exec "$CONTAINER_NAME" bash -c "borg compact --verbose $repo_path" 2>&1)
        local exit_code=$?
        
        if [ $exit_code -eq 0 ]; then
            if [ "$VERBOSE" = true ]; then
                # Filter out duplicate "Storage quota:" lines from borg's verbose output
                echo "$output" | grep -v "^Storage quota:"
            fi
            return 0
        fi
        
        # Check if error is due to lock
        if echo "$output" | grep -qi "lock"; then
            log_verbose "Lock detected on attempt $attempt/$RETRY_MAX_ATTEMPTS for borg compact on $repo_path, retrying..."
        else
            log_verbose "Non-lock error on attempt $attempt/$RETRY_MAX_ATTEMPTS for borg compact on $repo_path"
        fi
        
        if [ $attempt -lt $RETRY_MAX_ATTEMPTS ]; then
            sleep $RETRY_INTERVAL_SECONDS
        fi
        attempt=$((attempt + 1))
    done
    
    # After all retries, check if it was a lock issue
    if echo "$output" | grep -qi "lock"; then
        return 2
    fi
    return 1
}

# ------------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------------

# Send healthcheck to UptimeKuma
healthcheck() {
    local status=$1
    local msg=$2
    
    log "[HEALTHCHECK] Sending: status=$status msg=$msg"
    
    docker exec "$CONTAINER_NAME" bash -c \
        "curl -fsS --retry 5 -o /dev/null https://$UPTIMEKUMA_DOMAIN/api/push/$HEALTHCHECK_ID?status=$status&msg=$msg&ping=" \
        > /dev/null 2>&1 || true
}

# Convert human-readable size to bytes
to_bytes() {
    local size=$1
    
    if [ -z "$size" ]; then
        echo 0
        return
    fi
    
    size=${size// /}
    
    if [[ $size =~ ^[0-9]+B?$ ]]; then
        echo "${size%B}"
        return
    fi
    
    if [[ $size =~ ^[0-9]+$ ]]; then
        echo "$size"
        return
    fi
    
    if [[ $size =~ ^([0-9.]+)([A-Za-z]+)$ ]]; then
        local num=${BASH_REMATCH[1]}
        local unit=${BASH_REMATCH[2]}
        
        unit=$(echo "$unit" | tr '[:lower:]' '[:upper:]' | sed 's/B$//')
        
        if [ -z "$unit" ]; then
            echo "${size%B}" | sed 's/[^0-9.]//g'
            return
        fi
        
        case $unit in
            K)  echo "$(echo "$num * $BYTES_PER_K" | bc 2>/dev/null || echo $((num * BYTES_PER_K)))" | cut -d. -f1 ;;
            M)  echo "$(echo "$num * $BYTES_PER_M" | bc 2>/dev/null || echo $((num * BYTES_PER_M)))" | cut -d. -f1 ;;
            G)  echo "$(echo "$num * $BYTES_PER_G" | bc 2>/dev/null || echo $((num * BYTES_PER_G)))" | cut -d. -f1 ;;
            T)  echo "$(echo "$num * $BYTES_PER_T" | bc 2>/dev/null || echo $((num * BYTES_PER_T)))" | cut -d. -f1 ;;
            *)  echo "$size" ;;
        esac
    else
        echo "$size"
    fi
}

# Get repository quota in bytes
# Returns:
#   0 - Success (quota value echoed to stdout)
#   2 - Lock contention failure
get_quota() {
    local repo_path=$1
    local raw_quota
    
    raw_quota=$(execute_borg_config "$repo_path" "storage_quota")
    local exit_code=$?
    
    # Propagate lock failure
    if [ $exit_code -eq 2 ]; then
        return 2
    fi
    
    if [ -z "$raw_quota" ]; then
        echo 0
        return 0
    fi
    
    to_bytes "$raw_quota"
    return 0
}

# Get repository space used in bytes
get_space_used() {
    local repo_path=$1
    verbose_exec docker exec "$CONTAINER_NAME" bash -c "du -sb $repo_path"
}

# Convert bytes to human-readable GB (integer)
to_human_gb() {
    local bytes=$1
    echo $(( (bytes + BYTES_PER_G - 1) / BYTES_PER_G ))
}

# Convert bytes to human-readable format with 2 decimal places (e.g., "23.16 GB")
to_human_readable() {
    local bytes=$1
    if [ "$bytes" -eq 0 ] 2>/dev/null; then
        echo "0.00 GB"
        return
    fi
    local gb
    gb=$(echo "scale=2; $bytes / $BYTES_PER_G" | bc 2>/dev/null || printf "%.2f" "$(echo "scale=2; $bytes / $BYTES_PER_G" | bc -l 2>/dev/null)")
    echo "${gb} GB"
}

# Analyze a single repository for dry-run mode
# Reports what action would be taken without making changes
analyze_repo() {
    local repo=$1
    local repo_path="$REPO_DIR/$repo"
    
    log "Analyzing repository: $repo"
    
    # Get quota and space used
    local quota_raw
    quota_raw=$(execute_borg_config "$repo_path" "storage_quota" 2>/dev/null || echo "")
    
    # Check for lock failure
    if [ $? -eq 2 ]; then
        log "  Repository is locked, cannot analyze"
        return
    fi
    
    local quota_bytes
    quota_bytes=$(to_bytes "$quota_raw")
    
    local space_used
    space_used=$(get_space_used "$repo_path" | awk '{print $1}')
    
    local quota_human used_human
    quota_human=$(to_human_readable "$quota_bytes")
    used_human=$(to_human_readable "$space_used")
    
    log "  Quota: ${quota_raw:-0} (${quota_human})"
    log "  Used: ${used_human}"
    
    # Determine action
    if [ "$quota_bytes" -eq 0 ]; then
        log "  Action: Would compact with unlimited quota"
    elif [ "$space_used" -gt "$quota_bytes" ]; then
        local extra_bytes=$((EXTRA_QUOTA_G * BYTES_PER_G))
        local new_quota_bytes=$((space_used + extra_bytes))
        local new_quota_gb
        new_quota_gb=$(to_human_gb "$new_quota_bytes")
        log "  Action: Would temporarily increase quota to ${new_quota_gb}G, compact, then restore to ${quota_raw}"
    else
        log "  Action: Would compact with existing quota"
    fi
}

# Compact a single repository with quota management and retry logic
compact_repo() {
    local repo=$1
    local repo_path="$REPO_DIR/$repo"
    local repo_success=true
    local original_quota_str=""
    
    log "Processing repository: $repo"
    
    # Step 1: Get quota with retry
    log_verbose "Getting quota..."
    local quota_raw
    quota_raw=$(execute_borg_config "$repo_path" "storage_quota")
    local exit_code=$?
    
    # Check for lock failure on quota retrieval
    if [ $exit_code -eq 2 ]; then
        log "Repository $repo is locked (cannot read quota), skipping..."
        healthcheck "down" "${repo}-locked"
        return 0
    fi
    
    # Check for other failures on quota retrieval
    if [ $exit_code -ne 0 ] || [ -z "$quota_raw" ]; then
        log "ERROR: Failed to get quota for $repo" >&2
        healthcheck "down" "${repo}-locked"
        return 1
    fi
    
    original_quota_str="$quota_raw"
    
    local quota_bytes
    quota_bytes=$(to_bytes "$quota_raw")
    
    log_verbose "Getting space used..."
    local space_used
    space_used=$(get_space_used "$repo_path" | awk '{print $1}')
    
    local quota_human used_human
    quota_human=$(to_human_readable "$quota_bytes")
    used_human=$(to_human_readable "$space_used")
    log "Quota: ${quota_raw:-0} (${quota_human}), Used: ${used_human}"
    
    if [ "$quota_bytes" -eq 0 ]; then
        log "Quota is unlimited, compacting without adjustment..."
        log_verbose "Running borg compact..."
        if ! execute_borg_compact "$repo_path"; then
            exit_code=$?
            if [ $exit_code -eq 2 ]; then
                log "Repository $repo is locked during compact, skipping..."
                healthcheck "down" "${repo}-locked"
                return 0
            else
                log "ERROR: Compact failed for $repo" >&2
                repo_success=false
            fi
        fi
        
        if [ "$repo_success" = true ]; then
            log "Repository $repo: SUCCESS"
            healthcheck "up" "$repo"
            return 0
        else
            log "Repository $repo: FAILED" >&2
            healthcheck "down" "$repo"
            return 1
        fi
    fi
    
    if [ "$space_used" -gt "$quota_bytes" ]; then
        log "Space used (${space_used}) > quota (${quota_bytes}), adjusting quota..."
        
        local extra_bytes=$((EXTRA_QUOTA_G * BYTES_PER_G))
        local new_quota_bytes=$((space_used + extra_bytes))
        local new_quota_gb
        new_quota_gb=$(to_human_gb "$new_quota_bytes")
        local new_quota_str="${new_quota_gb}G"
        
        log "Temporarily increasing quota from ${quota_raw} to ${new_quota_str}"
        
        # Step 2: Set new quota with retry
        log_verbose "Setting new quota..."
        if ! execute_borg_config "$repo_path" "storage_quota" "$new_quota_str" > /dev/null; then
            exit_code=$?
            if [ $exit_code -eq 2 ]; then
                log "Repository $repo is locked during quota update, skipping..."
                healthcheck "down" "${repo}-locked"
                return 0
            else
                log "ERROR: Failed to set new quota for $repo" >&2
                repo_success=false
            fi
        fi
        
        # Step 3: Compact with retry
        log_verbose "Running borg compact..."
        if ! execute_borg_compact "$repo_path"; then
            exit_code=$?
            if [ $exit_code -eq 2 ]; then
                log "Repository $repo is locked during compact, skipping..."
                # Try to restore quota before skipping
                if [ -n "$original_quota_str" ]; then
                    log_verbose "Restoring original quota before skipping..."
                    execute_borg_config "$repo_path" "storage_quota" "$original_quota_str" > /dev/null 2>&1 || true
                fi
                healthcheck "down" "${repo}-locked"
                return 0
            else
                log "ERROR: Compact failed for $repo" >&2
                repo_success=false
            fi
        fi
        
        # Step 4: Restore original quota with retry
        log_verbose "Restoring original quota..."
        if [ -n "$original_quota_str" ]; then
            if ! execute_borg_config "$repo_path" "storage_quota" "$original_quota_str" > /dev/null; then
                exit_code=$?
                if [ $exit_code -eq 2 ]; then
                    log "Repository $repo is locked during quota restoration, skipping..."
                    healthcheck "down" "${repo}-locked"
                    return 0
                else
                    log "ERROR: Failed to restore original quota for $repo" >&2
                    repo_success=false
                fi
            fi
        fi
    else
        log "Space used (${used_human}) <= quota (${quota_human}), compacting..."
        
        # Step 5: Compact with retry
        log_verbose "Running borg compact..."
        if ! execute_borg_compact "$repo_path"; then
            exit_code=$?
            if [ $exit_code -eq 2 ]; then
                log "Repository $repo is locked during compact, skipping..."
                healthcheck "down" "${repo}-locked"
                return 0
            else
                log "ERROR: Compact failed for $repo" >&2
                repo_success=false
            fi
        fi
    fi
    
    if [ "$repo_success" = true ]; then
        log "Repository $repo: SUCCESS"
        healthcheck "up" "$repo"
        return 0
    else
        log "Repository $repo: FAILED" >&2
        healthcheck "down" "$repo"
        return 1
    fi
}

# Process all repositories (normal mode)
process_all_repos() {
    local failed_repos=0
    local repos
    
    log "Listing repositories in $REPO_DIR..."
    
    repos=$(verbose_exec docker exec "$CONTAINER_NAME" bash -c "ls -1 $REPO_DIR" 2>/dev/null | grep -v '^$' || echo "")
    
    if [ -z "$repos" ]; then
        log "No repositories found in $REPO_DIR"
        return 0
    fi
    
    log "Found repositories:"
    while IFS= read -r repo; do
        if [ -n "$repo" ]; then
            log "  - $repo"
        fi
    done <<< "$repos"
    
    for repo in $repos; do
        if [ -z "$repo" ]; then
            continue
        fi
        
        if [ "$VERBOSE" = true ]; then
            echo "---"
        fi
        if ! compact_repo "$repo"; then
            failed_repos=$((failed_repos + 1))
        fi
        if [ "$VERBOSE" = true ]; then
            echo "---"
        fi
    done
    
    log "Processed all repositories. Failures: $failed_repos"
    
    if [ "$failed_repos" -gt 0 ]; then
        return 1
    fi
    
    return 0
}

# Process all repositories (dry-run mode)
process_all_repos_dryrun() {
    local repos
    
    log "[DRY-RUN MODE] Listing repositories in $REPO_DIR..."
    
    repos=$(verbose_exec docker exec "$CONTAINER_NAME" bash -c "ls -1 $REPO_DIR" 2>/dev/null | grep -v '^$' || echo "")
    
    if [ -z "$repos" ]; then
        log "[DRY-RUN MODE] No repositories found in $REPO_DIR"
        return 0
    fi
    
    log "[DRY-RUN MODE] Found repositories:"
    while IFS= read -r repo; do
        if [ -n "$repo" ]; then
            log "  - $repo"
        fi
    done <<< "$repos"
    log "[DRY-RUN MODE] ============================================"
    
    for repo in $repos; do
        if [ -z "$repo" ]; then
            continue
        fi
        
        analyze_repo "$repo"
        
        if [ "$VERBOSE" = true ]; then
            echo "---"
        fi
    done
    
    log "[DRY-RUN MODE] ============================================"
    log "[DRY-RUN MODE] Dry-run complete. No changes were made."
    return 0
}

# ------------------------------------------------------------------
# MAIN ENTRY POINT
# ------------------------------------------------------------------

main() {
    # Initialize
    DRY_RUN=false
    
    # Parse command-line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run|-n)
                DRY_RUN=true
                shift
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                echo "Usage: $0 [--dry-run|-n]" >&2
                exit 1
                ;;
        esac
    done
    
    log "============================================"
    log "Borg Repository Compaction Script Started"
    if [ "$DRY_RUN" = true ]; then
        log "[DRY-RUN MODE] NO CHANGES WILL BE MADE"
    fi
    log "============================================"
    
    # Validate required environment variables
    if [ -z "$UPTIMEKUMA_DOMAIN" ] || [ -z "$HEALTHCHECK_ID" ]; then
        echo "ERROR: UPTIMEKUMA_DOMAIN and HEALTHCHECK_ID must be set" >&2
        exit 1
    fi
    
    log "Configuration:"
    log "  UptimeKuma Domain: $UPTIMEKUMA_DOMAIN"
    log "  Healthcheck ID: $HEALTHCHECK_ID"
    log "  Container: $CONTAINER_NAME"
    log "  Repo Directory: $REPO_DIR"
    log "  Extra Quota: ${EXTRA_QUOTA_G}G"
    log "  Verbose Mode: $VERBOSE"
    log "  Dry-Run Mode: $DRY_RUN"
    log "  Retry Interval: ${RETRY_INTERVAL_SECONDS} seconds"
    log "  Max Retry Attempts: $RETRY_MAX_ATTEMPTS"
    
    if [ "$DRY_RUN" = false ]; then
        # Normal mode: send healthchecks and process repos
        log "Sending start healthcheck..."
        healthcheck "up" "OK"
        
        log "Starting repository processing..."
        if [ "$VERBOSE" = true ]; then
            echo ""
        fi
        
        if process_all_repos; then
            if [ "$VERBOSE" = true ]; then
                echo ""
            fi
            log "All repositories processed successfully"
            log "Sending finish healthcheck..."
            healthcheck "up" "finish"
            log "Script completed successfully"
            exit 0
        else
            if [ "$VERBOSE" = true ]; then
                echo ""
            fi
            log "One or more repositories failed" >&2
            log "Sending fail healthcheck..."
            healthcheck "down" "fail"
            log "Script completed with errors" >&2
            exit 1
        fi
    else
        # Dry-run mode: no healthchecks, just analyze
        if [ "$VERBOSE" = true ]; then
            echo ""
        fi
        
        if ! process_all_repos_dryrun; then
            log "Dry-run failed" >&2
            exit 1
        fi
        
        exit 0
    fi
}

main "$@"
