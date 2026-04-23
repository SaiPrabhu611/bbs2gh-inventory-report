#!/bin/bash

#===============================================================================
# Batch Runner for BBS Repository Inventory Generator
#
# This script orchestrates running multiple batches of the inventory generator
# with configurable batch sizes and wait times between batches.
#
# Usage: ./batch_runner.sh <projects.csv> [OPTIONS]
#===============================================================================

set -e

readonly SCRIPT_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
readonly INVENTORY_SCRIPT="${SCRIPT_DIR}/bbs_repo_inventory.sh"
readonly TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Defaults
BATCH_SIZE=50
WAIT_BETWEEN_BATCHES=30
START_FROM=1
END_AT=""
DRY_RUN=false
VERBOSE=false

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

usage() {
    cat << EOF
Batch Runner for BBS Repository Inventory Generator

USAGE:
    $(basename "$0") <projects.csv> [OPTIONS]

ARGUMENTS:
    <projects.csv>          Path to projects CSV file

OPTIONS:
    -b, --batch-size <num>  Number of projects per batch (default: 50)
    -w, --wait <seconds>    Wait time between batches (default: 30)
    -s, --start <num>       Start from project number (default: 1)
    -e, --end <num>         End at project number (default: total projects)
    --dry-run               Show what would be executed without running
    -v, --verbose           Verbose output
    -h, --help              Show this help

EXAMPLES:
    # Run all projects with default batch size of 50
    $(basename "$0") projects.csv

    # Run with batch size of 100
    $(basename "$0") projects.csv -b 100

    # Run projects 101-500 with batch size 50
    $(basename "$0") projects.csv -s 101 -e 500 -b 50

    # Dry run to see batch plan
    $(basename "$0") projects.csv --dry-run

ENVIRONMENT VARIABLES:
    BBS_USER       Bitbucket Server username (required)
    BBS_PASSWORD   Bitbucket Server password (required)

EOF
    exit 0
}

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

parse_args() {
    if [[ $# -lt 1 ]]; then
        usage
    fi

    PROJECTS_FILE="$1"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -b|--batch-size)
                BATCH_SIZE="$2"
                shift 2
                ;;
            -w|--wait)
                WAIT_BETWEEN_BATCHES="$2"
                shift 2
                ;;
            -s|--start)
                START_FROM="$2"
                shift 2
                ;;
            -e|--end)
                END_AT="$2"
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
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

validate() {
    if [[ ! -f "$PROJECTS_FILE" ]]; then
        log_error "Projects file not found: $PROJECTS_FILE"
        exit 1
    fi

    if [[ ! -f "$INVENTORY_SCRIPT" ]]; then
        log_error "Inventory script not found: $INVENTORY_SCRIPT"
        exit 1
    fi

    if [[ -z "${BBS_USER:-}" ]] || [[ -z "${BBS_PASSWORD:-}" ]]; then
        log_error "BBS_USER and BBS_PASSWORD environment variables are required"
        log_info "Set them with:"
        log_info "  export BBS_USER='your_username'"
        log_info "  export BBS_PASSWORD='your_password'"
        exit 1
    fi

    if ! [[ "$BATCH_SIZE" =~ ^[0-9]+$ ]] || [[ "$BATCH_SIZE" -lt 1 ]]; then
        log_error "Invalid batch size: $BATCH_SIZE"
        exit 1
    fi
}

count_projects() {
    # Count non-header lines
    tail -n +2 "$PROJECTS_FILE" | wc -l | tr -d ' '
}

run_batches() {
    local total_projects=$(count_projects)
    
    if [[ -z "$END_AT" ]] || [[ "$END_AT" -gt "$total_projects" ]]; then
        END_AT=$total_projects
    fi

    local projects_to_process=$((END_AT - START_FROM + 1))
    local num_batches=$(( (projects_to_process + BATCH_SIZE - 1) / BATCH_SIZE ))
    
    echo ""
    echo "=========================================="
    echo "BBS Inventory Batch Runner"
    echo "=========================================="
    echo "Projects File:    $PROJECTS_FILE"
    echo "Total Projects:   $total_projects"
    echo "Processing Range: $START_FROM to $END_AT"
    echo "Batch Size:       $BATCH_SIZE"
    echo "Number of Batches: $num_batches"
    echo "Wait Between:     ${WAIT_BETWEEN_BATCHES}s"
    echo "=========================================="
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "DRY RUN - Batch Plan:"
        echo "----------------------"
    fi

    local batch_num=1
    local current_start=$START_FROM
    local successful_batches=0
    local failed_batches=0

    while [[ $current_start -le $END_AT ]]; do
        local current_end=$((current_start + BATCH_SIZE - 1))
        if [[ $current_end -gt $END_AT ]]; then
            current_end=$END_AT
        fi

        echo ""
        log_info "Batch $batch_num/$num_batches: Projects $current_start to $current_end"

        if [[ "$DRY_RUN" == "true" ]]; then
            echo "  Command: $INVENTORY_SCRIPT -f $PROJECTS_FILE -s $current_start -e $current_end -u \$BBS_USER:\$BBS_PASSWORD"
        else
            local verbose_flag=""
            if [[ "$VERBOSE" == "true" ]]; then
                verbose_flag="-v"
            fi

            if "$INVENTORY_SCRIPT" -f "$PROJECTS_FILE" -s "$current_start" -e "$current_end" -u "${BBS_USER}:${BBS_PASSWORD}" $verbose_flag; then
                log_info "Batch $batch_num completed successfully"
                ((successful_batches++))
            else
                log_warn "Batch $batch_num completed with errors"
                ((failed_batches++))
            fi

            # Wait between batches (except for last batch)
            if [[ $current_end -lt $END_AT ]] && [[ $WAIT_BETWEEN_BATCHES -gt 0 ]]; then
                log_info "Waiting ${WAIT_BETWEEN_BATCHES} seconds before next batch..."
                sleep "$WAIT_BETWEEN_BATCHES"
            fi
        fi

        current_start=$((current_end + 1))
        ((batch_num++))
    done

    echo ""
    echo "=========================================="
    echo "Batch Processing Complete"
    echo "=========================================="
    if [[ "$DRY_RUN" != "true" ]]; then
        echo "Successful Batches: $successful_batches"
        echo "Failed Batches:     $failed_batches"
    fi
    echo "=========================================="
}

main() {
    parse_args "$@"
    validate
    run_batches
}

main "$@"
