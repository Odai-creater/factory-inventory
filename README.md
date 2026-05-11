# Factory Inventory Service (On-Premise)

A factory parts inventory management service currently running on-premise.
This service will be migrated to AWS Lambda as part of the Devin demo.

## Overview

This service manages parts inventory across multiple factory locations.
It tracks stock levels, triggers low-stock alerts, and handles inter-factory part transfers.

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Health check |
| POST | `/inventory` | Register or update a part in inventory |
| GET | `/inventory` | Get inventory (filter by factory or low stock) |
| POST | `/transfer` | Transfer parts between factories |
| GET | `/transfers` | Get transfer history |

## Request Examples

### Register a part
```bash
curl -X POST http://localhost:3000/inventory \
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
curl "http://localhost:3000/inventory?factoryId=FACTORY-TAKAOKA&lowStock=true"
```

### Transfer parts between factories
```bash
curl -X POST http://localhost:3000/transfer \
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
curl "http://localhost:3000/transfers?factoryId=FACTORY-TAKAOKA"
```

## Current Issues (On-Premise)

- Server must run 24/7 across all factory locations — high energy and maintenance cost
- No real-time visibility across factories — data is siloed per location
- Cannot handle sudden spikes in transfer requests (e.g. emergency line restocking)
- Single point of failure — server outage means inventory data is inaccessible
- Inventory data is lost on server restart (in-memory storage)
- Manual synchronization required between factory servers

## Migration Goal

Migrate to AWS Lambda + DynamoDB to achieve:

- **Unified visibility**: All factories share a single real-time inventory view
- **Pay-per-use**: Zero cost during off-shift hours
- **Auto-scaling**: Instantly handles burst requests during emergency restocking
- **Durability**: Inventory data persisted in DynamoDB — never lost
- **High availability**: 99.95% SLA across all factory locations
- **Zero ops burden**: No per-factory server management required
