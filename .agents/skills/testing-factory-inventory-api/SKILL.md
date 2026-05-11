---
name: testing-factory-inventory-api
description: Test the factory inventory REST API end-to-end against the live AWS Lambda deployment. Use when verifying API changes, DynamoDB interactions, or deployment updates.
---

## Overview

The factory inventory service is a REST API deployed on AWS Lambda + API Gateway + DynamoDB in `ap-northeast-1` (Tokyo). Testing is done via shell commands (curl) — no UI exists.

## Devin Secrets Needed

- `AWS_IAM` — Contains `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_REGION` in a single string. Parse with grep.

## How to Parse AWS Credentials

```bash
export AWS_ACCESS_KEY_ID=$(echo "$AWS_IAM" | grep -oP 'AWS_ACCESS_KEY_ID\s*=\s*\K\S+')
export AWS_SECRET_ACCESS_KEY=$(echo "$AWS_IAM" | grep -oP 'AWS_SECRET_ACCESS_KEY\s*=\s*\K\S+')
export AWS_DEFAULT_REGION=ap-northeast-1
```

## Finding the API URL

The API Gateway URL follows the pattern:
```
https://<api-id>.execute-api.ap-northeast-1.amazonaws.com/prod/
```

To find the current API ID:
```bash
aws apigateway get-rest-apis --region ap-northeast-1 --query "items[?name=='factory-inventory-api'].id" --output text
```

## Endpoints to Test

| Method | Path | Key Assertions |
|--------|------|----------------|
| GET | `/` | Returns `status:ok`, `version:2.0.0`, message contains "AWS Lambda" |
| POST | `/inventory` | `action:created` or `action:updated`; `isLowStock` computed as `quantity <= minimumStock` |
| GET | `/inventory` | Supports `?factoryId=` and `?lowStock=true` query filters |
| POST | `/transfer` | Deducts from source, adds to destination (auto-creates if needed); validates stock |
| GET | `/transfers` | Supports `?factoryId=` and `?partId=` query filters |

## Testing Strategy

- Use **unique timestamp-based IDs** (e.g. `PART-${timestamp}`) per test run to avoid data interference from prior runs.
- All testing is shell-based (curl + python3 for JSON assertion parsing). **No recording needed** since there is no UI.
- Test validation errors (400/404) with exact error message string matching.
- Test transfer math: verify source deduction, destination creation, and `isLowStock` flag transitions.
- Test insufficient stock: attempt transfer exceeding available quantity, expect HTTP 400.

## DynamoDB Tables

- `FactoryInventory` — PK: `partId`, SK: `factoryId`, GSI: `factoryId-index`
- `FactoryTransfers` — PK: `transferId`, GSI: `partId-index`

## Deployment

Run `deploy.sh` from the repo root. It is idempotent and creates/updates all resources (DynamoDB tables, IAM role, Lambda function, API Gateway).

Note: The deploy script uses `aws lambda wait function-active` (not `function-active-v2`) for compatibility with older AWS CLI versions.
