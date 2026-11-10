# Pearl pool statistics

In **Settings → Pearl**, choose the **Pool** your miner uses, **PF Pool** (the default) or **Kryptex**, and enter the public PRL wallet address it mines to. With Kryptex, you can enter an exact worker name, such as `rtx4090`; leave it empty to combine all workers for that wallet. PF Pool reports whole addresses, so its figures always include every worker. Save & connect reads the pool directly. No API key, local stats server, SSH connection or extra service on the mining host is required. Configurations saved before the pool choice existed use PF Pool; select Kryptex to keep reading Kryptex.

**Settings → Pearl → Hashrate average** selects one of the pool's own averages: **1 hour, 8 hours, 24 hours or 7 days** on PF Pool, **30 minutes, 3 hours, 24 hours or 7 days** on Kryptex. Seven days is the default. Changing pool keeps the selection's position, so 30 minutes becomes 1 hour and 3 hours becomes 8 hours. Click **Save & connect** to apply a change. The selected average drives the menu bar, dropdown headline, projected PRL/day and revenue/profit table. The dropdown labels the pool and selected period, and also shows all four averages and the online worker count.

These accepted-share averages fluctuate and can differ from a miner's instantaneous reported speed. The shortest average counts as zero while no worker is online: on PF Pool when no worker is connected, on Kryptex for workers it marks offline. Longer averages can remain nonzero while offline. Longer-window projections assume that historical average continues. A missing wallet/worker or failed selected-average request leaves the headline and projections unavailable; the app never silently substitutes a shorter average.

## PF Pool

[PF Pool](https://pearlfortune.org/) is Pearl Fortune's pool; Pearl Fortune 2.2.8 and later mine only there. Its public API under `https://pearlfortune.org/api/v1/` needs no key and wraps each response in `data`. Most responses shorten addresses, as in `prl1abcdef...uvwxyz12`; the collector requires both ends to match the saved address. Unknown addresses return HTTP 400. Verified on 29 October 2026:

- **Hashrate:** `GET /miners/{address}/hourly-shares?hours=24` → `rolling_hashrates[]` with `hours` 1, 8 and 24. Each `hashrate` is accepted work over the time the pool observed, in H/s, updated every five minutes; the latest window must end less than 30 minutes ago. `GET /miners/{address}/connections` → `workers[]` lists connected sessions, online unless `stale`. Disconnected workers are not listed, so the worker count covers connected sessions only.
- **7-day average:** `GET /miners/{address}/hourly-shares?hours=168` → `series[]` holds 168 hourly buckets plus the current partial hour, each with `share_statistics.from`, `to`, `effective_hashrate` (H/s) and `observed_ms`. The collector time-weights each hour's rate over the seven days ending at the latest bucket, clipping the oldest hour. Hours without shares count as zero, including the hours before you started mining on PF Pool, so the 7-day average only reaches your full rate after a week on the pool. Gaps, overlapping hours, hours the pool did not observe at all, malformed values, less than a week, or a latest bucket 30 minutes old or more leave it unavailable. History has its own five-minute cache.
- **Yield and fee:** `GET /summary?hours=24` → the `pool_stats.rolling_stats[]` entry with `hours` 0, whose `theoretical_yield` is PRL per MH/s per day before fees, from the latest difficulty and block reward (cached five minutes). `GET /miners/{address}/address-mode` → `bridge.payment_mode`, `pps` unless an administrator switched the address to `pplns`, and `bridge.pps_fee_rate`, the address's PPS fee.
- **Unpaid rewards:** `GET /miners/{address}/pps?status=pending` → `immature_q64`, PPS income after the fee that is still maturing (about five hours); `balance_atomic`, matured and payable; and `remainder_q64`, a matured fraction below one base unit. Q64 values are base units × 2⁶⁴, and a base unit is 10⁻⁸ PRL.
- **Payouts:** `GET /miners/{address}/ledger?page=1&page_size=5&entry_type=payout` → the five newest `entries` with `amount_atomic`, `event_time`, `status` and `tx_hash`, plus `total`, the number of payouts, and `sum_payout_amount_atomic`, the all-time total. PF Pool sends matured rewards automatically, about hourly, in batches; it publishes no payout threshold.

## Kryptex

The worker endpoint is `GET https://pool.kryptex.com/prl/api/v3/miner/workers/{address}`. Verified live fields are `results[].avg_hashrate_30m`, `avg_hashrate_3h`, `avg_hashrate_24h`, `status`, `scheme`, `coin`, and `miner`; the rate fields are H/s and may be decimal strings. The public OpenAPI schema currently lists an older generic `hashrate` field, so the collector uses the verified v3 average fields explicitly. Responses that indicate incomplete worker lists are rejected rather than displaying partial totals.

The seven-day average comes from `GET /prl/api/v1/miner/chart/{address}?days=7`, or `/chart/{address}/{worker}?days=7` for an exact worker. It is available immediately from pool history, without keeping the Mac awake to collect samples. The verified chart contains 1,009 ten-minute points spanning seven days, with millisecond `timestamp` values and raw `hashrate` in H/s. The collector time-weights the raw rate from each timestamp to the next, clipped to seven days ending at the latest chart timestamp. It does not average the chart's already-smoothed 30-minute/3-hour fields or extrapolate beyond its latest timestamp. Explicit zero-rate intervals count as downtime; missing intervals, duplicate timestamps, malformed samples or less than a full week leave this average unavailable. The latest chart timestamp must be less than 30 minutes old.

History has its own five-minute cache and error backoff, scoped to the wallet and worker. Only the normalized average and latest chart timestamp are stored, with private file permissions. If weekly history is unavailable, shorter selections and independent price/balance data remain usable.

Kryptex's miner endpoints are `/prl/api/v1/miner/balance/{address}`, `/payouts/{address}`, and `/payouts/{address}/stats`; yield and fee come from `/prl/api/v1/pool/info`.

## Wallet balance and payouts

The dropdown's Balances section shows:

- **Wallet:** confirmed PRL held at the saved mining address, read from Pearl's public mainnet Blockbook explorer, with its value at the current price. This is the current balance of that address, not lifetime receipts or a total across every address a wallet may control. Mempool changes are excluded.
- **Unpaid rewards:** the pool's total, with its current value; the tooltip splits it into confirmed rewards and rewards still maturing. On PF Pool, confirmed means matured and payable, and maturing is PPS income in its roughly five-hour maturation. In PPLNS mode, PF Pool's figure includes only the payable balance. On Kryptex, a bar shows confirmed rewards against the payout threshold; only confirmed rewards count toward it.
- **Total paid:** the pool's all-time payout total, independent of current wallet holdings. Spending or receiving PRL elsewhere can make this differ from wallet balance. PF Pool's total includes payouts still being sent and excludes failed ones.

**Recent payouts** lists up to five newest records on one line each, with date and time, pool-reported status and PRL amount; the header counts them against the total, as in "5 of 46". Valid transaction IDs link to Pearl's mainnet explorer. Only a finished payout is labeled Paid. On PF Pool, Sent is on-chain but awaiting the pool's own confirmation, and Sending is still being broadcast. On Kryptex, a pending payout shows its planned amount and keeps its pending status. Failed, rejected, cancelled and needs-review payouts are orange. Pool status is not an independent on-chain confirmation check.

Balances and payouts cover the entire configured mining address, even when Kryptex hashrate is filtered to one worker. Use **Settings → Pearl → Add item** for Wallet balance, Unpaid pool rewards or Total paid by pool in the menu bar. The dropdown and menu items display four decimal places; hover an amount in the dropdown for all eight.

The wallet source is `GET https://blockbook.pearlresearch.ai/api/v2/address/{address}?details=basic`. The explorer's `/api/v2` status must report synchronized Pearl mainnet, eight decimal places, and a block update within 30 minutes. Integer balance units are divided by 100,000,000. Pool sources are listed under each pool above. The collector never calculates all-time paid by summing one page of payout history.

Each source has independent 60-second caching and error backoff. Requests run concurrently; an explorer failure leaves pool metrics available and vice versa. Missing balances and payout history stay unavailable; a successful empty history is shown as No payouts yet. Normalized balances, amounts, dates, statuses and transaction IDs are cached with private file permissions; wallet addresses remain in preferences rather than the metrics cache.

## Projection definitions

Projected PRL/day = selected pool-accepted hashrate average × the pool's current yield per H/s per day × (1 − pool fee):

- **PF Pool:** `theoretical_yield` ÷ 1,000,000 and the address's `pps_fee_rate`. Projections need the default PPS mode; PPS pays this yield for accepted work.
- **Kryptex:** `estimated_profit_day` and the pool `fee`. Projections need PPS+ workers.

Shares mined for the software developer do not arrive under your wallet, so the developer fee is already reflected in the accepted hashrate and is not deducted again.

Revenue is projected PRL/day × CoinGecko's USD price for Pearl Research (`pearl-2`), optionally converted to EUR. Profit subtracts measured power assigned to Pearl at the shared Power tariff. The projection scales by 1/24, 1, 7 and 30 for hour, day, week and month; the table's Power row shows the daily cost it deducts. All periods assume the selected hashrate average continues at the current price, yield and draw. A seven-day hashrate selection does not turn these into historical earnings or average past prices, yields or power readings. Hardware, exchange, withdrawal and tax costs are excluded. Missing price or assigned power readings leave the dependent projections unavailable.

Previous local API settings are ignored and omitted on the next preferences save; Power settings and other providers are preserved. No local adapter is bundled.

Sources: [PF Pool](https://pearlfortune.org/), [Pearl Fortune miner](https://github.com/pearlfortune/pearl-miner), [Kryptex API](https://pool.kryptex.com/en/api), [OpenAPI schema](https://pool.kryptex.com/openapi.yaml), [live pool information](https://pool.kryptex.com/prl/api/v1/pool/info), [Pearl Blockbook](https://blockbook.pearlresearch.ai/), [Blockbook API schema](https://github.com/pearl-research-labs/blockbook/blob/master/openapi.yaml), [CoinGecko simple price](https://docs.coingecko.com/reference/simple-price).
