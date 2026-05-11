const express = require('express');
const app = express();
app.use(express.json());

const PORT = process.env.PORT || 3000;

// In-memory inventory store (on-premise style)
const inventory = [];
const transferLog = [];

// Health check
app.get('/', (req, res) => {
  res.json({
    status: 'ok',
    message: 'Factory Inventory Service is running (on-premise)',
    version: '1.0.0'
  });
});

// Register or update a part in inventory
// Expected body: { partId, partName, factoryId, quantity, unit, minimumStock }
app.post('/inventory', (req, res) => {
  const { partId, partName, factoryId, quantity, unit, minimumStock } = req.body;

  if (!partId || !partName || !factoryId || quantity === undefined) {
    return res.status(400).json({
      error: 'partId, partName, factoryId, and quantity are required'
    });
  }

  const existing = inventory.find(i => i.partId === partId && i.factoryId === factoryId);

  if (existing) {
    existing.quantity = quantity;
    existing.updatedAt = new Date().toISOString();
    return res.json({ success: true, action: 'updated', item: existing });
  }

  const item = {
    id: inventory.length + 1,
    partId,
    partName,
    factoryId,
    quantity,
    unit: unit || 'pcs',
    minimumStock: minimumStock || 0,
    isLowStock: quantity <= (minimumStock || 0),
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
  };

  inventory.push(item);
  console.log(`[INVENTORY] Registered: ${partName} (${partId}) at ${factoryId} — qty: ${quantity}`);

  res.json({ success: true, action: 'created', item });
});

// Get inventory (optionally filter by factoryId or lowStock)
app.get('/inventory', (req, res) => {
  const { factoryId, lowStock } = req.query;

  let results = [...inventory];

  if (factoryId) {
    results = results.filter(i => i.factoryId === factoryId);
  }
  if (lowStock === 'true') {
    results = results.filter(i => i.isLowStock);
  }

  res.json({ total: results.length, inventory: results });
});

// Transfer parts between factories
// Expected body: { partId, fromFactoryId, toFactoryId, quantity }
app.post('/transfer', (req, res) => {
  const { partId, fromFactoryId, toFactoryId, quantity } = req.body;

  if (!partId || !fromFactoryId || !toFactoryId || !quantity) {
    return res.status(400).json({
      error: 'partId, fromFactoryId, toFactoryId, and quantity are required'
    });
  }

  const source = inventory.find(i => i.partId === partId && i.factoryId === fromFactoryId);

  if (!source) {
    return res.status(404).json({ error: `Part ${partId} not found at ${fromFactoryId}` });
  }

  if (source.quantity < quantity) {
    return res.status(400).json({
      error: `Insufficient stock. Available: ${source.quantity}, Requested: ${quantity}`
    });
  }

  // Deduct from source
  source.quantity -= quantity;
  source.isLowStock = source.quantity <= source.minimumStock;
  source.updatedAt = new Date().toISOString();

  // Add to destination
  let destination = inventory.find(i => i.partId === partId && i.factoryId === toFactoryId);
  if (destination) {
    destination.quantity += quantity;
    destination.isLowStock = destination.quantity <= destination.minimumStock;
    destination.updatedAt = new Date().toISOString();
  } else {
    destination = {
      id: inventory.length + 1,
      partId,
      partName: source.partName,
      factoryId: toFactoryId,
      quantity,
      unit: source.unit,
      minimumStock: source.minimumStock,
      isLowStock: quantity <= source.minimumStock,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };
    inventory.push(destination);
  }

  const transfer = {
    id: transferLog.length + 1,
    partId,
    partName: source.partName,
    fromFactoryId,
    toFactoryId,
    quantity,
    transferredAt: new Date().toISOString(),
  };

  transferLog.push(transfer);
  console.log(`[TRANSFER] ${source.partName} x${quantity} from ${fromFactoryId} to ${toFactoryId}`);

  res.json({ success: true, transfer, source, destination });
});

// Get transfer history
app.get('/transfers', (req, res) => {
  const { partId, factoryId } = req.query;

  let results = [...transferLog];

  if (partId) results = results.filter(t => t.partId === partId);
  if (factoryId) results = results.filter(t => t.fromFactoryId === factoryId || t.toFactoryId === factoryId);

  res.json({ total: results.length, transfers: results });
});

// Start server (on-premise style - always running)
app.listen(PORT, () => {
  console.log(`Factory Inventory Service running on port ${PORT}`);
});

module.exports = app;
