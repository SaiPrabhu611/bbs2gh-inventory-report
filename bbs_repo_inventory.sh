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
RETRY_COUNT=${RETRY_COUNT:-$DEFAULT_RETRY_COUNT}
RETRY_DELAY=${RETRY_DELAY:-$DEFAULT_RETRY_DELAY}
API_TIMEOUT=${API_TIMEOUT:-$DEFAULT_TIMEOUT}

# Script variables
PROJECTS_FILE=""
START_INDEX=1
END_INDEX=""
BBS_PAT=""
BBS_USER=""
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

AUTHENTICATION (one of the following):
    -t, --token <token>     Bitbucket Server personal access token
    -u, --user <user:pass>  Username and password (user:password format)
    
    Environment variables can also be used:
        BBS_PAT           Personal access token
        BBS_USER            Username
        BBS_PASSWORD        Password

OPTIONS:
    -b, --base-url <url>    Override base URL from CSV (optional)
    -o, --output <dir>      Output directory (default: ./output)
    -l, --limit <num>       Page limit for API calls (default: 100)
    -p, --parallel <num>    Number of parallel jobs (default: 5)
    -r, --retry <num>       Number of retries for failed API calls (default: 3)
    --resume <file>         Resume from a previous progress file
    --dry-run               Validate inputs without making API calls
    -v, --verbose           Enable verbose output
    -h, --help              Show this help message

EXAMPLES:
    # Process projects 1-20 with token authentication
    ${SCRIPT_NAME} -f projects.csv -s 1 -e 20 -t "your_token"

    # Process projects 21-50 with verbose output
    ${SCRIPT_NAME} -f projects.csv -s 21 -e 50 -t "your_token" -v

    # Resume from previous run
    ${SCRIPT_NAME} -f projects.csv -s 1 -e 100 -t "your_token" --resume progress.json

    # Dry run to validate setup
    ${SCRIPT_NAME} -f projects.csv -s 1 -e 5 -t "your_token" --dry-run

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
            -t|--token)
                BBS_PAT="$2"
                shift 2
                ;;
            -u|--user)
                BBS_USER="$2"
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

    # Check authentication
    if [[ -z "$BBS_PAT" ]] && [[ -z "$BBS_USER" ]]; then
        # Check environment variables
        if [[ -n "${BBS_PAT:-}" ]]; then
            BBS_PAT="${BBS_PAT}"
        elif [[ -n "${BBS_USER:-}" ]] && [[ -n "${BBS_PASSWORD:-}" ]]; then
            BBS_USER="${BBS_USER}:${BBS_PASSWORD}"
        else
            log_error "Authentication required. Use -t/--token or -u/--user, or set BBS_PAT/BBS_USER/BBS_PASSWORD environment variables"
            ((errors++))
        fi
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
    if [[ -n "$BBS_PAT" ]]; then
        echo "Authorization: Bearer $BBS_PAT"
    elif [[ -n "$BBS_USER" ]]; then
        local encoded=$(echo -n "$BBS_USER" | base64)
        echo "Authorization: Basic $encoded"
    fi
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
        
        # Make API call with timeout
        local tmp_file=$(mktemp)
        http_code=$(curl -s -w "%{http_code}" \
            -H "$(get_auth_header)" \
            -H "Content-Type: application/json" \
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
    
    # Write headers
    echo "project_key,project_name,repo_slug,repo_name,repo_id,clone_url_ssh,clone_url_http,repo_state,repo_size_bytes,attachments_size_bytes,total_size_bytes,total_size_mb,fetch_timestamp" > "$REPORT_FILE"
    echo "project_key,repo_slug,error_type,error_message,timestamp" > "$ERRORS_FILE"
    
    log_info "Report file initialized: $REPORT_FILE"
}

write_repo_entry() {
    local project_key="$1"
    local project_name="$2"
    local repo_json="$3"
    local size_json="$4"
    
    # Extract repo details
    local repo_slug=$(echo "$repo_json" | jq -r '.slug // "unknown"')
    local repo_name=$(echo "$repo_json" | jq -r '.name // "unknown"')
    local repo_id=$(echo "$repo_json" | jq -r '.id // 0')
    local repo_state=$(echo "$repo_json" | jq -r '.state // "AVAILABLE"')
    
    # Extract clone URLs
    local clone_ssh=$(echo "$repo_json" | jq -r '.links.clone[]? | select(.name == "ssh") | .href // ""')
    local clone_http=$(echo "$repo_json" | jq -r '.links.clone[]? | select(.name == "http") | .href // ""')
    
    # Extract sizes
    local repo_size=$(echo "$size_json" | jq -r '.repository // 0')
    local attachments_size=$(echo "$size_json" | jq -r '.attachments // 0')
    
    # Calculate totals
    local total_size=$((repo_size + attachments_size))
    local total_size_mb=$(echo "scale=2; $total_size / 1048576" | bc 2>/dev/null || echo "0")
    
    local timestamp=$(date -Iseconds)
    
    # Escape special characters in names
    project_name=$(echo "$project_name" | sed 's/,/;/g' | sed 's/"/""/g')
    repo_name=$(echo "$repo_name" | sed 's/,/;/g' | sed 's/"/""/g')
    
    # Write to report
    echo "\"$project_key\",\"$project_name\",\"$repo_slug\",\"$repo_name\",$repo_id,\"$clone_ssh\",\"$clone_http\",\"$repo_state\",$repo_size,$attachments_size,$total_size,$total_size_mb,\"$timestamp\"" >> "$REPORT_FILE"
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
    local repos=$(fetch_repos_for_project "$project_key" "$base_url")
    
    if [[ -z "$repos" ]] || [[ "$repos" == "[]" ]]; then
        log_warn "No repositories found or failed to fetch for project: $project_key"
        write_error_entry "$project_key" "" "FETCH_REPOS" "No repositories found or API call failed"
        update_progress "$project_key" "failed"
        return 1
    fi
    
    local repo_count=$(echo "$repos" | jq 'length')
    log_info "Found $repo_count repositories in project $project_key"
    
    # Process each repository
    local processed=0
    local failed=0
    
    echo "$repos" | jq -c '.[]' | while read -r repo; do
        local repo_slug=$(echo "$repo" | jq -r '.slug')
        
        log_debug "Processing repo: $project_key/$repo_slug"
        
        # Fetch size for the repo
        local size=$(fetch_repo_size "$project_key" "$repo_slug" "$base_url")
        
        if [[ $(echo "$size" | jq -r '.repository') == "-1" ]]; then
            write_error_entry "$project_key" "$repo_slug" "FETCH_SIZE" "Failed to fetch repository size"
            ((failed++))
        fi
        
        # Write repo entry regardless of size fetch status
        write_repo_entry "$project_key" "$project_name" "$repo" "$size"
        ((processed++))
        
        # Small delay to avoid overwhelming the server
        sleep 0.1
    done
    
    update_progress "$project_key" "success"
    log_info "Completed project $project_key: processed $processed repos, failed $failed size fetches"
    
    return 0
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
    local total_size=$(tail -n +2 "$REPORT_FILE" | awk -F',' '{sum += $11} END {print sum}')
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
