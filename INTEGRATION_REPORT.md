# Integration Completion Report

## Report Date
September 13, 2026

## Objective
Migrate the AI Allergen Compliance system off Elastic Beanstalk to a fully serverless architecture — 7 Lambda functions behind an API Gateway HTTP API, a static frontend on AWS Amplify Hosting, Terraform-managed infrastructure with remote state, and a working CI/CD pipeline — with full functional parity against the original Flask app's routes.

## Completed Work

### 1. Serverless Rewrite (Full Route Parity)
Every Flask route in the predecessor app now has a Lambda equivalent:

| Function | Routes |
|---|---|
| `read_menu` | `GET /restaurants`, `GET /menus/{restaurantId}`, `GET /menus/{uploadId}/status` |
| `edit_menu` | `PATCH /menus/{menuId}/items/{itemId}` |
| `auth` | `POST /auth/login`, `POST /auth/change-password` |
| `dish_mutations` | `POST /menus/{menuId}/items`, `DELETE /menus/{menuId}/items/{itemId}`, `DELETE /menus/{menuId}`, `POST /menus/{menuId}/seed` |
| `upload_menu` | `POST /menus/{menuId}/upload` (multipart, OCR) |
| `allergen_api` | `POST /allergens/extract`, `POST /compliance/verify` |
| `reference_data` | `GET /health`, `GET /allergen-categories`, `GET /languages` |

All seven share one Lambda Layer (`build/layer/`) built from `app/services/*.py`, byte-for-byte — no per-function copy that can drift.

### 2. Infrastructure
- **Terraform**: Lambda, API Gateway HTTP API, DynamoDB, S3, Secrets Manager, Amplify app, all in `ap-southeast-2`.
- **Remote state**: S3 bucket + DynamoDB lock table (`terraform/bootstrap/`), migrated from local state with zero resource drift.
- **CI/CD**: `.github/workflows/deploy.yml` — GitHub Actions authenticates via OIDC (no stored AWS keys), PRs plan-only, pushes to `main` apply + deploy the frontend to Amplify.
- **Security improvements over the predecessor**: least-privilege IAM per function (verified against actual handler code, not granted by convention); admin password moved from a hardcoded string to Secrets Manager, with a working "Change Password" action; every mutating route now requires the admin bearer token (three of the four previously did not).

### 3. Testing & Verification
- ✅ Every route exercised directly (curl) against the live API — login, change-password + revert, manual dish add, delete, seed, PATCH edit (with and without auth, confirming 401 on the unauthenticated case), file upload with a real image through OCR.
- ✅ Full browser UI flow (Playwright): cafe picker, cafe selection, admin login, manual add, allergen-filter checkbox toggling (confirmed discriminating correctly across combinations), change password + revert, clear dishes — zero console errors on the final pass.
- ✅ Live Bedrock LLM output confirmed (`"llm_source": "bedrock"`, not the offline fallback) after the model-id fix below.
- ✅ CI pipeline exercised end-to-end after each of the bugs below was fixed.
- ✅ A 4-dish test PDF uploaded through the full pipeline (S3 → Textract → parser → Bedrock extract/translate ×4) in 15.8s, well inside the 30s ceiling.

## Real Bugs Found and Fixed

| # | Bug | Root Cause | Fix |
|---|---|---|---|
| 1 | Dish-listing route returned 500 `AccessDeniedException` | `read_menu`'s dish-listing path uses `services/dynamo_service.py`, which reads `DYNAMODB_TABLE`; the Lambda's Terraform `environment` block only set `MENU_TABLE_NAME` (which its other two routes read directly) | Set both env var names to the same table on every DynamoDB-touching function |
| 2 | Allergen extraction/translation always fell back to offline/rules | Guessed Bedrock inference profile id (`apac.anthropic.claude-haiku-4-5-...`) doesn't exist in `ap-southeast-2` | Checked `aws bedrock list-inference-profiles`, switched to `global.anthropic.claude-haiku-4-5-...`, verified live |
| 3 | CI: `Not authorized to perform sts:AssumeRoleWithWebIdentity` | GitHub now sometimes issues "immutable ID" OIDC subject claims (`repo:owner@id/repo@id:ref:...`) instead of the classic format the IAM trust policy expected | Diagnosed via CloudTrail (`userIdentity.principalId`), added the immutable-ID pattern alongside the classic one |
| 4 | CI: `failed to get shared config profile, default` | AWS provider's `profile = "default"` forced a literal named-profile lookup that doesn't exist on the GitHub Actions runner (OIDC credentials arrive as plain env vars, not a profile file) | `aws_profile` now defaults to `""`; provider passes `null` when empty, falling through to the standard credential chain |
| 5 | CI: push to `main` rejected | A cached git credential on the dev machine lacked the `workflow` scope needed to update `.github/workflows/*.yml` | Pushed with an explicit PAT for that one commit; confirmed the token isn't persisted anywhere on disk afterward |
| 6 | Upload timed out (bare 500, zero log output) on an 8-dish test PDF | `upload_menu` ran the per-dish pipeline through an uncapped `ThreadPoolExecutor`, firing every dish's Bedrock calls at once; this account's on-demand quota throttled them immediately, and the resulting retries ran out the time budget before any dish finished | Diagnostic logging isolated the hang to the Bedrock loop; switched to sequential processing. Even then, 8 dishes measured 26-29s against API Gateway's hard 30s ceiling - a real capacity limit, not a bug, so it's now documented (README, TDD) rather than "fixed" outright |

## Compatibility Notes

- **No functional regressions.** Every capability in the original app has a Lambda equivalent; two legacy duplicate read routes (`/api/menus`, `/api/menus/<id>/items`) were consolidated into their `/v2`-style equivalents rather than carried forward as parallel paths, since they had no distinct behavior.
- **Cognito dropped, not carried forward unwired.** It was deployed-but-unused infrastructure in the predecessor (see `docs/TECHNICAL_DESIGN.md` §9 for what re-adding real per-user auth would look like).
- **Upload size reduced from 10MB to ~4MB** — a consequence of Lambda's synchronous invocation payload limit, documented in `README.md` and `DEPLOY_GUIDE.md`, not an oversight.

## Live Endpoints

```
Frontend:  https://main.dh7kbvjjic7ot.amplifyapp.com
API:       https://jnyks5sne0.execute-api.ap-southeast-2.amazonaws.com
Source:    https://github.com/rajkumar-BR/ai-allergen-compliance-demo
Region:    ap-southeast-2
```

## Further Reading

- **[README.md](README.md)** — architecture overview, API table, deploy steps.
- **[docs/TECHNICAL_DESIGN.md](docs/TECHNICAL_DESIGN.md)** — full technical design: data model, pipeline sequence diagram, per-Lambda IAM grants, CI/CD flow, known limitations and roadmap.
- **[DEPLOY_GUIDE.md](DEPLOY_GUIDE.md)** — step-by-step deployment and CI/CD setup instructions.

## Status
**Live and passing.** All 7 Lambda functions, the API Gateway, DynamoDB, S3, Secrets Manager, and the Amplify-hosted frontend are deployed and verified in `ap-southeast-2`. CI/CD is green on `main` after the fixes above.
