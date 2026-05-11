import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import {
  DynamoDBDocumentClient,
  PutCommand,
  QueryCommand,
  ScanCommand,
  GetCommand,
  UpdateCommand,
} from "@aws-sdk/lib-dynamodb";
import { randomUUID } from "crypto";

const client = new DynamoDBClient({ region: process.env.AWS_REGION || "ap-northeast-1" });
const ddb = DynamoDBDocumentClient.from(client);

const INVENTORY_TABLE = process.env.INVENTORY_TABLE || "FactoryInventory";
const TRANSFERS_TABLE = process.env.TRANSFERS_TABLE || "FactoryTransfers";

function response(statusCode, body) {
  return {
    statusCode,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  };
}

// GET /
function handleHealthCheck() {
  return response(200, {
    status: "ok",
    message: "Factory Inventory Service is running (AWS Lambda)",
    version: "2.0.0",
  });
}

// POST /inventory
async function handlePostInventory(body) {
  const { partId, partName, factoryId, quantity, unit, minimumStock } = body;

  if (!partId || !partName || !factoryId || quantity === undefined) {
    return response(400, {
      error: "partId, partName, factoryId, and quantity are required",
    });
  }

  const existing = await ddb.send(
    new GetCommand({
      TableName: INVENTORY_TABLE,
      Key: { partId, factoryId },
    })
  );

  const now = new Date().toISOString();

  if (existing.Item) {
    await ddb.send(
      new UpdateCommand({
        TableName: INVENTORY_TABLE,
        Key: { partId, factoryId },
        UpdateExpression: "SET quantity = :qty, isLowStock = :low, updatedAt = :now",
        ExpressionAttributeValues: {
          ":qty": quantity,
          ":low": quantity <= (existing.Item.minimumStock || 0),
          ":now": now,
        },
        ReturnValues: "ALL_NEW",
      })
    );
    const updated = { ...existing.Item, quantity, updatedAt: now, isLowStock: quantity <= (existing.Item.minimumStock || 0) };
    return response(200, { success: true, action: "updated", item: updated });
  }

  const item = {
    partId,
    partName,
    factoryId,
    quantity,
    unit: unit || "pcs",
    minimumStock: minimumStock || 0,
    isLowStock: quantity <= (minimumStock || 0),
    createdAt: now,
    updatedAt: now,
  };

  await ddb.send(new PutCommand({ TableName: INVENTORY_TABLE, Item: item }));

  return response(200, { success: true, action: "created", item });
}

// GET /inventory
async function handleGetInventory(queryParams) {
  const { factoryId, lowStock } = queryParams || {};

  let results;

  if (factoryId) {
    const data = await ddb.send(
      new QueryCommand({
        TableName: INVENTORY_TABLE,
        IndexName: "factoryId-index",
        KeyConditionExpression: "factoryId = :fid",
        ExpressionAttributeValues: { ":fid": factoryId },
      })
    );
    results = data.Items || [];
  } else {
    const data = await ddb.send(new ScanCommand({ TableName: INVENTORY_TABLE }));
    results = data.Items || [];
  }

  if (lowStock === "true") {
    results = results.filter((i) => i.isLowStock);
  }

  return response(200, { total: results.length, inventory: results });
}

// POST /transfer
async function handlePostTransfer(body) {
  const { partId, fromFactoryId, toFactoryId, quantity } = body;

  if (!partId || !fromFactoryId || !toFactoryId || !quantity) {
    return response(400, {
      error: "partId, fromFactoryId, toFactoryId, and quantity are required",
    });
  }

  const sourceResult = await ddb.send(
    new GetCommand({
      TableName: INVENTORY_TABLE,
      Key: { partId, factoryId: fromFactoryId },
    })
  );

  const source = sourceResult.Item;
  if (!source) {
    return response(404, { error: `Part ${partId} not found at ${fromFactoryId}` });
  }

  if (source.quantity < quantity) {
    return response(400, {
      error: `Insufficient stock. Available: ${source.quantity}, Requested: ${quantity}`,
    });
  }

  const now = new Date().toISOString();

  // Deduct from source
  const newSourceQty = source.quantity - quantity;
  await ddb.send(
    new UpdateCommand({
      TableName: INVENTORY_TABLE,
      Key: { partId, factoryId: fromFactoryId },
      UpdateExpression: "SET quantity = :qty, isLowStock = :low, updatedAt = :now",
      ExpressionAttributeValues: {
        ":qty": newSourceQty,
        ":low": newSourceQty <= (source.minimumStock || 0),
        ":now": now,
      },
    })
  );

  const updatedSource = {
    ...source,
    quantity: newSourceQty,
    isLowStock: newSourceQty <= (source.minimumStock || 0),
    updatedAt: now,
  };

  // Add to destination
  const destResult = await ddb.send(
    new GetCommand({
      TableName: INVENTORY_TABLE,
      Key: { partId, factoryId: toFactoryId },
    })
  );

  let destination;
  if (destResult.Item) {
    const newDestQty = destResult.Item.quantity + quantity;
    await ddb.send(
      new UpdateCommand({
        TableName: INVENTORY_TABLE,
        Key: { partId, factoryId: toFactoryId },
        UpdateExpression: "SET quantity = :qty, isLowStock = :low, updatedAt = :now",
        ExpressionAttributeValues: {
          ":qty": newDestQty,
          ":low": newDestQty <= (destResult.Item.minimumStock || 0),
          ":now": now,
        },
      })
    );
    destination = {
      ...destResult.Item,
      quantity: newDestQty,
      isLowStock: newDestQty <= (destResult.Item.minimumStock || 0),
      updatedAt: now,
    };
  } else {
    destination = {
      partId,
      partName: source.partName,
      factoryId: toFactoryId,
      quantity,
      unit: source.unit,
      minimumStock: source.minimumStock,
      isLowStock: quantity <= (source.minimumStock || 0),
      createdAt: now,
      updatedAt: now,
    };
    await ddb.send(new PutCommand({ TableName: INVENTORY_TABLE, Item: destination }));
  }

  // Record transfer
  const transfer = {
    transferId: randomUUID(),
    partId,
    partName: source.partName,
    fromFactoryId,
    toFactoryId,
    quantity,
    transferredAt: now,
  };

  await ddb.send(new PutCommand({ TableName: TRANSFERS_TABLE, Item: transfer }));

  return response(200, { success: true, transfer, source: updatedSource, destination });
}

// GET /transfers
async function handleGetTransfers(queryParams) {
  const { partId, factoryId } = queryParams || {};

  let results;

  if (partId) {
    const data = await ddb.send(
      new QueryCommand({
        TableName: TRANSFERS_TABLE,
        IndexName: "partId-index",
        KeyConditionExpression: "partId = :pid",
        ExpressionAttributeValues: { ":pid": partId },
      })
    );
    results = data.Items || [];
  } else {
    const data = await ddb.send(new ScanCommand({ TableName: TRANSFERS_TABLE }));
    results = data.Items || [];
  }

  if (factoryId) {
    results = results.filter(
      (t) => t.fromFactoryId === factoryId || t.toFactoryId === factoryId
    );
  }

  return response(200, { total: results.length, transfers: results });
}

export const handler = async (event) => {
  const method = event.httpMethod || event.requestContext?.http?.method;
  const path = event.path || event.rawPath;
  const queryParams = event.queryStringParameters || {};
  let body = {};

  if (event.body) {
    try {
      body = JSON.parse(event.isBase64Encoded ? Buffer.from(event.body, "base64").toString() : event.body);
    } catch {
      return response(400, { error: "Invalid JSON body" });
    }
  }

  try {
    if (path === "/" && method === "GET") {
      return handleHealthCheck();
    }
    if (path === "/inventory" && method === "POST") {
      return await handlePostInventory(body);
    }
    if (path === "/inventory" && method === "GET") {
      return await handleGetInventory(queryParams);
    }
    if (path === "/transfer" && method === "POST") {
      return await handlePostTransfer(body);
    }
    if (path === "/transfers" && method === "GET") {
      return await handleGetTransfers(queryParams);
    }

    return response(404, { error: `Not found: ${method} ${path}` });
  } catch (err) {
    console.error("Handler error:", err);
    return response(500, { error: "Internal server error", details: err.message });
  }
};
