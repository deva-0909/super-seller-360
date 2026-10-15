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

## Our own barcode and QR on every product (Round 26)
- Every product has one code of our own, made by the system (a valid EAN-13 starting with 20, the range reserved for in-store use). It never changes, and it cannot clash with a supplier's or marketplace barcode.
- Inventory -> Product Labels: search or filter ("Never printed"), type how many labels each product needs, choose the label size (50 x 25 mm roll, 70 x 35 mm roll, or an A4 sheet of 3 x 8), press Print. Each label carries the name, SKU, size, colour, the barcode and a QR of the same number.
- The supplier's barcode stays linked to the same product ("Linked codes" on each row: add by typing or scanning, mark a carton code with its piece count, remove a wrong one). Scanning the supplier's label or ours finds the same product everywhere: receiving, stock-in, transfers.
- Suggested routine on arrival: scan the supplier's barcode; if the goods carry no label of ours, print and stick ours. After that, scan whichever is easier.
- One label per product variant (SKU, size and colour). Labels for each individual piece (unique serial per unit) are not part of this.

## Barcodes and QR codes are generated inside the app (Round 27)
- Labels are drawn by our own code (`apps/web/lib/codes/ean13.ts`, `qr.ts`). No outside package, website or service is used, so nothing can be switched off, change price or expire.
- Our code is a fixed 13-digit number stored against the product (`products.internal_code`). The barcode and QR are only a picture of that number, so a label printed today scans the same years later.
- Checked by decoding the generated images with an independent reader: all EAN-13 barcodes read correctly; QR codes read correctly in nearly all cases. Always print one test label and scan it with your real scanner and a phone before printing a full roll.

## A unique serial on every piece (Round 28, migration 0111)
- **When a serial is made:** the moment goods are received (against an order or by direct stock-in). One serial per piece, a 13-digit barcode starting 21. Inventory -> Piece Labels & Tracking lists the labels waiting to print, grouped by receipt. Print them and stick one on every piece. After printing, they leave the list.
- **Life of a piece:** in stock -> in transit (store transfer) -> in stock at the other store; in stock -> packed -> sold; sold -> back in stock after a customer return or RTO is restocked; in stock -> returned to supplier; or written off. Every step is saved with who, when and which document. Look any piece up by scanning it (Find a piece).
- **Store transfers:** scan the pieces on dispatch and again on arrival. Pieces not scanned at the other end count as the shortfall, and the manager's settlement brings them back or writes them off.
- **Return to supplier:** scan the pieces going back on the order page.
- **Selling:** Inventory -> Pack an Order. Find the order, scan each piece in the parcel. When the order ships, those pieces become sold. A sold piece cannot be packed again.
- **Marketplace orders are never blocked.** If an order ships without its pieces scanned, stock still goes down, the order appears under "Needs attention", and you clear it by scanning the pieces that left.
- **Old stock** (received before this round) has no serials and keeps working by quantity. While a store holds labelled pieces, those cannot be sent or returned to a supplier by counting; they must be scanned. This stops labelled stock silently disappearing.
- **Written off:** a manager can write off a lost labelled piece; stock goes down by one.
- Switch off with `purchase_settings.serial_tracking = false` if ever needed (new receipts then make no serials).
