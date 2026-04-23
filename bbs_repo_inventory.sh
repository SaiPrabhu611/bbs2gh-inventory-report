#!/bin/bash

#===============================================================================
# BBS (Bitbucket Server) Repository Inventory Generator
# 
# This script fetches repository details and sizes from Bitbucket Server API
# with support for batch processing, pagination, and error resilience.
#
# Usage: ./bbs_repo_inventory.sh -f <projects.csv> -s <start> -e <end> [options]
#
# Author: Migration Team
# Date: April 2026
#===============================================================================

set -o pipefail

#-------------------------------------------------------------------------------
# Configuration & Defaults
#-------------------------------------------------------------------------------
readonly SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
readonly TIMESTAMP=$(date +%Y%m%d_%H%M%S)
readonly DEFAULT_PAGE_LIMIT=100
readonly DEFAULT_PARALLEL_JOBS=5
readonly DEFAULT_PARALLEL_THRESHOLD=10   # projects with > this many repos run in parallel
readonly DEFAULT_RETRY_COUNT=3
readonly DEFAULT_RETRY_DELAY=5
readonly DEFAULT_TIMEOUT=30

# Output directories
OUTPUT_DIR="${SCRIPT_DIR}/output"
LOG_DIR="${SCRIPT_DIR}/logs"
REPORT_DIR="${OUTPUT_DIR}/reports"

# API Configuration
BBS_API_VERSION="1.0"
PAGE_LIMIT=${PAGE_LIMIT:-$DEFAULT_PAGE_LIMIT}
PARALLEL_JOBS=${PARALLEL_JOBS:-$DEFAULT_PARALLEL_JOBS}
PARALLEL_THRESHOLD=${PARALLEL_THRESHOLD:-$DEFAULT_PARALLEL_THRESHOLD}
RETRY_COUNT=${RETRY_COUNT:-$DEFAULT_RETRY_COUNT}
RETRY_DELAY=${RETRY_DELAY:-$DEFAULT_RETRY_DELAY}
API_TIMEOUT=${API_TIMEOUT:-$DEFAULT_TIMEOUT}

# Script variables
PROJECTS_FILE=""
START_INDEX=1
END_INDEX=""
BBS_CREDENTIALS=""   # Expected format: "username:password"
BBS_BASE_URL=""
DRY_RUN=false
VERBOSE=false
RESUME_FILE=""

#-------------------------------------------------------------------------------
# Color codes for output
#-------------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

#-------------------------------------------------------------------------------
# Logging Functions
#-------------------------------------------------------------------------------
LOG_FILE=""

init_logging() {
    mkdir -p "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/bbs_inventory_${TIMESTAMP}.log"
    touch "$LOG_FILE"
    log_info "Logging initialized: $LOG_FILE"
}

log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    if [[ "$VERBOSE" == "true" ]] || [[ "$level" == "ERROR" ]] || [[ "$level" == "WARN" ]]; then
        case "$level" in
            ERROR) echo -e "${RED}[$level]${NC} $message" >&2 ;;
            WARN)  echo -e "${YELLOW}[$level]${NC} $message" >&2 ;;
            INFO)  echo -e "${GREEN}[$level]${NC} $message" ;;
            DEBUG) echo -e "${BLUE}[$level]${NC} $message" ;;
        esac
    fi
}

log_info()  { log_message "INFO" "$1"; }
log_warn()  { log_message "WARN" "$1"; }
log_error() { log_message "ERROR" "$1"; }
log_debug() { [[ "$VERBOSE" == "true" ]] && log_message "DEBUG" "$1"; }

#-------------------------------------------------------------------------------
# Usage & Help
#-------------------------------------------------------------------------------
usage() {
    cat << EOF
${SCRIPT_NAME} - Bitbucket Server Repository Inventory Generator

USAGE:
    ${SCRIPT_NAME} -f <projects.csv> -s <start> -e <end> [OPTIONS]

REQUIRED ARGUMENTS:
    -f, --file <path>       Path to projects CSV file
    -s, --start <num>       Start index (1-based) for batch processing
    -e, --end <num>         End index for batch processing

AUTHENTICATION (Basic auth only):
    -u, --user <user:pass>  Username and password in "user:password" format

    Environment variables can also be used:
        BBS_USER            Username
        BBS_PASSWORD        Password

OPTIONS:
    -b, --base-url <url>    Override base URL from CSV (optional)
    -o, --output <dir>      Output directory (default: ./output)
    -l, --limit <num>       Page limit for API calls (default: 100)
    -p, --parallel <num>    Concurrency level when parallel mode kicks in (default: 5)
    --parallel-threshold <n> Switch a project to parallel mode when it has more
                            than <n> repositories (default: 10). Use 0 to force
                            parallel always; use a very large number to force
                            sequential always.
    -r, --retry <num>       Number of retries for failed API calls (default: 3)
    --resume <file>         Resume from a previous progress file
    --dry-run               Validate inputs without making API calls
    -v, --verbose           Enable verbose output
    -h, --help              Show this help message

EXAMPLES:
    # Process projects 1-20 with basic auth
    ${SCRIPT_NAME} -f projects.csv -s 1 -e 20 -u "s5642784:mypass"

    # Using environment variables for credentials
    export BBS_USER="s5642784"
    export BBS_PASSWORD="mypass"
    ${SCRIPT_NAME} -f projects.csv -s 21 -e 50 -v

    # Resume from previous run
    ${SCRIPT_NAME} -f projects.csv -s 1 -e 100 -u "user:pass" --resume progress.json

    # Dry run to validate setup
    ${SCRIPT_NAME} -f projects.csv -s 1 -e 5 -u "user:pass" --dry-run

CSV FORMAT:
    The input CSV should have the following columns (tab or comma separated):
    project-key, project-name, url, repo-count, pr-count

OUTPUT:
    The script generates:
    - repo_inventory_<timestamp>.csv   : Main report with repo details and sizes
    - progress_<timestamp>.json        : Progress file for resume capability
    - bbs_inventory_<timestamp>.log    : Detailed execution log
    - errors_<timestamp>.csv           : Failed API calls for retry

EOF
    exit 0
}

#-------------------------------------------------------------------------------
# Argument Parsing
#-------------------------------------------------------------------------------
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--file)
                PROJECTS_FILE="$2"
                shift 2
                ;;
            -s|--start)
                START_INDEX="$2"
                shift 2
                ;;
            -e|--end)
                END_INDEX="$2"
                shift 2
                ;;
            -u|--user)
                BBS_CREDENTIALS="$2"
                shift 2
                ;;
            -b|--base-url)
                BBS_BASE_URL="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_DIR="$2"
                REPORT_DIR="${OUTPUT_DIR}/reports"
                shift 2
                ;;
            -l|--limit)
                PAGE_LIMIT="$2"
                shift 2
                ;;
            -p|--parallel)
                PARALLEL_JOBS="$2"
                shift 2
                ;;
            --parallel-threshold)
                PARALLEL_THRESHOLD="$2"
                shift 2
                ;;
            -r|--retry)
                RETRY_COUNT="$2"
                shift 2
                ;;
            --resume)
                RESUME_FILE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                echo "Unknown option: $1" >&2
                echo "Use -h or --help for usage information" >&2
                exit 1
                ;;
        esac
    done
}

#-------------------------------------------------------------------------------
# Validation Functions
#-------------------------------------------------------------------------------
validate_inputs() {
    local errors=0

    # Check required arguments
    if [[ -z "$PROJECTS_FILE" ]]; then
        log_error "Projects file is required (-f/--file)"
        ((errors++))
    elif [[ ! -f "$PROJECTS_FILE" ]]; then
        log_error "Projects file not found: $PROJECTS_FILE"
        ((errors++))
    fi

    if [[ -z "$START_INDEX" ]] || ! [[ "$START_INDEX" =~ ^[0-9]+$ ]]; then
        log_error "Valid start index is required (-s/--start)"
        ((errors++))
    fi

    if [[ -z "$END_INDEX" ]] || ! [[ "$END_INDEX" =~ ^[0-9]+$ ]]; then
        log_error "Valid end index is required (-e/--end)"
        ((errors++))
    fi

    if [[ "$START_INDEX" -gt "$END_INDEX" ]]; then
        log_error "Start index ($START_INDEX) cannot be greater than end index ($END_INDEX)"
        ((errors++))
    fi

    # Check authentication (Basic auth only)
    if [[ -z "$BBS_CREDENTIALS" ]]; then
        if [[ -n "${BBS_USER:-}" ]] && [[ -n "${BBS_PASSWORD:-}" ]]; then
            BBS_CREDENTIALS="${BBS_USER}:${BBS_PASSWORD}"
        else
            log_error "Authentication required. Use -u/--user <user:pass> or set BBS_USER and BBS_PASSWORD environment variables"
            ((errors++))
        fi
    fi

    # Validate credentials format (must contain a colon separating user and password)
    if [[ -n "$BBS_CREDENTIALS" ]] && [[ "$BBS_CREDENTIALS" != *:* ]]; then
        log_error "Credentials must be in 'username:password' format"
        ((errors++))
    fi

    # Validate numeric parameters
    if ! [[ "$PAGE_LIMIT" =~ ^[0-9]+$ ]] || [[ "$PAGE_LIMIT" -lt 1 ]] || [[ "$PAGE_LIMIT" -gt 1000 ]]; then
        log_error "Page limit must be between 1 and 1000"
        ((errors++))
    fi

    if ! [[ "$PARALLEL_JOBS" =~ ^[0-9]+$ ]] || [[ "$PARALLEL_JOBS" -lt 1 ]] || [[ "$PARALLEL_JOBS" -gt 20 ]]; then
        log_error "Parallel jobs must be between 1 and 20"
        ((errors++))
    fi

    if ! [[ "$PARALLEL_THRESHOLD" =~ ^[0-9]+$ ]]; then
        log_error "Parallel threshold must be a non-negative integer"
        ((errors++))
    fi

    # Check dependencies
    for cmd in curl jq; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Required command not found: $cmd"
            ((errors++))
        fi
    done

    if [[ $errors -gt 0 ]]; then
        log_error "Validation failed with $errors error(s). Exiting."
        exit 1
    fi

    log_info "Input validation passed"
}

#-------------------------------------------------------------------------------
# Directory Setup
#-------------------------------------------------------------------------------
setup_directories() {
    mkdir -p "$OUTPUT_DIR" "$LOG_DIR" "$REPORT_DIR"
    log_info "Output directories created: $OUTPUT_DIR"
}

#-------------------------------------------------------------------------------
# CSV Parsing Functions
#-------------------------------------------------------------------------------
detect_delimiter() {
    local file="$1"
    local first_line=$(head -1 "$file")
    
    if [[ "$first_line" == *$'\t'* ]]; then
        echo $'\t'
    elif [[ "$first_line" == *","* ]]; then
        echo ","
    else
        echo $'\t'  # Default to tab
    fi
}

parse_projects_csv() {
    local file="$1"
    local start="$2"
    local end="$3"
    local delimiter=$(detect_delimiter "$file")
    
    # Skip header and extract rows within range
    local total_lines=$(tail -n +2 "$file" | wc -l)
    
    if [[ "$end" -gt "$total_lines" ]]; then
        log_warn "End index ($end) exceeds total projects ($total_lines). Adjusting to $total_lines"
        end=$total_lines
    fi
    
    log_info "Processing projects $start to $end (total available: $total_lines)"
    
    # Use awk to extract specific line range
    tail -n +2 "$file" | awk -v start="$start" -v end="$end" 'NR >= start && NR <= end'
}

#-------------------------------------------------------------------------------
# API Functions
#-------------------------------------------------------------------------------
get_auth_header() {
    # Kept for backward compatibility; credentials are now passed to curl via -u.
    # Returns empty so callers passing this as a header are effectively no-ops.
    echo ""
}

extract_base_url() {
    local url="$1"
    # Extract base URL from project URL (e.g., https://bitbucket.agile.bns/projects/GHBBMIG -> https://bitbucket.agile.bns)
    echo "$url" | sed -E 's|(https?://[^/]+).*|\1|'
}

api_call_with_retry() {
    local url="$1"
    local context="$2"
    local attempt=1
    local response=""
    local http_code=""
    
    while [[ $attempt -le $RETRY_COUNT ]]; do
        log_debug "API call attempt $attempt/$RETRY_COUNT: $url"
        
        # Make API call with timeout (Basic auth via -u, matching customer's working pattern)
        local tmp_file=$(mktemp)
        http_code=$(curl -s -w "%{http_code}" \
            -u "$BBS_CREDENTIALS" \
            -H "Accept: application/json" \
            --connect-timeout "$API_TIMEOUT" \
            --max-time $((API_TIMEOUT * 2)) \
            -o "$tmp_file" \
            "$url" 2>/dev/null)
        
        response=$(cat "$tmp_file")
        rm -f "$tmp_file"
        
        if [[ "$http_code" == "200" ]]; then
            echo "$response"
            return 0
        elif [[ "$http_code" == "429" ]]; then
            # Rate limited - wait longer
            log_warn "Rate limited. Waiting 60 seconds before retry..."
            sleep 60
        elif [[ "$http_code" =~ ^5[0-9]{2}$ ]]; then
            # Server error - retry
            log_warn "Server error ($http_code). Retrying in $RETRY_DELAY seconds..."
            sleep "$RETRY_DELAY"
        else
            # Client error or other - log and fail
            log_error "API call failed for $context: HTTP $http_code - $url"
            echo ""
            return 1
        fi
        
        ((attempt++))
    done
    
    log_error "API call failed after $RETRY_COUNT attempts for $context: $url"
    echo ""
    return 1
}

fetch_repos_for_project() {
    local project_key="$1"
    local base_url="$2"
    local all_repos="[]"
    local start=0
    local is_last_page=false
    
    log_info "Fetching repositories for project: $project_key"
    
    while [[ "$is_last_page" == "false" ]]; do
        local api_url="${base_url}/rest/api/${BBS_API_VERSION}/projects/${project_key}/repos?start=${start}&limit=${PAGE_LIMIT}"
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would call: $api_url"
            break
        fi
        
        local response=$(api_call_with_retry "$api_url" "repos for $project_key")
        
        if [[ -z "$response" ]]; then
            log_error "Failed to fetch repos for project $project_key at start=$start"
            return 1
        fi
        
        # Parse response
        local repos=$(echo "$response" | jq -c '.values // []')
        local next_page_start=$(echo "$response" | jq -r '.nextPageStart // "null"')
        is_last_page=$(echo "$response" | jq -r '.isLastPage // true')
        
        # Merge repos
        all_repos=$(echo "$all_repos $repos" | jq -s 'add')
        
        local repo_count=$(echo "$repos" | jq 'length')
        log_debug "Fetched $repo_count repos for $project_key (page start: $start)"
        
        if [[ "$next_page_start" != "null" ]] && [[ "$is_last_page" == "false" ]]; then
            start=$next_page_start
        else
            break
        fi
    done
    
    echo "$all_repos"
}

fetch_repo_size() {
    local project_key="$1"
    local repo_slug="$2"
    local base_url="$3"
    
    #local api_url="${base_url}/rest/api/${BBS_API_VERSION}/projects/${project_key}/repos/${repo_slug}/sizes"
    local api_url="${base_url}/projects/${project_key}/repos/${repo_slug}/sizes"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_debug "[DRY RUN] Would call: $api_url"
        echo '{"repository": 0, "attachments": 0}'
        return 0
    fi
    
    local response=$(api_call_with_retry "$api_url" "size for $project_key/$repo_slug")
    
    if [[ -z "$response" ]]; then
        # Return default values on error but don't fail
        echo '{"repository": -1, "attachments": -1}'
        return 0
    fi
    
    echo "$response"
}

#-------------------------------------------------------------------------------
# Fetch the most recent commit date on the default branch.
# Returns a string like "2026-01-13 10:02 AM", or empty if unavailable
# (e.g. empty repo, missing default branch, API failure).
#-------------------------------------------------------------------------------
fetch_last_commit_date() {
    local project_key="$1"
    local repo_slug="$2"
    local base_url="$3"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo ""
        return 0
    fi

    local api_url="${base_url}/rest/api/${BBS_API_VERSION}/projects/${project_key}/repos/${repo_slug}/commits?limit=1"
    local response
    response=$(api_call_with_retry "$api_url" "last commit for $project_key/$repo_slug")

    if [[ -z "$response" ]]; then
        echo ""
        return 0
    fi

    local ts_ms
    ts_ms=$(echo "$response" | jq -r '.values[0].authorTimestamp // empty')
    if [[ -z "$ts_ms" ]] || ! [[ "$ts_ms" =~ ^[0-9]+$ ]]; then
        echo ""
        return 0
    fi

    local ts_sec=$((ts_ms / 1000))
    # Try GNU date first, then BSD date as fallback
    date -d "@${ts_sec}" '+%Y-%m-%d %I:%M %p' 2>/dev/null \
        || date -r "${ts_sec}" '+%Y-%m-%d %I:%M %p' 2>/dev/null \
        || echo ""
}

#-------------------------------------------------------------------------------
# Fetch total pull-request count (all states) for a repo.
# Returns an integer (0 on error or none).
#-------------------------------------------------------------------------------
fetch_pr_count() {
    local project_key="$1"
    local repo_slug="$2"
    local base_url="$3"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "0"
        return 0
    fi

    local total=0
    local start=0
    local page_size=1000   # large page to minimize round-trips
    local is_last_page="false"

    while [[ "$is_last_page" == "false" ]]; do
        local api_url="${base_url}/rest/api/${BBS_API_VERSION}/projects/${project_key}/repos/${repo_slug}/pull-requests?state=ALL&start=${start}&limit=${page_size}"
        local response
        response=$(api_call_with_retry "$api_url" "PR count for $project_key/$repo_slug")

        if [[ -z "$response" ]]; then
            echo "$total"
            return 0
        fi

        local size
        size=$(echo "$response" | jq -r '.size // 0')
        total=$((total + size))

        is_last_page=$(echo "$response" | jq -r '.isLastPage // true')
        local next
        next=$(echo "$response" | jq -r '.nextPageStart // "null"')

        if [[ "$is_last_page" == "true" ]] || [[ "$next" == "null" ]]; then
            break
        fi
        start="$next"
    done

    echo "$total"
}

#-------------------------------------------------------------------------------
# Progress Tracking
#-------------------------------------------------------------------------------
PROGRESS_FILE=""
PROCESSED_PROJECTS=()
FAILED_PROJECTS=()

init_progress() {
    PROGRESS_FILE="${OUTPUT_DIR}/progress_${TIMESTAMP}.json"
    
    if [[ -n "$RESUME_FILE" ]] && [[ -f "$RESUME_FILE" ]]; then
        log_info "Resuming from progress file: $RESUME_FILE"
        # Load processed projects from resume file
        PROCESSED_PROJECTS=($(jq -r '.processed_projects[]' "$RESUME_FILE" 2>/dev/null))
        log_info "Loaded ${#PROCESSED_PROJECTS[@]} previously processed projects"
    fi
    
    # Initialize progress file
    echo '{"start_time": "'$(date -Iseconds)'", "processed_projects": [], "failed_projects": [], "status": "running"}' > "$PROGRESS_FILE"
}

update_progress() {
    local project_key="$1"
    local status="$2"
    
    if [[ "$status" == "success" ]]; then
        PROCESSED_PROJECTS+=("$project_key")
    else
        FAILED_PROJECTS+=("$project_key")
    fi
    
    # Update progress file
    jq --arg pk "$project_key" --arg status "$status" \
        '.processed_projects += [$pk] | .last_project = $pk | .last_update = (now | todate)' \
        "$PROGRESS_FILE" > "${PROGRESS_FILE}.tmp" && mv "${PROGRESS_FILE}.tmp" "$PROGRESS_FILE"
}

is_project_processed() {
    local project_key="$1"
    for processed in "${PROCESSED_PROJECTS[@]}"; do
        if [[ "$processed" == "$project_key" ]]; then
            return 0
        fi
    done
    return 1
}

#-------------------------------------------------------------------------------
# Report Generation
#-------------------------------------------------------------------------------
REPORT_FILE=""
ERRORS_FILE=""

init_reports() {
    REPORT_FILE="${REPORT_DIR}/repo_inventory_${TIMESTAMP}.csv"
    ERRORS_FILE="${REPORT_DIR}/errors_${TIMESTAMP}.csv"
    
    # Write headers (customer-requested schema)
    echo "project-key,project-name,repo,url,last-commit-date,repo-size-in-bytes,attachments-size-in-bytes,is-archived,pr-count" > "$REPORT_FILE"
    echo "project_key,repo_slug,error_type,error_message,timestamp" > "$ERRORS_FILE"
    
    log_info "Report file initialized: $REPORT_FILE"
}

write_repo_entry() {
    local project_key="$1"
    local project_name="$2"
    local repo_json="$3"
    local size_json="$4"
    local last_commit_date="$5"
    local pr_count="$6"
    local base_url="$7"

    # Extract repo details
    local repo_slug
    repo_slug=$(echo "$repo_json" | jq -r '.slug // "unknown"')

    # is-archived: BBS exposes .archived as bool (BBS 8+); default to false otherwise.
    local archived_raw
    archived_raw=$(echo "$repo_json" | jq -r '.archived // false')
    local archived="False"
    [[ "$archived_raw" == "true" ]] && archived="True"

    # Sizes (use 0 if /sizes failed)
    local repo_size
    repo_size=$(echo "$size_json" | jq -r '.repository // 0')
    [[ "$repo_size" == "-1" ]] && repo_size=0
    local attachments_size
    attachments_size=$(echo "$size_json" | jq -r '.attachments // 0')
    [[ "$attachments_size" == "-1" ]] && attachments_size=0

    # Browse URL (matches customer-requested format: <base>/projects/<KEY>/repos/<SLUG>)
    local repo_url="${base_url}/projects/${project_key}/repos/${repo_slug}"

    # PR count fallback
    [[ -z "$pr_count" ]] && pr_count=0

    # Escape commas/quotes in free-text fields
    project_name=$(echo "$project_name" | sed 's/,/;/g' | sed 's/"/""/g')

    # Order: project-key, project-name, repo, url, last-commit-date,
    #        repo-size-in-bytes, attachments-size-in-bytes, is-archived, pr-count
    echo "\"$project_key\",\"$project_name\",\"$repo_slug\",\"$repo_url\",\"$last_commit_date\",\"$repo_size\",\"$attachments_size\",\"$archived\",$pr_count" >> "$REPORT_FILE"
}

write_error_entry() {
    local project_key="$1"
    local repo_slug="$2"
    local error_type="$3"
    local error_message="$4"
    
    local timestamp=$(date -Iseconds)
    error_message=$(echo "$error_message" | sed 's/,/;/g' | sed 's/"/""/g')
    
    echo "\"$project_key\",\"$repo_slug\",\"$error_type\",\"$error_message\",\"$timestamp\"" >> "$ERRORS_FILE"
}

#-------------------------------------------------------------------------------
# Main Processing Functions
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# Single-repo worker: fetches size, writes report row and (if needed) error row.
# Designed to be safe to call from a background subshell — only appends to
# files (atomic for small lines under POSIX O_APPEND) and never mutates shared
# in-memory state.
#-------------------------------------------------------------------------------
process_single_repo() {
    local project_key="$1"
    local project_name="$2"
    local repo_json="$3"
    local base_url="$4"

    local repo_slug
    repo_slug=$(echo "$repo_json" | jq -r '.slug')

    log_debug "Processing repo: $project_key/$repo_slug"

    # 1. Repo size + attachments
    local size
    size=$(fetch_repo_size "$project_key" "$repo_slug" "$base_url")
    if [[ $(echo "$size" | jq -r '.repository') == "-1" ]]; then
        write_error_entry "$project_key" "$repo_slug" "FETCH_SIZE" "Failed to fetch repository size"
    fi

    # 2. Last commit date on default branch (empty if repo has no commits)
    local last_commit_date
    last_commit_date=$(fetch_last_commit_date "$project_key" "$repo_slug" "$base_url")

    # 3. Total PR count (all states)
    local pr_count
    pr_count=$(fetch_pr_count "$project_key" "$repo_slug" "$base_url")

    write_repo_entry "$project_key" "$project_name" "$repo_json" "$size" \
        "$last_commit_date" "$pr_count" "$base_url"
}

process_project() {
    local project_key="$1"
    local project_name="$2"
    local project_url="$3"

    # Check if already processed (for resume)
    if is_project_processed "$project_key"; then
        log_info "Skipping already processed project: $project_key"
        return 0
    fi

    # Determine base URL
    local base_url="${BBS_BASE_URL:-$(extract_base_url "$project_url")}"

    log_info "Processing project: $project_key ($project_name)"

    # Fetch all repos for the project
    local repos
    repos=$(fetch_repos_for_project "$project_key" "$base_url")

    if [[ -z "$repos" ]] || [[ "$repos" == "[]" ]]; then
        log_warn "No repositories found or failed to fetch for project: $project_key"
        write_error_entry "$project_key" "" "FETCH_REPOS" "No repositories found or API call failed"
        update_progress "$project_key" "failed"
        return 1
    fi

    local repo_count
    repo_count=$(echo "$repos" | jq 'length')
    log_info "Found $repo_count repositories in project $project_key"

    # Decide mode based on threshold
    if [[ "$repo_count" -gt "$PARALLEL_THRESHOLD" ]]; then
        log_info "Parallel mode for $project_key: $repo_count repos > threshold $PARALLEL_THRESHOLD (concurrency=$PARALLEL_JOBS)"
        _process_repos_parallel "$project_key" "$project_name" "$base_url" "$repos"
    else
        log_info "Sequential mode for $project_key: $repo_count repos <= threshold $PARALLEL_THRESHOLD"
        _process_repos_sequential "$project_key" "$project_name" "$base_url" "$repos"
    fi

    update_progress "$project_key" "success"
    log_info "Completed project $project_key"

    return 0
}

_process_repos_sequential() {
    local project_key="$1"
    local project_name="$2"
    local base_url="$3"
    local repos="$4"

    # Process substitution avoids the subshell-counter trap of `cmd | while`.
    while read -r repo; do
        process_single_repo "$project_key" "$project_name" "$repo" "$base_url"
        sleep 0.1   # gentle pacing in sequential mode
    done < <(echo "$repos" | jq -c '.[]')
}

_process_repos_parallel() {
    local project_key="$1"
    local project_name="$2"
    local base_url="$3"
    local repos="$4"

    while read -r repo; do
        # Throttle: don't exceed PARALLEL_JOBS background workers at once.
        while [[ $(jobs -rp | wc -l) -ge "$PARALLEL_JOBS" ]]; do
            sleep 0.05
        done

        process_single_repo "$project_key" "$project_name" "$repo" "$base_url" &
    done < <(echo "$repos" | jq -c '.[]')

    # Wait for all background workers spawned in this function to finish
    # before the project is marked complete.
    wait
}

process_batch() {
    local delimiter=$(detect_delimiter "$PROJECTS_FILE")
    local projects_data=$(parse_projects_csv "$PROJECTS_FILE" "$START_INDEX" "$END_INDEX")
    
    if [[ -z "$projects_data" ]]; then
        log_error "No projects found in the specified range"
        exit 1
    fi
    
    local total_projects=$(echo "$projects_data" | wc -l)
    log_info "Starting batch processing of $total_projects projects"
    
    local current=0
    local success=0
    local failed=0
    
    # Process projects
    while IFS="$delimiter" read -r project_key project_name project_url repo_count pr_count; do
        ((current++))
        
        # Clean up values (remove leading/trailing whitespace)
        project_key=$(echo "$project_key" | xargs)
        project_name=$(echo "$project_name" | xargs)
        project_url=$(echo "$project_url" | xargs)
        
        if [[ -z "$project_key" ]]; then
            log_warn "Skipping empty project key at line $current"
            continue
        fi
        
        log_info "[$current/$total_projects] Processing project: $project_key"
        
        if process_project "$project_key" "$project_name" "$project_url"; then
            ((success++))
        else
            ((failed++))
        fi
        
    done <<< "$projects_data"
    
    log_info "Batch processing completed: $success successful, $failed failed out of $total_projects projects"
}

#-------------------------------------------------------------------------------
# Summary Generation
#-------------------------------------------------------------------------------
generate_summary() {
    local total_repos=$(tail -n +2 "$REPORT_FILE" | wc -l)
    # New schema: $6=repo-size-in-bytes, $7=attachments-size-in-bytes (both quoted).
    # Strip quotes via gsub before summing.
    local total_size
    total_size=$(tail -n +2 "$REPORT_FILE" | awk -F',' '{
        gsub(/"/, "", $6); gsub(/"/, "", $7);
        sum += $6 + $7
    } END { print sum+0 }')
    local total_errors=$(tail -n +2 "$ERRORS_FILE" | wc -l)
    
    # Convert to human-readable size
    local size_gb=$(echo "scale=2; ${total_size:-0} / 1073741824" | bc 2>/dev/null || echo "0")
    
    local summary_file="${REPORT_DIR}/summary_${TIMESTAMP}.txt"
    
    cat > "$summary_file" << EOF
=============================================================
BBS Repository Inventory Summary
=============================================================
Generated: $(date)
Batch Range: Projects $START_INDEX to $END_INDEX

STATISTICS:
-----------
Total Projects Processed: ${#PROCESSED_PROJECTS[@]}
Total Repositories Found: $total_repos
Total Size: $size_gb GB
Total Errors: $total_errors

OUTPUT FILES:
-------------
Report: $REPORT_FILE
Errors: $ERRORS_FILE
Progress: $PROGRESS_FILE
Log: $LOG_FILE

PROCESSED PROJECTS:
-------------------
$(printf '%s\n' "${PROCESSED_PROJECTS[@]}")

FAILED PROJECTS:
----------------
$(printf '%s\n' "${FAILED_PROJECTS[@]}")
=============================================================
EOF

    log_info "Summary generated: $summary_file"
    cat "$summary_file"
}

finalize_progress() {
    jq --arg status "completed" \
        --arg end_time "$(date -Iseconds)" \
        '.status = $status | .end_time = $end_time' \
        "$PROGRESS_FILE" > "${PROGRESS_FILE}.tmp" && mv "${PROGRESS_FILE}.tmp" "$PROGRESS_FILE"
}

#-------------------------------------------------------------------------------
# Main Entry Point
#-------------------------------------------------------------------------------
main() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}BBS Repository Inventory Generator${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    parse_arguments "$@"
    
    # Show help if no arguments
    if [[ $# -eq 0 ]]; then
        usage
    fi
    
    setup_directories
    init_logging
    
    log_info "Starting BBS Repository Inventory Generator"
    log_info "Batch range: $START_INDEX to $END_INDEX"
    
    validate_inputs
    init_progress
    init_reports
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Running in DRY RUN mode - no API calls will be made"
    fi
    
    # Process the batch
    process_batch
    
    # Finalize and generate summary
    finalize_progress
    generate_summary
    
    log_info "Script completed successfully"
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Processing Complete!${NC}"
    echo -e "${GREEN}Report: $REPORT_FILE${NC}"
    echo -e "${GREEN}========================================${NC}"
}

# Run main function
main "$@"
