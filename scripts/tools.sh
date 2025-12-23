#!/bin/bash
# tools.sh - Tool installation and management

# Exit on error
set -e

# Source common utilities
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

# -----------------------------------------------------------------------------
# Tool installation functions
# -----------------------------------------------------------------------------
function ensure_helm_installed() {
    if ! command -v helm &> /dev/null; then
        log "INFO" "Helm not found. Installing helm..."
        install_helm
    else
        log "INFO" "Helm is already installed. Version: $(helm version --short)"
    fi
}

function install_helm() {
    log "INFO" "Installing Helm $(if [ -n "$HELM_VERSION" ]; then echo $HELM_VERSION; else echo "latest"; fi)..."
    
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 get_helm.sh
    DESIRED_VERSION=$HELM_VERSION ./get_helm.sh
    rm get_helm.sh

    log "INFO" "Helm installation complete. Installed version: $(helm version --short)"
}

function install_hypershift_cli() {
    log "INFO" "Installing Hypershift CLI binary..."

    # Check if hypershift CLI is already installed
    if command -v hypershift &> /dev/null; then
        log "INFO" "Hypershift CLI already installed. Version: $(hypershift version 2>/dev/null || echo 'unknown')"
        return 0
    fi

    # Create a temporary container and copy the hypershift binary
    CONTAINER_COMMAND=${CONTAINER_COMMAND:-podman}
    $CONTAINER_COMMAND cp $($CONTAINER_COMMAND create --name hypershift --rm --pull always $HYPERSHIFT_IMAGE):/usr/bin/hypershift /tmp/hypershift
    $CONTAINER_COMMAND rm -f hypershift

    # Install the hypershift binary
    sudo install -m 0755 -o root -g root /tmp/hypershift /usr/local/bin/hypershift
    rm -f /tmp/hypershift

    log "INFO" "Hypershift CLI installed successfully!"
}

# Legacy function for backwards compatibility
function install_hypershift() {
    install_hypershift_cli
}

function install_oc() {
    # Download the OpenShift CLI
    log "INFO" "Downloading OpenShift CLI..."
    wget https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz

    # Extract the archive
    tar -xzf openshift-client-linux.tar.gz

    # Move the oc binary to a directory in your PATH
    sudo mv oc /usr/local/bin/

    # Verify the installation
    oc version
}

# -----------------------------------------------------------------------------
# Command dispatcher
# -----------------------------------------------------------------------------
function main() {
    local command=$1
    shift

    case "$command" in
        install-helm)
            install_helm
            ;;
        install-hypershift)
            install_hypershift
            ;;
        *)
            log "Unknown command: $command"
            log "Available commands: install-helm, install-hypershift"
            exit 1
            ;;
    esac
}

# If script is executed directly (not sourced), run the main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ $# -lt 1 ]; then
        log "Usage: $0 <command> [arguments...]"
        exit 1
    fi
    
    main "$@"
fi 
