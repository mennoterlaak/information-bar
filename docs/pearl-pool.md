# Pearl pool statistics

In **Settings → Pearl**, enter the public PRL wallet address used for mining on Kryptex. Optionally enter an exact worker name, such as `rtx4090`; leave it empty to combine all workers for that wallet. Save & connect reads the pool directly. No API key, local stats server, SSH connection or extra service on the mining host is required.

**Settings → Pearl → Hashrate average** selects **30 minutes, 3 hours, 24 hours or 7 days**. Seven days is the default, including for existing configurations. Click **Save & connect** to apply a change. The selected average drives the menu bar, dropdown headline, projected PRL/day and revenue/profit table. The dropdown labels the selected period and also shows all four averages and the online worker count.

These accepted-share averages fluctuate and can differ from a miner's instantaneous reported speed. Workers explicitly marked offline contribute zero to the 30-minute current rate; historical averages can remain nonzero while offline. Longer-window projections assume that historical average continues. A missing wallet/worker or failed selected-average request leaves the headline and projections unavailable; the app never silently substitutes a shorter average.

The worker endpoint is `GET /prl/api/v3/miner/workers/{address}`. Verified live fields are `results[].avg_hashrate_30m`, `avg_hashrate_3h`, `avg_hashrate_24h`, `status`, `scheme`, `coin`, and `miner`; the rate fields are H/s and may be decimal strings. The public OpenAPI schema currently lists an older generic `hashrate` field, so the collector uses the verified v3 average fields explicitly. Responses that indicate incomplete worker lists are rejected rather than displaying partial totals.

The seven-day average comes from `GET /prl/api/v1/miner/chart/{address}?days=7`, or `/chart/{address}/{worker}?days=7` for an exact worker. It is available immediately from pool history, without keeping the Mac awake to collect samples. The verified chart contains 1,009 ten-minute points spanning seven days, with millisecond `timestamp` values and raw `hashrate` in H/s. The collector time-weights the raw rate from each timestamp to the next, clipped to seven days ending at the latest chart timestamp. It does not average the chart's already-smoothed 30-minute/3-hour fields or extrapolate beyond its latest timestamp. Explicit zero-rate intervals count as downtime; missing intervals, duplicate timestamps, malformed samples or less than a full week leave this average unavailable. The latest chart timestamp must be less than 30 minutes old.

History has its own five-minute cache and error backoff, scoped to the wallet and worker. Only the normalized average and latest chart timestamp are stored, with private file permissions. If weekly history is unavailable, shorter selections and independent price/balance data remain usable.

## Wallet balance and payouts

The dropdown's Balances section shows:

- **Wallet:** confirmed PRL held at the saved mining address, read from Pearl's public mainnet Blockbook explorer, with its value at the current price. This is the current balance of that address, not lifetime receipts or a total across every address a wallet may control. Mempool changes are excluded.
- **Unpaid rewards:** Kryptex's total, with its current value. A bar shows confirmed rewards against the payout threshold; the tooltip splits the total into confirmed rewards and rewards still maturing. Only confirmed rewards count toward the threshold.
- **Total paid:** Kryptex's all-time paid statistic, independent of current wallet holdings. Spending or receiving PRL elsewhere can make this differ from wallet balance.

**Recent payouts** lists up to five newest records on one line each, with date and time, pool-reported status and PRL amount; the header counts them against the total, as in "5 of 46". Valid transaction IDs link to Pearl's mainnet explorer. A pending payout shows its planned amount and retains its pending status; only a finished payout is labeled Paid, and failed, rejected or cancelled payouts are orange. Pool status is not an independent on-chain confirmation check.

Balances and payouts cover the entire configured mining address even when hashrate is filtered to one worker. Use **Settings → Pearl → Add item** for Wallet balance, Unpaid pool rewards or Total paid by pool in the menu bar. The dropdown and menu items display four decimal places; hover an amount in the dropdown for all eight.

Sources are `GET https://blockbook.pearlresearch.ai/api/v2/address/{address}?details=basic` and Kryptex's `/prl/api/v1/miner/balance/{address}`, `/payouts/{address}`, and `/payouts/{address}/stats`. The explorer's `/api/v2` status must report synchronized Pearl mainnet, eight decimal places, and a block update within 30 minutes. Integer balance units are divided by 100,000,000. The collector never calculates all-time paid by summing one page of payout history.

Each source has independent 60-second caching and error backoff. Requests run concurrently; an explorer failure leaves pool metrics available and vice versa. Missing balances and payout history stay unavailable; a successful empty history is shown as No payouts yet. Normalized balances, amounts, dates, statuses and transaction IDs are cached with private file permissions; wallet addresses remain in preferences rather than the metrics cache.

## Projection definitions

Projected PRL/day = selected pool-accepted hashrate average × current Kryptex `estimated_profit_day` × (1 − pool `fee`). This uses PPS+ workers. Shares mined for the software developer do not arrive under your wallet, so the developer fee is already reflected in the accepted hashrate and is not deducted again.

Revenue is projected PRL/day × CoinGecko's USD price for Pearl Research (`pearl-2`), optionally converted to EUR. Profit subtracts measured power assigned to Pearl at the shared Power tariff. The projection scales by 1/24, 1, 7 and 30 for hour, day, week and month; the table's Power row shows the daily cost it deducts. All periods assume the selected hashrate average continues at the current price, yield and draw. A seven-day hashrate selection does not turn these into historical earnings or average past prices, yields or power readings. Hardware, exchange, withdrawal and tax costs are excluded. Missing price or assigned power readings leave the dependent projections unavailable.

Previous local API settings are ignored and omitted on the next preferences save; Power settings and other providers are preserved. No local adapter is bundled.

Sources: [Kryptex API](https://pool.kryptex.com/en/api), [OpenAPI schema](https://pool.kryptex.com/openapi.yaml), [live pool information](https://pool.kryptex.com/prl/api/v1/pool/info), [Pearl Blockbook](https://blockbook.pearlresearch.ai/), [Blockbook API schema](https://github.com/pearl-research-labs/blockbook/blob/master/openapi.yaml), [CoinGecko simple price](https://docs.coingecko.com/reference/simple-price).
