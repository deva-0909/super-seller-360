# Scanning goods in: how it works

## Two places to receive goods
1. **Against a purchase order**: open the order (Purchase Orders → the order) → "Receive goods: scan each item".
2. **Without an order** (walk-in purchase, free goods, sample, supplier replacement): Inventory → **Stock in (scan)**.

## Scanning
- **USB / Bluetooth scanner**: click the scan box (it turns green) and scan. The scanner types the code and presses Enter by itself. Each scan adds 1.
- **Phone camera**: tap "Use phone camera", point at the barcode or QR code. Each read counts once. For hundreds of items a hardware scanner is much faster.
- Sounds: high short beep = counted, medium beep = counted with a warning, low buzz = refused.
- "Each scan adds" lets you count in bulk, for example 12 when you scan the code on a carton of 12.
- **Good / Damaged**: switch the mode before scanning damaged pieces. Only good pieces enter stock.
- **Undo last scan** takes back the most recent scan.
- Your scans are kept on the device if the page is closed by mistake; "Clear all" throws them away.

## First time a code is seen
If a supplier's own barcode or a carton code is not known, the screen asks "Which product is it?". Choose the product once; the code is remembered for everyone from then on. A carton code can carry a pack size (pieces in the pack).

## Items that are not on the order
Scanning an item that is not on the purchase order puts it under **Not on the order**. Each such line needs a reason (supplier sent extra, substituted, free goods, wrong item, other). It is added to stock as a separate, linked stock-in, so the order itself stays accurate. More than 10% over an ordered quantity is refused.

## Lots / batches
Tick **Lot / batch tracked** on the product (Admin → Products). From then on a lot number is required whenever that product is received: type it in the Lot box before scanning. Other products ignore the Lot box.

## 100 or more items at once
Stock in → "Add many at once". Paste a list (one item per line: `barcode, quantity, lot`; quantity and lot are optional, a line with only a code counts as 1) or upload a CSV. Unknown codes are listed so you can link them, then everything is posted in one go (up to 1,000 lines per stock-in).

## Who did it
Everyone logs in with their own name. Every stock change records who, when, which warehouse and the quantity before and after. A warehouse person can only receive into the warehouse they are assigned to.

## Barcodes are unique
A barcode can belong to only one product. The product form now refuses a barcode that is already used.
