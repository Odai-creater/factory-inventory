# Factory Inventory Service (AWS Lambda)

A factory parts inventory management service running on AWS Lambda + API Gateway + DynamoDB.

## Architecture

- **AWS Lambda** — Serverless compute (Node.js 20.x)
- **API Gateway** — REST API with regional endpoint
- **DynamoDB** — Persistent storage for inventory and transfer records
- **Region** — ap-northeast-1 (Tokyo)

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Health check |
| POST | `/inventory` | Register or update a part in inventory |
| GET | `/inventory` | Get inventory (filter by factory or low stock) |
| POST | `/transfer` | Transfer parts between factories |
| GET | `/transfers` | Get transfer history |

## DynamoDB Tables

### FactoryInventory
- **Partition Key**: `partId` (String)
- **Sort Key**: `factoryId` (String)
- **GSI**: `factoryId-index` (partition key: `factoryId`)

### FactoryTransfers
- **Partition Key**: `transferId` (String)
- **GSI**: `partId-index` (partition key: `partId`)

## Deployment

### Prerequisites
- AWS CLI configured with appropriate credentials
- Target region: `ap-northeast-1`

### Deploy
```bash
chmod +x deploy.sh
./deploy.sh
```

The script will:
1. Create DynamoDB tables (FactoryInventory, FactoryTransfers)
2. Create an IAM role with least-privilege permissions
3. Package and deploy the Lambda function
4. Create and configure API Gateway with all routes
5. Output the API URL

## Request Examples

### Health check
```bash
curl https://<api-id>.execute-api.ap-northeast-1.amazonaws.com/prod/
```

### Register a part
```bash
curl -X POST https://<api-id>.execute-api.ap-northeast-1.amazonaws.com/prod/inventory \
  -H "Content-Type: application/json" \
  -d '{
    "partId": "PART-ENG-001",
    "partName": "Engine Bolt M12",
    "factoryId": "FACTORY-TAKAOKA",
    "quantity": 500,
    "unit": "pcs",
    "minimumStock": 100
  }'
```

### Get low stock items at a factory
```bash
curl "https://<api-id>.execute-api.ap-northeast-1.amazonaws.com/prod/inventory?factoryId=FACTORY-TAKAOKA&lowStock=true"
```

### Transfer parts between factories
```bash
curl -X POST https://<api-id>.execute-api.ap-northeast-1.amazonaws.com/prod/transfer \
  -H "Content-Type: application/json" \
  -d '{
    "partId": "PART-ENG-001",
    "fromFactoryId": "FACTORY-TAKAOKA",
    "toFactoryId": "FACTORY-TSUTSUMI",
    "quantity": 100
  }'
```

### Get transfer history
```bash
curl "https://<api-id>.execute-api.ap-northeast-1.amazonaws.com/prod/transfers?factoryId=FACTORY-TAKAOKA"
```

## Benefits Over On-Premise

- **Unified visibility**: All factories share a single real-time inventory view
- **Pay-per-use**: Zero cost during off-shift hours
- **Auto-scaling**: Instantly handles burst requests during emergency restocking
- **Durability**: Inventory data persisted in DynamoDB — never lost
- **High availability**: 99.95% SLA across all factory locations
- **Zero ops burden**: No per-factory server management required

## Project Structure

```
├── app.js              # Original Express app (kept for reference)
├── lambda/
│   └── index.mjs       # AWS Lambda handler
├── deploy.sh           # Deployment script
├── package.json        # Project metadata
└── README.md           # This file
```
