#!/usr/bin/env bash
#
# install.sh – Fetch files from a Git repo and copy them to local directories
#

# THIS IS A WORK IN PROGRESS.  IT WILL NOT EXECUTE IN ITS CURRENT STATE.

#------------------------------------------------------------------------------
# 1. Strict mode and utility functions
#------------------------------------------------------------------------------

# Exit on any error, treat unset variables as errors, and catch errors in pipelines
set -euo pipefail

# Print an error message to stderr and exit
error_exit() {
    echo "[ERROR] $1" >&2
    exit "${2:-1}"
}

# Print an informational message
log_info() {
    echo "[INFO] $1"
}

#------------------------------------------------------------------------------
# 2. Configuration / Variables
#------------------------------------------------------------------------------

# URL of the Git repository (HTTPS or SSH)
REPO_URL="https://github.com/product-design-experts/Soundscapes.git"

# Local path where the repo will be cloned or updated
# e.g., /home/pi/my‐project
LOCAL_REPO_DIR="~/audiostream"

# Branch (or tag) to check out
GIT_BRANCH="main"

# List of files or directories (relative to $LOCAL_REPO_DIR) to copy
# into corresponding destination paths. Format: ["source"]="destination"
declare -A FILE_MAP=(
    ["scripts/my‐script.sh"]="/usr/local/bin/my‐script.sh"
    ["config/app.conf"]="/etc/myapp/app.conf"
    ["www/"]="var/www/html/myapp/"
)

# (Optional) Log file to record errors or actions
LOGFILE="/var/log/install_audiostream.log"

#------------------------------------------------------------------------------
# 3. Prerequisite checks
#------------------------------------------------------------------------------

check_prerequisites() {
    log_info "Checking prerequisites…"

    # 3.1 Check for git
    if ! command -v git >/dev/null 2>&1; then
        error_exit "git is not installed. Please install git and retry."
    fi

    # 3.2 Check that we can write to the parent of LOCAL_REPO_DIR
    local parent_dir
    parent_dir="$(dirname "$LOCAL_REPO_DIR")"
    if [ ! -d "$parent_dir" ] || [ ! -w "$parent_dir" ]; then
        error_exit "Cannot write to '$parent_dir'. Check permissions."
    fi

    # 3.3 Check each destination directory’s parent is writable (later)
    log_info "Prerequisite checks passed."
}

#------------------------------------------------------------------------------
# 4. Clone or update the Git repository
#------------------------------------------------------------------------------

update_repo() {
    if [ -d "$LOCAL_REPO_DIR/.git" ]; then
        log_info "Repository already exists. Pulling latest updates from '$GIT_BRANCH'…"
        (
            cd "$LOCAL_REPO_DIR"
            # Ensure we’re on the correct branch
            git fetch origin \
                || error_exit "Failed to fetch from origin."
            git checkout "$GIT_BRANCH" \
                || error_exit "Failed to switch to branch '$GIT_BRANCH'."
            git pull origin "$GIT_BRANCH" \
                || error_exit "Failed to pull latest changes."
        )
        log_info "Repository updated."
    else
        log_info "Cloning repository '$REPO_URL' (branch '$GIT_BRANCH')…"
        git clone --branch "$GIT_BRANCH" "$REPO_URL" "$LOCAL_REPO_DIR" \
            || error_exit "Failed to clone repository '$REPO_URL'."
        log_info "Clone successful."
    fi
}

#------------------------------------------------------------------------------
# 5. Copy files from the repo into their destinations
#------------------------------------------------------------------------------

copy_files() {
    log_info "Starting file‐copy phase…"

    for src_rel in "${!FILE_MAP[@]}"; do
        dest_abs="${FILE_MAP[$src_rel]}"

        src_path="$LOCAL_REPO_DIR/$src_rel"
        if [ ! -e "$src_path" ]; then
            error_exit "Source '$src_path' does not exist."
        fi

        # Ensure destination directory exists
        dest_parent="$(dirname "$dest_abs")"
        if [ ! -d "$dest_parent" ]; then
            log_info "Creating directory '$dest_parent'…"
            mkdir -p "$dest_parent" \
                || error_exit "Failed to create directory '$dest_parent'."
        fi

        # Copy—if it's a directory, use -r; otherwise, copy file
        if [ -d "$src_path" ]; then
            log_info "Copying directory '$src_rel' → '$dest_parent/'"
            cp -r "$src_path" "$dest_parent/" \
                || error_exit "Failed to copy directory '$src_rel'."
        else
            log_info "Copying file '$src_rel' → '$dest_abs'"
            cp "$src_path" "$dest_abs" \
                || error_exit "Failed to copy file '$src_rel'."
        fi
    done

    log_info "All files copied successfully."
}

#------------------------------------------------------------------------------
# 6. Post‐install cleanup or permissions adjustments (optional)
#------------------------------------------------------------------------------

post_install_steps() {
    log_info "Running post‐install steps…"

    # Example: make scripts executable
    if [ -f "/usr/local/bin/my‐script.sh" ]; then
        chmod +x /usr/local/bin/my‐script.sh \
            || error_exit "Failed to chmod +x /usr/local/bin/my‐script.sh."
    fi

    # Example: reload service if you copied a new systemd unit
    # if systemctl is-enabled myapp.service &>/dev/null; then
    #     systemctl daemon-reload
    #     systemctl restart myapp.service
    # fi

    log_info "Post‐install steps completed."
}

#------------------------------------------------------------------------------
# 7. Main entry point
#------------------------------------------------------------------------------

main() {
    # Redirect stdout & stderr to logfile (optional)
    # exec > >(tee -a "$LOGFILE") 2>&1

    log_info "=== BEGIN installation at $(date) ==="

    check_prerequisites
    update_repo
    copy_files
    post_install_steps

    log_info "=== Installation completed successfully at $(date) ==="
    exit 0
}

# Invoke main()
main "$@"
