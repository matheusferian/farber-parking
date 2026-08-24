// ─────────────────────────────────────────────────────────────────────────────
// MAY 2026 OPERATIONS REPORT — Paste this entire block into the browser
// console while the valet app is open and logged in.
//
// Generates:
//   1. A print-ready HTML report (opens in new tab → Save as PDF)
//   2. Auto-downloads: may-2026-daily-operations.csv
//   3. Auto-downloads: may-2026-operations-summary.json
// ─────────────────────────────────────────────────────────────────────────────
(function() {

  // ── 1. PULL DATA FROM RUNNING APP ──────────────────────────────────────────
  if (typeof data === 'undefined' || !Array.isArray(data)) {
    alert('ERROR: The app data array is not loaded. Make sure you are logged in and data has finished loading.');
    return;
  }
  const records = data;

  // ── 2. DATE HELPERS ────────────────────────────────────────────────────────
  function parseDate(str) {
    if (!str || !String(str).trim()) return null;
    str = String(str).trim();
    if (/^\d{4}-\d{2}-\d{2}/.test(str)) {
      const [y,m,d] = str.split('T')[0].split('-').map(Number);
      if (!y||!m||!d) return null;
      return new Date(y, m-1, d);
    }
    const parts = str.split('/');
    if (parts.length === 3) {
      const [m,d,y] = parts.map(Number);
      if (!m||!d||!y||y<2000||y>2099) return null;
      return new Date(y, m-1, d);
    }
    return null;
  }
  const isMay26 = d => d && d.getFullYear()===2026 && d.getMonth()===4;
  const WDAYS   = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];

  // ── 3. PROCESS RECORDS ─────────────────────────────────────────────────────
  let ignoredTs=0, ignoredDel=0, validArr=0, validDel=0;
  const proc = records.map(r => {
    const ad = parseDate(r.ts),     dd = parseDate(r.deldate);
    const ai = ad && isMay26(ad),   di = dd && isMay26(dd);
    if (!ad) ignoredTs++;
    if (!dd) ignoredDel++;
    if (ai) validArr++;
    if (di) validDel++;
    return {...r, ad, dd, ai, di};
  });

  // Validation printout
  console.log('─── May 2026 Report Validation ───────────────────');
  console.log('Total records loaded:         ', records.length);
  console.log('Valid May 2026 arrivals:       ', validArr);
  console.log('Valid May 2026 deliveries:     ', validDel);
  console.log('Skipped (no/bad ts):          ', ignoredTs);
  console.log('Skipped (no/bad deldate):     ', ignoredDel);
  console.log('──────────────────────────────────────────────────');

  // ── 4. BUILD DAILY TABLE ───────────────────────────────────────────────────
  const daily = [];
  for (let d=1; d<=31; d++) {
    const dt = new Date(2026,4,d);
    daily.push({
      dt,
      key: `2026-05-${String(d).padStart(2,'0')}`,
      label: dt.toLocaleDateString('en-US',{month:'short',day:'numeric'}),
      wd: WDAYS[dt.getDay()],
      wdi: dt.getDay(),
      arr: 0, del: 0
    });
  }
  for (const r of proc) {
    if (r.ai) { const i=r.ad.getDate()-1; if(daily[i]) daily[i].arr++; }
    if (r.di) { const i=r.dd.getDate()-1; if(daily[i]) daily[i].del++; }
  }

  // ── 5. WEEKDAY AVERAGES ────────────────────────────────────────────────────
  const wdCnt=[0,0,0,0,0,0,0], wdArr=[0,0,0,0,0,0,0], wdDel=[0,0,0,0,0,0,0];
  for (const d of daily) {
    wdCnt[d.wdi]++; wdArr[d.wdi]+=d.arr; wdDel[d.wdi]+=d.del;
  }
  const wdAvgA = wdCnt.map((c,i)=>c?(wdArr[i]/c):0);
  const wdAvgD = wdCnt.map((c,i)=>c?(wdDel[i]/c):0);

  // ── 6. KEY STATS ───────────────────────────────────────────────────────────
  const avgDailyA = +(validArr/31).toFixed(1);
  const avgDailyD = +(validDel/31).toFixed(1);
  const busiestAWD = WDAYS[wdAvgA.indexOf(Math.max(...wdAvgA))];
  const busiestDWD = WDAYS[wdAvgD.indexOf(Math.max(...wdAvgD))];
  const sorted = [...daily].sort((a,b)=>(b.arr+b.del)-(a.arr+a.del));
  const busiest = sorted[0];

  // Spread analysis
  const mean = validArr/31;
  const stdDev = +Math.sqrt(daily.reduce((s,d)=>s+Math.pow(d.arr-mean,2),0)/31).toFixed(1);
  const cvPct = mean>0 ? +((stdDev/mean)*100).toFixed(0) : 0;
  const spreadNote = cvPct > 60
    ? 'Traffic is notably concentrated on specific days (high variability).'
    : cvPct > 30
    ? 'Traffic shows moderate daily variation with some peak days.'
    : 'Traffic is relatively evenly distributed throughout the month.';

  // ── 7. TOP 5 ───────────────────────────────────────────────────────────────
  const top5A = [...daily].sort((a,b)=>b.arr-a.arr).slice(0,5);
  const top5D = [...daily].sort((a,b)=>b.del-a.del).slice(0,5);
  const top5C = [...daily].sort((a,b)=>(b.arr+b.del)-(a.arr+a.del)).slice(0,5);

  // ── 8. CSV DOWNLOAD ────────────────────────────────────────────────────────
  const csvContent = 'Date,Weekday,Arrivals,Deliveries,Combined\n' +
    daily.map(d=>`${d.key},${d.wd},${d.arr},${d.del},${d.arr+d.del}`).join('\n');
  const csvBlob = new Blob([csvContent], {type:'text/csv'});
  const csvUrl  = URL.createObjectURL(csvBlob);
  const csvLink = document.createElement('a');
  csvLink.href=csvUrl; csvLink.download='may-2026-daily-operations.csv';
  csvLink.click();

  // ── 9. JSON DOWNLOAD ───────────────────────────────────────────────────────
  const jsonObj = {
    report:'Makers Air Valet — May 2026 Operations',
    generated: new Date().toISOString(),
    totals:{ arrivals:validArr, deliveries:validDel, avgDailyArrivals:avgDailyA, avgDailyDeliveries:avgDailyD },
    weekdayAverages: WDAYS.map((w,i)=>({ weekday:w, occurrences:wdCnt[i], totalArrivals:wdArr[i], avgArrivals:+wdAvgA[i].toFixed(1), totalDeliveries:wdDel[i], avgDeliveries:+wdAvgD[i].toFixed(1) })),
    daily: daily.map(d=>({ date:d.key, weekday:d.wd, arrivals:d.arr, deliveries:d.del, combined:d.arr+d.del })),
    top5ArrivalDays:  top5A.map(d=>({ date:d.key, weekday:d.wd, arrivals:d.arr })),
    top5DeliveryDays: top5D.map(d=>({ date:d.key, weekday:d.wd, deliveries:d.del })),
    top5CombinedDays: top5C.map(d=>({ date:d.key, weekday:d.wd, combined:d.arr+d.del })),
    insights:{ busiestArrivalWeekday:busiestAWD, busiestDeliveryWeekday:busiestDWD, busiestDate:busiest.key, spreadNote, coefficientOfVariation:cvPct+'%' },
    validation:{ totalRecords:records.length, validMayArrivals:validArr, validMayDeliveries:validDel, skippedTs:ignoredTs, skippedDeldate:ignoredDel }
  };
  const jsonBlob = new Blob([JSON.stringify(jsonObj,null,2)], {type:'application/json'});
  const jsonLink = document.createElement('a');
  jsonLink.href=URL.createObjectURL(jsonBlob); jsonLink.download='may-2026-operations-summary.json';
  jsonLink.click();

  // ── 10. HTML REPORT (print → PDF) ──────────────────────────────────────────
  const arrData    = daily.map(d=>d.arr);
  const delData    = daily.map(d=>d.del);
  const dayLabels  = daily.map(d=>d.label);
  const wdLabels   = WDAYS.map(w=>w.slice(0,3));
  const wdAvgAR    = WDAYS.map((_,i)=>+wdAvgA[i].toFixed(1));
  const wdAvgDR    = WDAYS.map((_,i)=>+wdAvgD[i].toFixed(1));

  // Top-5 rows helper
  const topRows = (arr, fields) => arr.map((d,i)=>
    `<tr><td>${i+1}</td><td>${d.key}</td><td>${d.wd}</td>${fields.map(f=>`<td>${d[f]}</td>`).join('')}</tr>`
  ).join('');

  // Weekday avg table rows (Mon–Sun ordering)
  const wdOrder = [1,2,3,4,5,6,0]; // Mon first
  const wdTableRows = wdOrder.map(i=>
    `<tr><td>${WDAYS[i]}</td><td>${wdCnt[i]}</td><td>${wdArr[i]}</td><td>${wdAvgA[i].toFixed(1)}</td><td>${wdDel[i]}</td><td>${wdAvgD[i].toFixed(1)}</td></tr>`
  ).join('');

  const dailyRows = daily.map((d,idx)=>
    `<tr class="${idx%2===0?'even':''}"><td>${d.key}</td><td>${d.wd}</td><td>${d.arr}</td><td>${d.del}</td><td>${d.arr+d.del}</td></tr>`
  ).join('');

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Makers Air Valet — May 2026 Operations Report</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"><\/script>
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:'Segoe UI',Arial,sans-serif;background:#f4f6fa;color:#1a1a2e;font-size:13px}
  .page{max-width:1050px;margin:0 auto;padding:32px 28px}
  /* ── HEADER ── */
  .header{display:flex;justify-content:space-between;align-items:flex-start;
    border-bottom:3px solid #1a3d7c;padding-bottom:18px;margin-bottom:26px}
  .header h1{color:#1a3d7c;font-size:20px;font-weight:800;letter-spacing:.5px}
  .header .sub{color:#666;font-size:11px;margin-top:4px}
  .badge-title{background:#1a3d7c;color:#fff;padding:8px 16px;border-radius:6px;
    font-size:12px;font-weight:700;text-align:right}
  /* ── SECTION ── */
  .section{margin-bottom:30px}
  .section h2{font-size:14px;font-weight:700;color:#1a3d7c;border-left:4px solid #c9a84c;
    padding-left:10px;margin-bottom:14px;text-transform:uppercase;letter-spacing:.5px}
  /* ── KPI CARDS ── */
  .kpi-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin-bottom:6px}
  .kpi{background:#fff;border:1px solid #e0e6f0;border-radius:10px;padding:14px 16px;text-align:center}
  .kpi .num{font-size:28px;font-weight:800;color:#1a3d7c;line-height:1}
  .kpi .lbl{font-size:10px;color:#888;margin-top:5px;text-transform:uppercase;letter-spacing:.5px}
  .kpi.accent .num{color:#c9a84c}
  /* ── TABLES ── */
  table{width:100%;border-collapse:collapse;font-size:12px;background:#fff;
    border-radius:8px;overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,.06)}
  th{background:#1a3d7c;color:#fff;padding:9px 10px;text-align:left;font-weight:600;font-size:11px}
  td{padding:8px 10px;border-bottom:1px solid #eef1f7}
  tr.even td{background:#f9fafd}
  tr:last-child td{border-bottom:none}
  /* ── CHARTS ── */
  .chart-grid{display:grid;grid-template-columns:1fr 1fr;gap:20px;margin-bottom:6px}
  .chart-wrap{background:#fff;border:1px solid #e0e6f0;border-radius:10px;padding:16px}
  .chart-wrap h3{font-size:11px;font-weight:700;color:#555;margin-bottom:12px;
    text-transform:uppercase;letter-spacing:.5px}
  .chart-full{background:#fff;border:1px solid #e0e6f0;border-radius:10px;padding:16px;margin-bottom:6px}
  .chart-full h3{font-size:11px;font-weight:700;color:#555;margin-bottom:12px;
    text-transform:uppercase;letter-spacing:.5px}
  /* ── TOP-5 TABLES SIDE BY SIDE ── */
  .top5-grid{display:grid;grid-template-columns:1fr 1fr 1fr;gap:14px}
  .top5-grid table th{background:#1a3d7c}
  /* ── INSIGHTS ── */
  .insights-box{background:#fff;border:1px solid #e0e6f0;border-radius:10px;padding:18px 20px}
  .ins-item{display:flex;gap:10px;margin-bottom:10px;align-items:flex-start}
  .ins-dot{width:8px;height:8px;border-radius:50%;background:#c9a84c;margin-top:4px;flex-shrink:0}
  .ins-text{font-size:12px;color:#333;line-height:1.5}
  /* ── FOOTER ── */
  .footer{text-align:center;color:#aaa;font-size:10px;margin-top:36px;padding-top:14px;
    border-top:1px solid #dde3ef}
  /* ── PRINT ── */
  @media print{
    body{background:#fff}
    .page{padding:12px 10px}
    .no-print{display:none}
    .chart-grid{grid-template-columns:1fr 1fr}
    .top5-grid{grid-template-columns:1fr 1fr 1fr}
    .kpi-grid{grid-template-columns:repeat(4,1fr)}
  }
</style>
</head>
<body>
<div class="page">

  <!-- PRINT BUTTON -->
  <div class="no-print" style="text-align:right;margin-bottom:18px">
    <button onclick="window.print()"
      style="background:#1a3d7c;color:#fff;border:none;padding:11px 22px;border-radius:7px;
             font-size:13px;font-weight:700;cursor:pointer;letter-spacing:.3px">
      🖨 Save as PDF / Print
    </button>
  </div>

  <!-- HEADER -->
  <div class="header">
    <div>
      <h1>MAKERS AIR VALET — By Farber Parking</h1>
      <div class="sub">Monthly Operations Report &nbsp;·&nbsp; May 2026 &nbsp;·&nbsp; Generated ${new Date().toLocaleDateString('en-US',{dateStyle:'long'})}</div>
    </div>
    <div class="badge-title">MAY 2026<br>Operations</div>
  </div>

  <!-- SECTION 1: EXECUTIVE SUMMARY -->
  <div class="section">
    <h2>Executive Summary</h2>
    <div class="kpi-grid">
      <div class="kpi"><div class="num">${validArr}</div><div class="lbl">Arrivals in May</div></div>
      <div class="kpi"><div class="num">${validDel}</div><div class="lbl">Deliveries in May</div></div>
      <div class="kpi accent"><div class="num">${avgDailyA}</div><div class="lbl">Avg Daily Arrivals</div></div>
      <div class="kpi accent"><div class="num">${avgDailyD}</div><div class="lbl">Avg Daily Deliveries</div></div>
    </div>
    <div class="kpi-grid" style="margin-top:10px">
      <div class="kpi"><div class="num" style="font-size:18px">${busiestAWD}</div><div class="lbl">Busiest Arrival Weekday</div></div>
      <div class="kpi"><div class="num" style="font-size:18px">${busiestDWD}</div><div class="lbl">Busiest Delivery Weekday</div></div>
      <div class="kpi"><div class="num" style="font-size:16px">${busiest.key}</div><div class="lbl">Busiest Single Day<br>${busiest.arr+busiest.del} combined ops</div></div>
      <div class="kpi"><div class="num">${records.length}</div><div class="lbl">Total Records in DB</div></div>
    </div>
  </div>

  <!-- SECTION 2: CHARTS -->
  <div class="section">
    <h2>Daily Activity Charts</h2>
    <div class="chart-full">
      <h3>Daily Arrivals vs Deliveries — May 2026</h3>
      <canvas id="dailyChart" height="90"></canvas>
    </div>
    <div class="chart-grid" style="margin-top:14px">
      <div class="chart-wrap">
        <h3>Average Arrivals by Weekday</h3>
        <canvas id="wdArrChart" height="160"></canvas>
      </div>
      <div class="chart-wrap">
        <h3>Average Deliveries by Weekday</h3>
        <canvas id="wdDelChart" height="160"></canvas>
      </div>
    </div>
  </div>

  <!-- SECTION 3: WEEKDAY AVERAGES -->
  <div class="section">
    <h2>Weekday Average Analysis</h2>
    <table>
      <thead><tr>
        <th>Weekday</th><th># Occurrences</th>
        <th>Total Arrivals</th><th>Avg Arrivals/Week</th>
        <th>Total Deliveries</th><th>Avg Deliveries/Week</th>
      </tr></thead>
      <tbody>${wdTableRows}</tbody>
    </table>
  </div>

  <!-- SECTION 4: TOP 5 DAYS -->
  <div class="section">
    <h2>Busiest Days</h2>
    <div class="top5-grid">
      <div>
        <p style="font-size:11px;font-weight:700;color:#555;text-transform:uppercase;letter-spacing:.5px;margin-bottom:8px">Top 5 Arrival Days</p>
        <table><thead><tr><th>#</th><th>Date</th><th>Weekday</th><th>Arr</th></tr></thead>
        <tbody>${topRows(top5A,['arr'])}</tbody></table>
      </div>
      <div>
        <p style="font-size:11px;font-weight:700;color:#555;text-transform:uppercase;letter-spacing:.5px;margin-bottom:8px">Top 5 Delivery Days</p>
        <table><thead><tr><th>#</th><th>Date</th><th>Weekday</th><th>Del</th></tr></thead>
        <tbody>${topRows(top5D,['del'])}</tbody></table>
      </div>
      <div>
        <p style="font-size:11px;font-weight:700;color:#555;text-transform:uppercase;letter-spacing:.5px;margin-bottom:8px">Top 5 Combined Days</p>
        <table><thead><tr><th>#</th><th>Date</th><th>Weekday</th><th>Comb</th></tr></thead>
        <tbody>${top5C.map((d,i)=>`<tr><td>${i+1}</td><td>${d.key}</td><td>${d.wd}</td><td>${d.arr+d.del}</td></tr>`).join('')}</tbody></table>
      </div>
    </div>
  </div>

  <!-- SECTION 5: DAILY TABLE -->
  <div class="section">
    <h2>Daily Operations — May 1 to May 31</h2>
    <table>
      <thead><tr><th>Date</th><th>Weekday</th><th>Arrivals</th><th>Deliveries</th><th>Combined</th></tr></thead>
      <tbody>${dailyRows}</tbody>
    </table>
  </div>

  <!-- SECTION 6: INSIGHTS -->
  <div class="section">
    <h2>Operational Insights</h2>
    <div class="insights-box">
      <div class="ins-item"><div class="ins-dot"></div><div class="ins-text">
        <strong>Busiest arrival weekday:</strong> ${busiestAWD} with an average of ${wdAvgA[WDAYS.indexOf(busiestAWD)].toFixed(1)} arrivals per ${busiestAWD}.
      </div></div>
      <div class="ins-item"><div class="ins-dot"></div><div class="ins-text">
        <strong>Busiest delivery weekday:</strong> ${busiestDWD} with an average of ${wdAvgD[WDAYS.indexOf(busiestDWD)].toFixed(1)} deliveries per ${busiestDWD}.
      </div></div>
      <div class="ins-item"><div class="ins-dot"></div><div class="ins-text">
        <strong>Peak operational day:</strong> ${busiest.key} (${busiest.wd}) with ${busiest.arr} arrivals and ${busiest.del} deliveries (${busiest.arr+busiest.del} total operations).
      </div></div>
      <div class="ins-item"><div class="ins-dot"></div><div class="ins-text">
        <strong>Monthly volume:</strong> ${validArr} check-ins and ${validDel} deliveries across 31 operating days.
        Average of ${avgDailyA} arrivals and ${avgDailyD} deliveries per calendar day.
      </div></div>
      <div class="ins-item"><div class="ins-dot"></div><div class="ins-text">
        <strong>Traffic distribution (CV ${cvPct}%):</strong> ${spreadNote}
      </div></div>
      <div class="ins-item"><div class="ins-dot"></div><div class="ins-text">
        <strong>Weekend vs weekday:</strong>
        Avg arrivals — Sat: ${wdAvgA[6].toFixed(1)}, Sun: ${wdAvgA[0].toFixed(1)} vs
        Mon–Fri avg: ${(([1,2,3,4,5].reduce((s,i)=>s+wdAvgA[i],0))/5).toFixed(1)}.
      </div></div>
    </div>
  </div>

  <!-- FOOTER -->
  <div class="footer">
    Makers Air Valet by Farber Parking &nbsp;·&nbsp; Confidential &nbsp;·&nbsp;
    ${records.length} total records &nbsp;·&nbsp; Report generated ${new Date().toLocaleString('en-US')}
  </div>

</div><!-- end .page -->

<script>
const dayLabels  = ${JSON.stringify(dayLabels)};
const arrData    = ${JSON.stringify(arrData)};
const delData    = ${JSON.stringify(delData)};
const wdLabels   = ${JSON.stringify(wdLabels)};
const wdAvgAR    = ${JSON.stringify(wdAvgAR)};
const wdAvgDR    = ${JSON.stringify(wdAvgDR)};

// Daily line chart
new Chart(document.getElementById('dailyChart'), {
  type: 'line',
  data: {
    labels: dayLabels,
    datasets: [
      { label:'Arrivals', data:arrData, borderColor:'#1a3d7c', backgroundColor:'rgba(26,61,124,.08)',
        tension:.35, fill:true, pointRadius:3, borderWidth:2 },
      { label:'Deliveries', data:delData, borderColor:'#c9a84c', backgroundColor:'rgba(201,168,76,.08)',
        tension:.35, fill:true, pointRadius:3, borderWidth:2 }
    ]
  },
  options:{
    responsive:true, interaction:{mode:'index',intersect:false},
    plugins:{legend:{labels:{font:{size:11}}}},
    scales:{
      x:{ticks:{font:{size:10},maxRotation:45}},
      y:{beginAtZero:true,ticks:{font:{size:10},stepSize:1}}
    }
  }
});

// Weekday arrivals bar
new Chart(document.getElementById('wdArrChart'), {
  type:'bar',
  data:{
    labels: wdLabels,
    datasets:[{ label:'Avg Arrivals', data:wdAvgAR,
      backgroundColor:'rgba(26,61,124,.75)', borderRadius:5, borderSkipped:false }]
  },
  options:{
    responsive:true,
    plugins:{legend:{display:false}},
    scales:{y:{beginAtZero:true,ticks:{font:{size:10}}},x:{ticks:{font:{size:10}}}}
  }
});

// Weekday deliveries bar
new Chart(document.getElementById('wdDelChart'), {
  type:'bar',
  data:{
    labels: wdLabels,
    datasets:[{ label:'Avg Deliveries', data:wdAvgDR,
      backgroundColor:'rgba(201,168,76,.80)', borderRadius:5, borderSkipped:false }]
  },
  options:{
    responsive:true,
    plugins:{legend:{display:false}},
    scales:{y:{beginAtZero:true,ticks:{font:{size:10}}},x:{ticks:{font:{size:10}}}}
  }
});
<\/script>
</body>
</html>`;

  // Open in new tab
  const win = window.open('', '_blank');
  if (!win) {
    alert('Pop-up blocked. Please allow pop-ups for this site and try again.');
    return;
  }
  win.document.write(html);
  win.document.close();

  console.log('✅ Report opened in new tab — use "Save as PDF / Print" button.');
  console.log('✅ CSV  download triggered: may-2026-daily-operations.csv');
  console.log('✅ JSON download triggered: may-2026-operations-summary.json');
  console.log('');
  console.log('── Key Numbers ────────────────────────────────────');
  console.log('Total arrivals in May:   ', validArr);
  console.log('Total deliveries in May: ', validDel);
  console.log('Avg daily arrivals:      ', avgDailyA);
  console.log('Avg daily deliveries:    ', avgDailyD);
  console.log('Busiest arrival weekday: ', busiestAWD, `(avg ${Math.max(...wdAvgA).toFixed(1)})`);
  console.log('Busiest delivery weekday:', busiestDWD, `(avg ${Math.max(...wdAvgD).toFixed(1)})`);
  console.log('Busiest single day:      ', busiest.key, `(${busiest.wd}) — ${busiest.arr+busiest.del} combined`);

})();
