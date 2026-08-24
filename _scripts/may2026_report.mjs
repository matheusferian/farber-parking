import { writeFileSync } from 'fs';
import { mkdirSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

// ── CONFIG ─────────────────────────────────────────────────────
const SUPABASE_URL = 'https://sfewtirvqhrpanwhbchd.supabase.co';
const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNmZXd0aXJ2cWhycGFud2hiY2hkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkyNzExMjcsImV4cCI6MjA5NDg0NzEyN30.UFf22k7Zn7v72IPujuF1YRrK6PPbp8K_uz6TkYlhOl8';
const TABLE = 'passengers';
const OUT_DIR = '/Users/matheusferian/Documents/FARBERMAKERS';

const WEEKDAYS = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];

// ── FETCH ALL RECORDS ──────────────────────────────────────────
async function fetchAll() {
  let all = [];
  let offset = 0;
  const limit = 1000;
  while (true) {
    const url = `${SUPABASE_URL}/rest/v1/${TABLE}?select=id,ts,deldate,name,ticket,status&limit=${limit}&offset=${offset}`;
    const res = await fetch(url, {
      headers: {
        'apikey': SUPABASE_KEY,
        'Authorization': 'Bearer ' + SUPABASE_KEY,
        'Accept': 'application/json'
      }
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}: ${await res.text()}`);
    const batch = await res.json();
    all = all.concat(batch);
    if (batch.length < limit) break;
    offset += limit;
  }
  return all;
}

// ── DATE PARSING ───────────────────────────────────────────────
// Handles M/D/YYYY, MM/DD/YYYY, YYYY-MM-DD
function parseDate(str) {
  if (!str || !str.trim()) return null;
  str = str.trim();
  // ISO format
  if (/^\d{4}-\d{2}-\d{2}/.test(str)) {
    const [y,m,d] = str.split('T')[0].split('-').map(Number);
    if (!y || !m || !d) return null;
    return new Date(y, m - 1, d);
  }
  // M/D/YYYY or MM/DD/YYYY
  const parts = str.split('/');
  if (parts.length === 3) {
    const [m, d, y] = parts.map(Number);
    if (!m || !d || !y || y < 2000 || y > 2099) return null;
    return new Date(y, m - 1, d);
  }
  return null;
}

function isMay2026(date) {
  return date && date.getFullYear() === 2026 && date.getMonth() === 4; // month 4 = May
}

// ── MAIN ───────────────────────────────────────────────────────
(async () => {
  console.log('Fetching records from Supabase...');
  const records = await fetchAll();
  console.log(`\n✔ Total records loaded: ${records.length}`);

  // ── VALIDATION ────────────────────────────────────────────────
  let validArrMay = 0, validDelMay = 0;
  let ignoredTs = 0, ignoredDel = 0;

  const processed = records.map(r => {
    const arrDate  = parseDate(r.ts);
    const delDate  = parseDate(r.deldate);

    const arrInMay = arrDate && isMay2026(arrDate);
    const delInMay = delDate && isMay2026(delDate);

    if (!r.ts || !r.ts.trim() || !arrDate) ignoredTs++;
    if (arrInMay) validArrMay++;

    if (!r.deldate || !r.deldate.trim() || !delDate) ignoredDel++;
    if (delInMay) validDelMay++;

    return { ...r, arrDate, delDate, arrInMay, delInMay };
  });

  console.log(`   Records with valid May 2026 arrivals:   ${validArrMay}`);
  console.log(`   Records with valid May 2026 deliveries: ${validDelMay}`);
  console.log(`   Records ignored (missing/invalid ts):   ${ignoredTs}`);
  console.log(`   Records ignored (missing/invalid deldate): ${ignoredDel - (records.length - validDelMay - (ignoredDel - records.filter(r => r.deldate && r.deldate.trim() && parseDate(r.deldate)).length))}`);

  // ── BUILD DAILY TABLE (May 1–31) ───────────────────────────────
  const dailyMap = {};
  for (let d = 1; d <= 31; d++) {
    const date = new Date(2026, 4, d);
    const key = `2026-05-${String(d).padStart(2,'0')}`;
    dailyMap[key] = {
      date: `${d} May 2026`,
      dateKey: key,
      weekday: WEEKDAYS[date.getDay()],
      dayOfWeek: date.getDay(),
      arrivals: 0,
      deliveries: 0
    };
  }

  for (const r of processed) {
    if (r.arrInMay) {
      const key = `2026-05-${String(r.arrDate.getDate()).padStart(2,'0')}`;
      if (dailyMap[key]) dailyMap[key].arrivals++;
    }
    if (r.delInMay) {
      const key = `2026-05-${String(r.delDate.getDate()).padStart(2,'0')}`;
      if (dailyMap[key]) dailyMap[key].deliveries++;
    }
  }

  const days = Object.values(dailyMap);

  // ── WEEKDAY AVERAGES ───────────────────────────────────────────
  // Count how many of each weekday exist in May 2026
  const wdCount     = Array(7).fill(0);
  const wdArrivals  = Array(7).fill(0);
  const wdDeliveries= Array(7).fill(0);

  for (const day of days) {
    wdCount[day.dayOfWeek]++;
    wdArrivals[day.dayOfWeek]  += day.arrivals;
    wdDeliveries[day.dayOfWeek]+= day.deliveries;
  }

  const wdAvgArr = wdCount.map((cnt, i) => cnt ? +(wdArrivals[i] / cnt).toFixed(1) : 0);
  const wdAvgDel = wdCount.map((cnt, i) => cnt ? +(wdDeliveries[i] / cnt).toFixed(1) : 0);

  // ── TOTALS ─────────────────────────────────────────────────────
  const totalArrMay = validArrMay;
  const totalDelMay = validDelMay;
  const avgDailyArr = +(totalArrMay / 31).toFixed(1);
  const avgDailyDel = +(totalDelMay / 31).toFixed(1);

  // ── TOP 5 ──────────────────────────────────────────────────────
  const top5Arr = [...days].sort((a,b) => b.arrivals   - a.arrivals).slice(0,5);
  const top5Del = [...days].sort((a,b) => b.deliveries - a.deliveries).slice(0,5);
  const top5Cmb = [...days].sort((a,b) => (b.arrivals+b.deliveries) - (a.arrivals+a.deliveries)).slice(0,5);

  // ── INSIGHTS ──────────────────────────────────────────────────
  const busiestArrWD  = WEEKDAYS[wdAvgArr.indexOf(Math.max(...wdAvgArr))];
  const busiestDelWD  = WEEKDAYS[wdAvgDel.indexOf(Math.max(...wdAvgDel))];
  const busiestDay    = [...days].sort((a,b) => (b.arrivals+b.deliveries)-(a.arrivals+a.deliveries))[0];

  // spread check: std dev of daily arrivals
  const mean = totalArrMay / 31;
  const variance = days.reduce((s,d) => s + Math.pow(d.arrivals - mean, 2), 0) / 31;
  const stdDev = +Math.sqrt(variance).toFixed(1);
  const spreadNote = stdDev > mean * 0.8
    ? 'Traffic is notably concentrated on specific days.'
    : 'Traffic is relatively spread evenly across the month.';

  // ── FORMAT HELPERS ─────────────────────────────────────────────
  const topRows = (arr) => arr.map((d,i) =>
    `  ${i+1}. ${d.dateKey} (${d.weekday}) — Arr: ${d.arrivals}, Del: ${d.deliveries}, Combined: ${d.arrivals+d.deliveries}`
  ).join('\n');

  const wdTableRows = WEEKDAYS.map((wd, i) =>
    `| ${wd.padEnd(9)} | ${String(wdCount[i]).padStart(2)} | ${String(wdArrivals[i]).padStart(9)} | ${String(wdAvgArr[i].toFixed(1)).padStart(8)} | ${String(wdDeliveries[i]).padStart(12)} | ${String(wdAvgDel[i].toFixed(1)).padStart(11)} |`
  ).join('\n');

  const dailyTableRows = days.map(d =>
    `| ${d.dateKey} | ${d.weekday.padEnd(9)} | ${String(d.arrivals).padStart(8)} | ${String(d.deliveries).padStart(12)} | ${String(d.arrivals+d.deliveries).padStart(8)} |`
  ).join('\n');

  // ── MARKDOWN REPORT ───────────────────────────────────────────
  const md = `# Makers Air Valet — Monthly Operations Report
## May 2026

_Generated: ${new Date().toLocaleString('en-US')}_

---

## 1. Monthly Totals

| Metric                     | Count |
|----------------------------|-------|
| Vehicles arrived in May    | ${totalArrMay} |
| Vehicles delivered in May  | ${totalDelMay} |
| Average daily arrivals     | ${avgDailyArr} |
| Average daily deliveries   | ${avgDailyDel} |

---

## 2. Average Arrivals & Deliveries by Weekday

| Weekday   | # Wks | Total Arr | Avg Arr | Total Del | Avg Del |
|-----------|-------|-----------|---------|-----------|---------|
${wdTableRows}

---

## 3. Daily Operations (May 1–31)

| Date       | Weekday   | Arrivals | Deliveries | Combined |
|------------|-----------|----------|------------|----------|
${dailyTableRows}

---

## 4. Busiest Days

### Top 5 Arrival Days
${topRows(top5Arr)}

### Top 5 Delivery Days
${topRows(top5Del)}

### Top 5 Combined Days (Arrivals + Deliveries)
${topRows(top5Cmb)}

---

## 5. Operational Summary

- **Busiest weekday for arrivals:** ${busiestArrWD} (avg ${Math.max(...wdAvgArr).toFixed(1)} arrivals/week)
- **Busiest weekday for deliveries:** ${busiestDelWD} (avg ${Math.max(...wdAvgDel).toFixed(1)} deliveries/week)
- **Busiest individual date:** ${busiestDay.dateKey} (${busiestDay.weekday}) — ${busiestDay.arrivals} arrivals, ${busiestDay.deliveries} deliveries, ${busiestDay.arrivals+busiestDay.deliveries} combined
- **Average daily arrivals:** ${avgDailyArr} vehicles/day
- **Average daily deliveries:** ${avgDailyDel} vehicles/day
- **Daily arrivals std dev:** ${stdDev}
- **Traffic spread:** ${spreadNote}

---

## 6. Validation

| Check                                     | Count |
|-------------------------------------------|-------|
| Total records in database                 | ${records.length} |
| Records with valid May 2026 arrival date  | ${validArrMay} |
| Records with valid May 2026 delivery date | ${validDelMay} |
| Records skipped (missing/invalid ts)      | ${ignoredTs} |
| Records skipped (missing/invalid deldate) | ${ignoredDel} |

---
_Makers Air Valet by Farber Parking — Confidential_
`;

  // ── CSV ───────────────────────────────────────────────────────
  const csvHeader = 'Date,Weekday,Arrivals,Deliveries,Combined\n';
  const csvRows = days.map(d =>
    `${d.dateKey},${d.weekday},${d.arrivals},${d.deliveries},${d.arrivals+d.deliveries}`
  ).join('\n');
  const csv = csvHeader + csvRows + '\n';

  // ── JSON ──────────────────────────────────────────────────────
  const json = JSON.stringify({
    report: 'Makers Air Valet — Monthly Operations Report',
    month: 'May 2026',
    generated: new Date().toISOString(),
    totals: {
      arrivals: totalArrMay,
      deliveries: totalDelMay,
      avgDailyArrivals: avgDailyArr,
      avgDailyDeliveries: avgDailyDel
    },
    weekdayAverages: WEEKDAYS.map((wd, i) => ({
      weekday: wd,
      occurrencesInMonth: wdCount[i],
      totalArrivals: wdArrivals[i],
      avgArrivals: wdAvgArr[i],
      totalDeliveries: wdDeliveries[i],
      avgDeliveries: wdAvgDel[i]
    })),
    daily: days.map(d => ({
      date: d.dateKey,
      weekday: d.weekday,
      arrivals: d.arrivals,
      deliveries: d.deliveries,
      combined: d.arrivals + d.deliveries
    })),
    top5ArrivalDays:   top5Arr.map(d => ({ date: d.dateKey, weekday: d.weekday, arrivals: d.arrivals })),
    top5DeliveryDays:  top5Del.map(d => ({ date: d.dateKey, weekday: d.weekday, deliveries: d.deliveries })),
    top5CombinedDays:  top5Cmb.map(d => ({ date: d.dateKey, weekday: d.weekday, combined: d.arrivals+d.deliveries })),
    insights: {
      busiestArrivalWeekday: busiestArrWD,
      busiestDeliveryWeekday: busiestDelWD,
      busiestDate: busiestDay.dateKey,
      busiestDateWeekday: busiestDay.weekday,
      dailyArrivalStdDev: stdDev,
      spreadNote
    },
    validation: {
      totalRecords: records.length,
      validMayArrivals: validArrMay,
      validMayDeliveries: validDelMay,
      skippedMissingTs: ignoredTs,
      skippedMissingDeldate: ignoredDel
    }
  }, null, 2);

  // ── WRITE FILES ───────────────────────────────────────────────
  writeFileSync(`${OUT_DIR}/may-2026-operations-report.md`,   md,   'utf8');
  writeFileSync(`${OUT_DIR}/may-2026-daily-operations.csv`,   csv,  'utf8');
  writeFileSync(`${OUT_DIR}/may-2026-operations-summary.json`,json, 'utf8');

  console.log('\n✅ Files written:');
  console.log(`   ${OUT_DIR}/may-2026-operations-report.md`);
  console.log(`   ${OUT_DIR}/may-2026-daily-operations.csv`);
  console.log(`   ${OUT_DIR}/may-2026-operations-summary.json`);

  console.log('\n📊 Key numbers:');
  console.log(`   Total arrivals in May:   ${totalArrMay}`);
  console.log(`   Total deliveries in May: ${totalDelMay}`);
  console.log(`   Avg daily arrivals:      ${avgDailyArr}`);
  console.log(`   Avg daily deliveries:    ${avgDailyDel}`);
  console.log(`   Busiest arrival weekday: ${busiestArrWD} (avg ${Math.max(...wdAvgArr).toFixed(1)})`);
  console.log(`   Busiest delivery weekday:${busiestDelWD} (avg ${Math.max(...wdAvgDel).toFixed(1)})`);
  console.log(`   Busiest day:             ${busiestDay.dateKey} (${busiestDay.weekday}) — ${busiestDay.arrivals+busiestDay.deliveries} combined`);
})();
