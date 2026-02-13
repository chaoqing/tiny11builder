#!/bin/bash
#
# update_iso_map.sh - Generate Windows ISO URL mappings from dockur repository
#
# This script downloads the dockur Windows ISO resolution logic and uses it
# to generate a JSON mapping of Windows version keys to their download URLs.
#

set -euo pipefail

# Constants
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DOCKUR_REPO="https://github.com/dockur/windows.git"
readonly DOCKUR_DIR="dockur_code"
readonly DEFAULT_OUTPUT="iso_map.json"
readonly TIMEOUT_SECONDS=60
readonly DEFAULT_VERSION_KEYS=("11" "11l" "10" "10l")

# Global options
OUTPUT_FILE="${DEFAULT_OUTPUT}"
KEEP_INTERMEDIATE=false
VERSION_KEYS=()

# Logging functions
log_info() {
    echo "[INFO] $*" >&2
}

log_warn() {
    echo "[WARN] $*" >&2
}

log_error() {
    echo "[ERROR] $*" >&2
}

log_debug() {
    if [[ -n "${DEBUG:-}" ]]; then
        echo "[DEBUG] $*" >&2
    fi
}

# Usage information
usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} [OPTIONS] [VERSION_KEYS...]

Generate a JSON mapping of Windows ISO version keys to download URLs using
the dockur repository resolution logic.

ARGUMENTS:
    VERSION_KEYS            Space-separated list of version keys to resolve
                            (default: ${DEFAULT_VERSION_KEYS[*]})

OPTIONS:
    -h, --help              Show this help message and exit
    -o, --output FILE       Output JSON file path (default: ${DEFAULT_OUTPUT})
    -k, --keep              Keep intermediate files (dockur repository)
    -d, --debug             Enable debug logging

EXAMPLES:
    # Generate ISO map with default settings
    ${SCRIPT_NAME}

    # Resolve specific versions as positional arguments
    ${SCRIPT_NAME} 11 10

    # Resolve single version
    ${SCRIPT_NAME} 11l

    # Specify custom output file and keep intermediate files
    ${SCRIPT_NAME} --output custom_map.json --keep

    # Combine options with custom versions
    ${SCRIPT_NAME} --output custom.json --keep 11 10l

    # Enable debug logging with specific versions
    ${SCRIPT_NAME} --debug 11 11l

VERSION KEYS:
    11   - Windows 11 (latest)
    11l  - Windows 11 LTSC
    10   - Windows 10 (latest)
    10l  - Windows 10 LTSC

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -o|--output)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option $1 requires an argument"
                    exit 1
                fi
                OUTPUT_FILE="$2"
                shift 2
                ;;
            -k|--keep)
                KEEP_INTERMEDIATE=true
                shift
                ;;
            -d|--debug)
                DEBUG=1
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                # Treat remaining arguments as version keys
                VERSION_KEYS+=("$1")
                shift
                ;;
        esac
    done

    # Use default version keys if none provided
    if [[ ${#VERSION_KEYS[@]} -eq 0 ]]; then
        VERSION_KEYS=("${DEFAULT_VERSION_KEYS[@]}")
        log_debug "Using default version keys: ${VERSION_KEYS[*]}"
    else
        log_info "Using custom version keys: ${VERSION_KEYS[*]}"
    fi
}

# Mock functions expected by dockur scripts
error() {
    log_error "$*"
    # Return error via output instead of exiting
    echo "ERROR: $*" >&2
    exit 1
}

info() {
    log_info "$*"
}

html() {
    :
}

warn() {
    log_warn "$*"
}

getLanguage() {
    case "$2" in
        "name"|"desc") echo "English" ;;
        "culture") echo "en-US" ;;
    esac
}

# Set required variables to avoid unbound variable errors
DEBUG="${DEBUG:-}"
VERIFY=""
TMP=""

# Download dockur code repository
download_dockur_code() {
    log_info "Downloading dockur code from ${DOCKUR_REPO}..."

    if [[ -d "${DOCKUR_DIR}" ]]; then
        log_debug "Removing existing ${DOCKUR_DIR} directory"
        rm -rf "${DOCKUR_DIR}"
    fi

    if ! git clone --depth 1 --filter=blob:none --sparse "${DOCKUR_REPO}" "${DOCKUR_DIR}" >/dev/null 2>&1; then
        log_error "Failed to clone dockur repository"
        return 1
    fi

    cd "${DOCKUR_DIR}" || return 1
    if ! git sparse-checkout set src >/dev/null 2>&1; then
        log_error "Failed to checkout src directory"
        cd ..
        return 1
    fi
    cd ..

    log_info "Successfully downloaded dockur code"
}

# Resolve URL for a given version key
# Runs in a subshell to isolate the sourced scripts
resolve_version() {
    local version_key="$1"

    (
        # dockur logic expects VERSION to be set
        VERSION="${version_key}"

        # Source dockur scripts
        # shellcheck disable=SC1091
        source "${DOCKUR_DIR}/src/define.sh"
        # shellcheck disable=SC1091
        source "${DOCKUR_DIR}/src/mido.sh"

        # Normalize (e.g. 11l -> win11x64-enterprise-ltsc-eval)
        parseVersion

        # Resolve URL
        PLATFORM="x64"
        if getWindows "$VERSION" "en-US" "Windows" 2>&1; then
            if [[ -n "${MIDO_URL:-}" ]]; then
                echo "${MIDO_URL}"
            else
                echo "null"
            fi
        else
            echo "null"
        fi
    )
}

# Cleanup intermediate files
cleanup() {
    if [[ "${KEEP_INTERMEDIATE}" == false ]]; then
        if [[ -d "${DOCKUR_DIR}" ]]; then
            log_info "Cleaning up intermediate files..."
            rm -rf "${DOCKUR_DIR}"
        fi
    else
        log_info "Keeping intermediate files in ${DOCKUR_DIR}"
    fi
}

# Main function to generate the ISO map
generate_iso_map() {
    local url
    local exit_code
    local first=1

    log_info "Generating ISO URL map..."

    # Setup
    download_dockur_code || return 1

    # Build JSON map
    {
        echo "{"

        for key in "${VERSION_KEYS[@]}"; do
            log_info "Resolving version key: ${key}"

            # Add timeout to prevent hanging
            # Export necessary variables and functions to the subshell
            url=$(timeout "${TIMEOUT_SECONDS}" bash -c "
                DOCKUR_DIR='${DOCKUR_DIR}'
                DEBUG='${DEBUG:-}'
                VERIFY='${VERIFY}'
                TMP='${TMP}'
                $(declare -f log_error)
                $(declare -f log_info)
                $(declare -f log_warn)
                $(declare -f error)
                $(declare -f info)
                $(declare -f html)
                $(declare -f warn)
                $(declare -f getLanguage)
                $(declare -f resolve_version)
                resolve_version '${key}'
            " 2>&1 | tail -1)
            exit_code=$?

            # If timeout or error, set to null
            if [[ ${exit_code} -ne 0 ]] || [[ -z "${url}" ]]; then
                if echo "${url}" | grep -q "ERROR:"; then
                    log_error "Failed to resolve ${key}: ${url}"
                else
                    log_warn "Failed to resolve ${key} (exit code: ${exit_code}), setting to null"
                fi
                url="null"
            else
                log_debug "Resolved ${key} -> ${url}"
            fi

            if [[ ${first} -ne 1 ]]; then
                echo ","
            fi
            echo "  \"${key}\": \"${url}\""
            first=0
        done

        echo "}"
    } > "${OUTPUT_FILE}"

    log_info "Generated ${OUTPUT_FILE}:"
    cat "${OUTPUT_FILE}"
}

# Main entry point
main() {
    parse_args "$@"

    # Set up cleanup trap
    trap cleanup EXIT

    # Generate the ISO map
    if generate_iso_map; then
        log_info "ISO map generation completed successfully"
        exit 0
    else
        log_error "ISO map generation failed"
        exit 1
    fi
}

# Run main function
main "$@"
