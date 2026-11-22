#!/bin/bash

set -euo pipefail

echo "=================================================="
echo " Login / Security Provisioning"
echo "=================================================="

PROVISION_DIR="$(dirname "$(readlink -f "$0")")"

bash "${PROVISION_DIR}/providers/login/users.sh"
bash "${PROVISION_DIR}/providers/login/groups.sh"
bash "${PROVISION_DIR}/providers/login/sudo.sh"
bash "${PROVISION_DIR}/providers/login/password.sh"
bash "${PROVISION_DIR}/providers/login/pam.sh"
bash "${PROVISION_DIR}/providers/login/filesystem.sh"
bash "${PROVISION_DIR}/providers/login/permissions.sh"
bash "${PROVISION_DIR}/providers/login/acl.sh"
bash "${PROVISION_DIR}/providers/login/sticky.sh"
bash "${PROVISION_DIR}/providers/login/ssh.sh"

echo "=================================================="
echo " Login / Security Provisioning Completed"
echo "=================================================="