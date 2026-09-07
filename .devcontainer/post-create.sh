#!/usr/bin/env bash
set -euo pipefail

python -m pip install -r requirements-dev.txt

echo "Installed development tools:"
python --version
python -m flask --version
python -m pytest --version
az version --query '"azure-cli"' --output tsv
pwsh --version
