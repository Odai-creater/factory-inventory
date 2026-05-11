#!/bin/bash
set -euo pipefail

REGION="ap-northeast-1"
FUNCTION_NAME="factory-inventory-service"
ROLE_NAME="factory-inventory-lambda-role"
API_NAME="factory-inventory-api"
INVENTORY_TABLE="FactoryInventory"
TRANSFERS_TABLE="FactoryTransfers"
STAGE_NAME="prod"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "AWS Account: $ACCOUNT_ID"
echo "Region: $REGION"

# ─── 1. Create DynamoDB Tables ───────────────────────────────────────────────

echo ""
echo "=== Creating DynamoDB Tables ==="

# Inventory table: partId (PK) + factoryId (SK), GSI on factoryId
if aws dynamodb describe-table --table-name "$INVENTORY_TABLE" --region "$REGION" 2>/dev/null; then
  echo "Table $INVENTORY_TABLE already exists, skipping."
else
  echo "Creating table $INVENTORY_TABLE..."
  aws dynamodb create-table \
    --table-name "$INVENTORY_TABLE" \
    --attribute-definitions \
      AttributeName=partId,AttributeType=S \
      AttributeName=factoryId,AttributeType=S \
    --key-schema \
      AttributeName=partId,KeyType=HASH \
      AttributeName=factoryId,KeyType=RANGE \
    --global-secondary-indexes \
      '[{
        "IndexName": "factoryId-index",
        "KeySchema": [{"AttributeName":"factoryId","KeyType":"HASH"}],
        "Projection": {"ProjectionType":"ALL"},
        "ProvisionedThroughput": {"ReadCapacityUnits":5,"WriteCapacityUnits":5}
      }]' \
    --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
    --region "$REGION"
  echo "Waiting for $INVENTORY_TABLE to become ACTIVE..."
  aws dynamodb wait table-exists --table-name "$INVENTORY_TABLE" --region "$REGION"
  echo "$INVENTORY_TABLE is ACTIVE."
fi

# Transfers table: transferId (PK), GSI on partId
if aws dynamodb describe-table --table-name "$TRANSFERS_TABLE" --region "$REGION" 2>/dev/null; then
  echo "Table $TRANSFERS_TABLE already exists, skipping."
else
  echo "Creating table $TRANSFERS_TABLE..."
  aws dynamodb create-table \
    --table-name "$TRANSFERS_TABLE" \
    --attribute-definitions \
      AttributeName=transferId,AttributeType=S \
      AttributeName=partId,AttributeType=S \
    --key-schema \
      AttributeName=transferId,KeyType=HASH \
    --global-secondary-indexes \
      '[{
        "IndexName": "partId-index",
        "KeySchema": [{"AttributeName":"partId","KeyType":"HASH"}],
        "Projection": {"ProjectionType":"ALL"},
        "ProvisionedThroughput": {"ReadCapacityUnits":5,"WriteCapacityUnits":5}
      }]' \
    --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
    --region "$REGION"
  echo "Waiting for $TRANSFERS_TABLE to become ACTIVE..."
  aws dynamodb wait table-exists --table-name "$TRANSFERS_TABLE" --region "$REGION"
  echo "$TRANSFERS_TABLE is ACTIVE."
fi

# ─── 2. Create IAM Role ─────────────────────────────────────────────────────

echo ""
echo "=== Setting up IAM Role ==="

TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "lambda.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

if aws iam get-role --role-name "$ROLE_NAME" 2>/dev/null; then
  echo "Role $ROLE_NAME already exists."
else
  echo "Creating role $ROLE_NAME..."
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --region "$REGION"
  echo "Waiting for role propagation..."
  sleep 10
fi

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

# Attach policies
echo "Attaching policies..."
aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true

DYNAMO_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:Query",
      "dynamodb:Scan"
    ],
    "Resource": [
      "arn:aws:dynamodb:'"$REGION"':'"$ACCOUNT_ID"':table/'"$INVENTORY_TABLE"'",
      "arn:aws:dynamodb:'"$REGION"':'"$ACCOUNT_ID"':table/'"$INVENTORY_TABLE"'/index/*",
      "arn:aws:dynamodb:'"$REGION"':'"$ACCOUNT_ID"':table/'"$TRANSFERS_TABLE"'",
      "arn:aws:dynamodb:'"$REGION"':'"$ACCOUNT_ID"':table/'"$TRANSFERS_TABLE"'/index/*"
    ]
  }]
}'

aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "DynamoDBAccess" \
  --policy-document "$DYNAMO_POLICY"

echo "Waiting for policy propagation..."
sleep 10

# ─── 3. Package and Deploy Lambda ───────────────────────────────────────────

echo ""
echo "=== Packaging Lambda Function ==="

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/lambda"

rm -f function.zip
zip function.zip index.mjs

echo ""
echo "=== Deploying Lambda Function ==="

if aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" 2>/dev/null; then
  echo "Updating existing function..."
  aws lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --zip-file fileb://function.zip \
    --region "$REGION"
  
  aws lambda wait function-updated --function-name "$FUNCTION_NAME" --region "$REGION"
  
  aws lambda update-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --runtime nodejs20.x \
    --handler index.handler \
    --timeout 30 \
    --memory-size 256 \
    --environment "Variables={INVENTORY_TABLE=$INVENTORY_TABLE,TRANSFERS_TABLE=$TRANSFERS_TABLE,AWS_REGION_OVERRIDE=$REGION}" \
    --region "$REGION"
else
  echo "Creating new function..."
  aws lambda create-function \
    --function-name "$FUNCTION_NAME" \
    --runtime nodejs20.x \
    --role "$ROLE_ARN" \
    --handler index.handler \
    --zip-file fileb://function.zip \
    --timeout 30 \
    --memory-size 256 \
    --environment "Variables={INVENTORY_TABLE=$INVENTORY_TABLE,TRANSFERS_TABLE=$TRANSFERS_TABLE,AWS_REGION_OVERRIDE=$REGION}" \
    --region "$REGION"
fi

echo "Waiting for function to be ready..."
aws lambda wait function-active --function-name "$FUNCTION_NAME" --region "$REGION" 2>/dev/null || sleep 5

LAMBDA_ARN=$(aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" --query 'Configuration.FunctionArn' --output text)
echo "Lambda ARN: $LAMBDA_ARN"

# ─── 4. Create API Gateway (REST API) ───────────────────────────────────────

echo ""
echo "=== Setting up API Gateway ==="

# Check if API already exists
API_ID=$(aws apigateway get-rest-apis --region "$REGION" \
  --query "items[?name=='$API_NAME'].id" --output text)

if [ -n "$API_ID" ] && [ "$API_ID" != "None" ]; then
  echo "API $API_NAME already exists (ID: $API_ID). Updating..."
else
  echo "Creating REST API: $API_NAME"
  API_ID=$(aws apigateway create-rest-api \
    --name "$API_NAME" \
    --description "Factory Inventory Service API" \
    --endpoint-configuration types=REGIONAL \
    --region "$REGION" \
    --query 'id' --output text)
  echo "API ID: $API_ID"
fi

ROOT_ID=$(aws apigateway get-resources --rest-api-id "$API_ID" --region "$REGION" \
  --query "items[?path=='/'].id" --output text)

# Helper function to create resource and method
create_resource_and_method() {
  local RESOURCE_PATH=$1
  local HTTP_METHOD=$2
  local PARENT_ID=$3

  # Check if resource exists
  RESOURCE_ID=$(aws apigateway get-resources --rest-api-id "$API_ID" --region "$REGION" \
    --query "items[?path=='/$RESOURCE_PATH'].id" --output text)

  if [ -z "$RESOURCE_ID" ] || [ "$RESOURCE_ID" = "None" ]; then
    echo "Creating resource: /$RESOURCE_PATH"
    RESOURCE_ID=$(aws apigateway create-resource \
      --rest-api-id "$API_ID" \
      --parent-id "$PARENT_ID" \
      --path-part "$RESOURCE_PATH" \
      --region "$REGION" \
      --query 'id' --output text)
  fi

  echo "Setting up $HTTP_METHOD /$RESOURCE_PATH (resource: $RESOURCE_ID)"

  # Delete existing method if any
  aws apigateway delete-method \
    --rest-api-id "$API_ID" \
    --resource-id "$RESOURCE_ID" \
    --http-method "$HTTP_METHOD" \
    --region "$REGION" 2>/dev/null || true

  # Create method
  aws apigateway put-method \
    --rest-api-id "$API_ID" \
    --resource-id "$RESOURCE_ID" \
    --http-method "$HTTP_METHOD" \
    --authorization-type NONE \
    --region "$REGION"

  # Create integration
  aws apigateway put-integration \
    --rest-api-id "$API_ID" \
    --resource-id "$RESOURCE_ID" \
    --http-method "$HTTP_METHOD" \
    --type AWS_PROXY \
    --integration-http-method POST \
    --uri "arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations" \
    --region "$REGION"

  echo "  $HTTP_METHOD /$RESOURCE_PATH configured."
}

# GET / (root)
echo "Setting up GET / (root)"
aws apigateway delete-method \
  --rest-api-id "$API_ID" \
  --resource-id "$ROOT_ID" \
  --http-method GET \
  --region "$REGION" 2>/dev/null || true

aws apigateway put-method \
  --rest-api-id "$API_ID" \
  --resource-id "$ROOT_ID" \
  --http-method GET \
  --authorization-type NONE \
  --region "$REGION"

aws apigateway put-integration \
  --rest-api-id "$API_ID" \
  --resource-id "$ROOT_ID" \
  --http-method GET \
  --type AWS_PROXY \
  --integration-http-method POST \
  --uri "arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations" \
  --region "$REGION"

# /inventory — POST and GET
create_resource_and_method "inventory" "POST" "$ROOT_ID"
INVENTORY_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id "$API_ID" --region "$REGION" \
  --query "items[?path=='/inventory'].id" --output text)
create_resource_and_method "inventory" "GET" "$ROOT_ID"

# /transfer — POST
create_resource_and_method "transfer" "POST" "$ROOT_ID"

# /transfers — GET
create_resource_and_method "transfers" "GET" "$ROOT_ID"

# ─── 5. Deploy API ──────────────────────────────────────────────────────────

echo ""
echo "=== Deploying API ==="

aws apigateway create-deployment \
  --rest-api-id "$API_ID" \
  --stage-name "$STAGE_NAME" \
  --region "$REGION"

# ─── 6. Add Lambda Permission ───────────────────────────────────────────────

echo ""
echo "=== Adding Lambda Permissions ==="

aws lambda remove-permission \
  --function-name "$FUNCTION_NAME" \
  --statement-id apigateway-invoke \
  --region "$REGION" 2>/dev/null || true

aws lambda add-permission \
  --function-name "$FUNCTION_NAME" \
  --statement-id apigateway-invoke \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*" \
  --region "$REGION"

# ─── Done ────────────────────────────────────────────────────────────────────

API_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com/${STAGE_NAME}"

echo ""
echo "============================================"
echo "  Deployment Complete!"
echo "============================================"
echo ""
echo "API URL: $API_URL"
echo ""
echo "Endpoints:"
echo "  GET  $API_URL/"
echo "  POST $API_URL/inventory"
echo "  GET  $API_URL/inventory"
echo "  POST $API_URL/transfer"
echo "  GET  $API_URL/transfers"
echo ""
echo "Test with:"
echo "  curl $API_URL/"
echo ""
