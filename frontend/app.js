/* Payday Splitter — live on-chain data (read-only, Base Sepolia RPC).
   No wallet, no signing. If the RPC cannot be reached, the page shows the
   last verified values, clearly labelled — never fake live numbers.

   How live data is read:
   - Vault / destination balances come from balanceOf() calls. The three
     destination wallets only ever receive MPT from vault splits, so their
     balances ARE the cumulative split totals.
   - The latest payment and split transactions come from a backwards scan
     of Transfer logs (newest first, stops as soon as both are found).
   - The public RPC caps eth_getLogs at 200 blocks per call, hence chunking. */
(function () {
  "use strict";

  var RPC_URL = "https://sepolia.base.org";
  var MPT = "0x43a33C4AeC29DB91c655eAB44417545ceCeD21A1";
  var VAULT = "0xB919828FfF2e6b3B6f7a3E5e8033b831e6545e9E";
  var MAIN = "0x77D3bbBAe111399a69a33b9feeC639fC3B155894";
  var SAVINGS = "0x6B9eE8C207F3258c023C0863DD8c638DD921cc66";
  var GAS = "0x92760589D753E606D3AB6a2FC15be6D9Aa366B3c";
  var TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
  var BASESCAN = "https://sepolia.basescan.org/tx/";
  var SCAN_CHUNK = 200;
  var SCAN_MAX_CHUNKS = 60;
  var SCAN_BATCH = 5;
  var OVERALL_TIMEOUT_MS = 25000;

  /* Last verified on-chain values (23 Nov 2026, checked against the RPC).
     Shown ONLY when live data cannot load, labelled as such. */
  var FALLBACK = {
    vaultBalance: 0,
    main: 2800,
    savings: 800,
    gas: 400,
    payTx: "0x56ec09a0484af0e1ad0f8943ea9c460dc7160f3a534d127be54612a17e22c1b1",
    payBlock: 62502902,
    splitTx: "0xd8b3e71081ac4cf1392701db041b68569b7f4badc02e196e7ba733e38d467638",
    splitBlock: 62502908,
    latencySec: 1,
    label: "Last verified 23 Nov 2026"
  };

  function $(id) { return document.getElementById(id); }
  function pad(addr) { return "0x" + "0".repeat(24) + addr.slice(2).toLowerCase(); }
  function shortHash(h) { return h.slice(0, 10) + "…" + h.slice(-6); }
  function fmt(n) { return n.toLocaleString("en-US"); }

  var rpcId = 0;
  function rpc(method, params, signal) {
    var body = JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method: method, params: params });
    return fetch(RPC_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: body,
      signal: signal
    }).then(function (res) {
      if (!res.ok) throw new Error("RPC HTTP " + res.status);
      return res.json();
    }).then(function (json) {
      if (json.error) throw new Error(json.error.message || "RPC error");
      return json.result;
    });
  }

  function balanceOf(addr, signal) {
    return rpc("eth_call", [{
      to: MPT,
      data: "0x70a08231" + pad(addr).slice(2)
    }, "latest"], signal).then(function (hex) {
      return Number(BigInt(hex) / BigInt("1000000000000000000"));
    });
  }

  function getBlockTimestamp(blockNumber, signal) {
    return rpc("eth_getBlockByNumber", ["0x" + blockNumber.toString(16), false], signal)
      .then(function (b) { return parseInt(b.timestamp, 16); });
  }

  /* Scan Transfer logs backwards from `latest`, newest chunk first, stopping
     as soon as the latest payment (to vault) and latest split (from vault)
     are both found. Capped so an old, quiet vault falls back cleanly. */
  function scanBackwards(latest, signal) {
    var found = { pay: null, split: null };
    var vaultLower = VAULT.toLowerCase();
    var ranges = [];
    for (var i = 0; i < SCAN_MAX_CHUNKS; i++) {
      var to = latest - i * SCAN_CHUNK;
      var from = Math.max(to - SCAN_CHUNK + 1, 0);
      ranges.push([from, to]);
      if (from <= 0) break;
    }
    var idx = 0;
    function processLogs(logs) {
      logs.forEach(function (e) {
        var fromA = "0x" + e.topics[1].slice(-40);
        var toA = "0x" + e.topics[2].slice(-40);
        var bn = parseInt(e.blockNumber, 16);
        var li = parseInt(e.logIndex, 16);
        if (toA === vaultLower && (!found.pay || bn > found.pay.block || (bn === found.pay.block && li > found.pay.logIndex))) {
          found.pay = { block: bn, tx: e.transactionHash, logIndex: li };
        }
        if (fromA === vaultLower && (!found.split || bn > found.split.block || (bn === found.split.block && li > found.split.logIndex))) {
          found.split = { block: bn, tx: e.transactionHash, logIndex: li };
        }
      });
    }
    function nextBatch() {
      if ((found.pay && found.split) || idx >= ranges.length) return Promise.resolve(found);
      var batch = ranges.slice(idx, idx + SCAN_BATCH);
      idx += SCAN_BATCH;
      return Promise.all(batch.map(function (r) {
        return rpc("eth_getLogs", [{
          address: MPT,
          fromBlock: "0x" + r[0].toString(16),
          toBlock: "0x" + r[1].toString(16),
          topics: [TRANSFER_TOPIC]
        }], signal);
      })).then(function (results) {
        results.forEach(processLogs);
        return nextBatch();
      });
    }
    return nextBatch();
  }

  function loadLive() {
    setStatus("loading", "Loading live data…");
    var ctrl = new AbortController();
    var timer = setTimeout(function () { ctrl.abort(); }, OVERALL_TIMEOUT_MS);
    var signal = ctrl.signal;

    rpc("eth_blockNumber", [], signal).then(function (latestHex) {
      var latest = parseInt(latestHex, 16);
      return Promise.all([
        balanceOf(VAULT, signal),
        balanceOf(MAIN, signal),
        balanceOf(SAVINGS, signal),
        balanceOf(GAS, signal)
      ]).then(function (bals) {
        return scanBackwards(latest, signal).then(function (found) {
          if (!found.pay || !found.split) throw new Error("No loop found on-chain yet");
          return getBlockTimestamp(found.pay.block, signal).then(function (tPay) {
            return getBlockTimestamp(found.split.block, signal).then(function (tSplit) {
              clearTimeout(timer);
              render({
                vaultBalance: bals[0],
                main: bals[1],
                savings: bals[2],
                gas: bals[3],
                payTx: found.pay.tx,
                payBlock: found.pay.block,
                splitTx: found.split.tx,
                splitBlock: found.split.block,
                latencySec: Math.max(0, tSplit - tPay),
                live: true,
                updatedAt: new Date()
              });
            });
          });
        });
      });
    }).catch(function (err) {
      clearTimeout(timer);
      renderFallback(err && err.name === "AbortError" ? "timed out" : (err && err.message) || "failed");
    });
  }

  function render(d) {
    $("vault-balance").textContent = fmt(d.vaultBalance) + " MPT";
    var total = d.main + d.savings + d.gas;
    $("total-split").textContent = fmt(total) + " MPT";
    $("latest-latency").textContent = d.latencySec + (d.latencySec === 1 ? " second" : " seconds");
    setBar("bar-main", "val-main", d.main, total);
    setBar("bar-savings", "val-savings", d.savings, total);
    setBar("bar-gas", "val-gas", d.gas, total);

    var payA = $("pay-tx");
    payA.textContent = shortHash(d.payTx);
    payA.href = BASESCAN + d.payTx;
    $("pay-block").textContent = "· block " + fmt(d.payBlock);

    var splitA = $("split-tx");
    splitA.textContent = shortHash(d.splitTx);
    splitA.href = BASESCAN + d.splitTx;
    $("split-block").textContent = "· block " + fmt(d.splitBlock);

    if (d.live) {
      setStatus("live", "Live · updated " + d.updatedAt.toLocaleTimeString("en-GB"));
      $("live-note").textContent = "Read from the Base Sepolia RPC just now. Click a transaction hash to verify it on Basescan.";
    } else {
      setStatus("fallback", "Live data couldn't load — showing last verified totals");
      $("live-note").textContent = d.label + ". " + (d.why || "") + " These are the last totals verified against the chain; refresh to try live data again.";
    }
  }

  function renderFallback(why) {
    render({
      vaultBalance: FALLBACK.vaultBalance,
      main: FALLBACK.main,
      savings: FALLBACK.savings,
      gas: FALLBACK.gas,
      payTx: FALLBACK.payTx,
      payBlock: FALLBACK.payBlock,
      splitTx: FALLBACK.splitTx,
      splitBlock: FALLBACK.splitBlock,
      latencySec: FALLBACK.latencySec,
      live: false,
      label: FALLBACK.label,
      why: why ? "(" + why + ")" : ""
    });
  }

  function setBar(barId, valId, value, total) {
    $(valId).textContent = fmt(value) + " MPT";
    $(barId).style.width = total > 0 ? Math.round((value / total) * 100) + "%" : "0%";
  }

  function setStatus(kind, text) {
    var el = $("live-status");
    var dot = el.querySelector(".status-dot");
    dot.className = "status-dot status-" + kind;
    el.childNodes.forEach(function (n) { if (n.nodeType === 3) n.remove(); });
    el.appendChild(document.createTextNode(" " + text));
  }

  /* Copy buttons (contracts + destinations) */
  document.querySelectorAll(".copy-btn").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var value = btn.getAttribute("data-copy");
      function done() {
        btn.textContent = "Copied";
        btn.classList.add("copied");
        setTimeout(function () { btn.textContent = "Copy"; btn.classList.remove("copied"); }, 1600);
      }
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(value).then(done, function () { fallbackCopy(value); done(); });
      } else {
        fallbackCopy(value);
        done();
      }
    });
  });
  function fallbackCopy(value) {
    var ta = document.createElement("textarea");
    ta.value = value;
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand("copy"); } catch (e) { /* ignore */ }
    document.body.removeChild(ta);
  }

  $("refresh-live").addEventListener("click", loadLive);
  loadLive();
})();
