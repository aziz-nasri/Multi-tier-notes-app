#!/bin/bash
set -euo pipefail

echo "=================================================="
echo "Starting Full AWS Infrastructure Deployment..."
echo "=================================================="

# Helper function to execute script with logging and check existence
run_script() {
    local script_name=$1
    local description=$2

    if [ -f "./$script_name" ]; then
        echo ""
        echo "--------------------------------------------------"
        echo "--> [STEP] $description ($script_name)"
        echo "--------------------------------------------------"

        bash "./$script_name"
        
        echo "SUCCESS: $script_name completed."
    else
        echo "ERROR: Required script '$script_name' not found in current directory!"
        exit 1
    fi
}

# 1. Environment & Base Variables
run_script "env.sh" "Loading environment configuration"

# 2. Network Infrastructure
run_script "01-network.sh" "Provisioning Network Tier"

# 3. Security Tier
run_script "02-security.sh" "Provisioning Security & Access Controls"

# 4. Data Tier
run_script "03-data.sh" "Provisioning Data Tier & Storage"

# 5. Compute Tier
run_script "04-compute.sh" "Deploying Compute Infrastructure"

# 6. Edge & Frontend Tier
run_script "05-edge.sh" "Configuring Edge & Routing"

# 7. Observability Tier
run_script "06-obervability.sh" "Setting up Observability & Logging"

echo ""
echo "=================================================="
echo " Full Infrastructure Deployment Completed Successfully!"
echo "=================================================="