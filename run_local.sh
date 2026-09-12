#!/usr/bin/env bash
# Runs the Flask app locally in LOCAL_MODE (no AWS account needed) so you
# can click through the UI before/without deploying to Elastic Beanstalk.
# Real Bedrock/Textract/S3/DynamoDB calls are replaced with clearly-labelled
# offline stubs and a /tmp JSON file, everything else (routes, allergen
# rules engine, translations map, human-in-the-loop edit flow) runs exactly
# as it will in AWS.
set -e
cd "$(dirname "$0")/app"

export LOCAL_MODE=true
export FLASK_ENV=development
export PORT=8000

python3 -m venv .venv 2>/dev/null || true
source .venv/bin/activate
pip install -q -r requirements.txt

echo "Starting local server at http://localhost:8000  (LOCAL_MODE=true, no AWS calls)"
python3 application.py
