# Deployment Guide - Serverless (Lambda + API Gateway + Amplify Hosting)

This project is a from-scratch serverless rebuild of the original Flask/Elastic
Beanstalk demo: every backend route is now its own Lambda function behind an
API Gateway HTTP API, and the static frontend is hosted on AWS Amplify. There
is no EC2, no Beanstalk, and no Cognito (the app never actually consumed the
Cognito scaffolding in the original build, so it was dropped rather than
carried forward unused).

## Architecture

| Layer | Service |
|---|---|
| Frontend hosting | AWS Amplify Hosting (`app/static/*`, manual zip deploy - no git remote is connected) |
| API | API Gateway HTTP API (16 routes, all `AWS_PROXY`) |
| Backend logic | 7 Lambda functions (Python 3.12), sharing one Lambda Layer for `app/services/*.py` |
| Data | DynamoDB (single table, `menu_id`/`item_id`), S3 (raw menu uploads) |
| Admin credential | Secrets Manager (`app_admin_password`), rotatable via the app's own "Change Password" action |
| AI | Bedrock (allergen extraction + translation), Textract (OCR), Amazon Translate (fallback) |

Everything lives in one region (`var.aws_region`, default `ap-southeast-2`) -
unlike the original build, which split DynamoDB/S3 into `us-east-1` while
Bedrock stayed in `ap-southeast-2`.

### The 7 Lambda functions

| Function | Routes | Auth |
|---|---|---|
| `read_menu` | `GET /restaurants`, `GET /menus/{restaurantId}`, `GET /menus/{uploadId}/status` | public |
| `edit_menu` | `PATCH /menus/{menuId}/items/{itemId}` | admin bearer token |
| `auth` | `POST /auth/login`, `POST /auth/change-password` | login public; change-password needs a token |
| `dish_mutations` | `POST /menus/{menuId}/items`, `DELETE /menus/{menuId}/items/{itemId}`, `DELETE /menus/{menuId}`, `POST /menus/{menuId}/seed` | admin bearer token |
| `upload_menu` | `POST /menus/{menuId}/upload` | admin bearer token |
| `allergen_api` | `POST /allergens/extract`, `POST /compliance/verify` | public |
| `reference_data` | `GET /health`, `GET /allergen-categories`, `GET /languages` | public |

Auth is a single shared admin credential (matching the original demo's scope
exactly - no per-user identity), enforced *inside* each handler via
`services/auth_service.py`, not by an API Gateway authorizer.

## Prerequisites

- Terraform >= 1.5, AWS CLI, Python 3.12 (to run `build/build_layer.py`)
- An AWS profile with rights to create Lambda/API Gateway/DynamoDB/S3/Secrets Manager/Amplify/IAM resources
- Bedrock model access granted for `var.bedrock_model_id` in `var.aws_region` (Bedrock console -> Model access) - without it, allergen extraction/translation silently fall back to the offline keyword-scan / Amazon Translate stubs

## 1. Build the Lambda packages

```bash
python3 build/build_layer.py
```

This copies `app/services/*.py` (byte-for-byte) into `build/layer/python/services/`,
and the small `docs/*.md` regulatory files into `build/layer/docs/` (the local
RAG-fallback search reads these when no Bedrock Knowledge Base is configured).
Re-run this any time a file under `app/services/` changes - Terraform hashes
`build/layer/` on every `plan`/`apply`, so a stale layer is otherwise invisible
until you actually invoke a function and hit an `ImportModuleError`.

## 2. Deploy the backend with Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit aws_profile / bedrock_model_id as needed
terraform init
terraform plan -out=tfplan
terraform apply "tfplan"
```

Grab the API base URL:

```bash
terraform output menu_api_invoke_url
```

## 3. Point the frontend at the API, then deploy it to Amplify

Edit `app/static/config.js`:

```js
window.API_BASE_URL = "<menu_api_invoke_url, no trailing slash>";
```

Amplify has no connected git repository in this demo (there's no GitHub
remote), so every deploy is a manual zip upload:

```bash
cd app/static
zip -r /tmp/frontend.zip . -x ".*"

APP_ID=$(cd ../../terraform && terraform output -raw amplify_app_id)
RESP=$(aws amplify create-deployment --app-id "$APP_ID" --branch-name main)
UPLOAD_URL=$(echo "$RESP" | python3 -c "import json,sys;print(json.load(sys.stdin)['zipUploadUrl'])")
JOB_ID=$(echo "$RESP" | python3 -c "import json,sys;print(json.load(sys.stdin)['jobId'])")
curl -X PUT "$UPLOAD_URL" --data-binary @/tmp/frontend.zip -H "Content-Type: application/zip"
aws amplify start-deployment --app-id "$APP_ID" --branch-name main --job-id "$JOB_ID"
```

Poll status with `aws amplify get-job --app-id "$APP_ID" --branch-name main --job-id "$JOB_ID"`
until `job.summary.status` is `SUCCEED`. Then open:

```bash
terraform -chdir=terraform output frontend_url
```

Repeat this step (no Terraform re-apply needed) every time only `app/static/*`
changes; repeat step 2 when anything under `terraform/`, `build/`, or
`app/services/` changes.

## 4. Seed a restaurant registry row

Restaurant creation is still manual/CLI-only (no admin UI or write endpoint
for it, matching the original project's documented scope). `GET /restaurants`
reads dedicated registry rows, not inferred from dish rows:

```bash
TABLE=$(terraform -chdir=terraform output -raw dynamodb_table_name)
aws dynamodb put-item --table-name "$TABLE" --region ap-southeast-2 --item '{
  "menu_id":   {"S": "my-cafe"},
  "item_id":   {"S": "restaurant#my-cafe"},
  "record_type": {"S": "restaurant"},
  "name":      {"S": "My Cafe"}
}'
```

## 5. Admin login

- Username: `admin`
- Password: whatever `var.app_admin_initial_password` was set to (default `admin`) - change it via the app's own **Change Password** button afterward, which rotates the Secrets Manager value directly. Terraform will never overwrite a rotated password on a later `apply` (see `secrets.tf`'s `ignore_changes`).

## Known trade-offs of this migration (read before assuming parity)

- **Upload size cap is 4MB**, not the original 10MB. API Gateway HTTP APIs cap request payloads at 10MB, but a synchronous Lambda invocation payload is capped at 6MB, and a base64-encoded file is ~33% larger than the original - so 4MB raw stays safely under that. A production version would have the browser upload straight to S3 via a presigned URL and process asynchronously; that's out of scope here.
- **No Cognito / per-user auth.** Same single shared admin credential as the original app, just moved from a hardcoded string into Secrets Manager. A production version would want real per-user identity.
- **CORS is wide open (`allow_origins = ["*"]`)** on the API Gateway HTTP API, since the Amplify domain isn't known until after the first `apply` (avoiding that chicken-and-egg dependency). Fine for a public demo with header-based (not cookie-based) auth; tighten it to the actual Amplify domain for anything more sensitive.
- **The Bedrock Knowledge Base is still opt-in** (`var.create_knowledge_base = false` by default), identical to the original project.

## Destroying the stack

```bash
cd terraform
terraform destroy
```

Removes every Lambda, the API Gateway, DynamoDB table, S3 buckets
(`force_destroy = true`), the Secrets Manager secret, and the Amplify app.
Nothing is left behind.
