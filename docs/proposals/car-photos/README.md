# Arrival car photos + car AI — proposal (2026-11-18)

Status: prototype on a local branch. Nothing deployed, no migration applied.

## What is built (index.html, off by default)
- `?photos=1` on a device turns on a **Photos** section in New check-in (after the ticket exists),
  above Vehicle: Driver side · Front · Passenger side · Rear · Close-up.
- Each photo is resized to 1600 px JPEG (q 0.7, ~250 KB), the canvas drops EXIF/GPS, a SHA-256
  fingerprint is taken, and the photo is kept in this device's IndexedDB (`airvalet-photos`). No upload.
- `?photos=demo` also shows a sample AI answer ("Fill car from photos") so the confirm step can be seen.
  "Looks right" fills make/model/color through the normal Vehicle chips.
- `?photos=0` turns it off again.

## What is drafted (not wired)
- `schema_draft.sql`: private bucket `car-photos`, table `airvalet_car_photos` (server time, who, hash,
  hold for complaints, delete 30 days after delivery), `passengers.plate`, AI log `airvalet_vehicle_ai`.
- `vehicle-ai/index.ts`: Edge Function on the AirValet Anthropic key (Matt Solutions), same auth and
  daily cap as `manifest-scan`; returns make, model, color, plate, marks with confidences.

## Numbers (research_photos_ai.md in iCloud DESIGN_DIA_A_DIA_2026-11-18)
- Storage: ~1 MB per car. 10 cars/day, kept 30 days after delivery ≈ 0.35 GB → inside the plan, $0.
- AI: about 1–3 cents per car (4 photos at 1024 px). ~$3–8 per month at 10 cars/day.
- Plate reading: a suggestion staff confirm (research: 86% full-plate accuracy on hard plates).
- Damage: the AI misses small scratches (studies ~55–63%). The photo is the proof, not the AI.

## To ship (owner decisions)
1. OK to store photos (30 days after delivery; hold when a guest complains).
2. OK to store the plate.
3. AI on or off; test on 30 real cars first.
4. Then: real migration number + rollback, upload in the app, delivery photos, cleanup job.
