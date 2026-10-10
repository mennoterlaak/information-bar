# Data sources

AI/Vast sources checked 9 September 2026; HomeWizard added 2 October 2026; Pearl pool workers verified 3 October 2026; Kraken added 10 October 2026. The collector is deliberately read-only.

## Codex

Starts the installed `codex app-server` over stdio, performs `initialize` / `initialized`, calls `account/rateLimits/read`, then terminates the process group. It never starts a thread or an inference turn, reads auth tokens directly, or consumes earned limit resets.

[Official Codex app-server documentation](https://developers.openai.com/codex/app-server) defines `usedPercent`, `windowDurationMins`, Unix-second `resetsAt` and the optional multi-bucket `rateLimitsByLimitId`. Window names come from the actual duration, including accounts with only a weekly primary window. Additional model limits remain separate.

## Claude

Reads the existing Claude Code OAuth credential from its `Claude Code-credentials` macOS Keychain item, with the CLI credential file as a fallback. Calls `GET https://api.anthropic.com/api/oauth/usage` with the existing bearer token and the client's OAuth beta header. This is an undocumented account interface.

`five_hour.utilization`, `seven_day.utilization` and available optional model windows are percentages. Reset timestamps are ISO 8601. Newer responses also carry a `limits` list whose entries have a `kind` (`session`, `weekly_all`, `weekly_scoped`), a `percent`, and a `scope` naming a model or surface; model-specific weekly caps such as Fable's appear only there. The collector merges both forms under `seven_day_<model>` identifiers, skips duplicates, and marks account-wide and per-model pools as main so they lead the dropdown and count for the menu bar's most-used value. Surface-scoped limits stay under additional allowances. Expired credentials require a login refresh through Claude Code; this app does not refresh them itself. Polling has a five-minute minimum and honors HTTP 429 backoff.

[Claude's documented status-line interface](https://code.claude.com/docs/en/statusline) also exposes subscription limits after model responses. This app does not change the user's status line or depend on a running conversation.

## Cursor

Opens Cursor's `User/globalStorage/state.vscdb` read-only and selects only `cursorAuth/accessToken` and `cursorAuth/stripeMembershipType`. Calls the read-only Connect RPC `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage` with an empty request.

The installed Cursor app's `workbench.desktop.main.js` establishes the service method and the response schema. `planUsage.autoPercentUsed` and `apiPercentUsed` represent separate pools. `billingCycleStart` and `billingCycleEnd` are milliseconds since epoch; both are normalized to seconds and displayed as the billing cycle. Percentages are not reconstructed from token logs or combined into a single blended quota. The default menu summary shows the higher of the two main pool percentages; Settings can select an individual pool and show usage, remaining allowance or reset countdown.

[Cursor usage documentation](https://prod.cursor.com/help/models-and-usage/usage-limits) describes the Cursor-model and other-model pools and billing-cycle resets. The account RPC is not the public team Admin API and may change.

## Vast.ai

[Machines API](https://docs.vast.ai/api-reference/machines/show-machines): `GET /api/v0/machines/`, with `owner=me` and `include_offline=1`. Fields were checked against the authenticated web console: `current_rentals_running`, `current_rentals_resident`, `gpu_occupancy`, `listed_gpu_cost`, `earn_hour`, `verification`, GPU and machine identifiers. Running counts establish active rental status; occupancy establishes rented GPU count. `earn_hour` is the console's reported hourly average, not assumed to be an instantaneous contract price.

Daily earnings use the current console's `GET /api/v1/user/earnings/` with a UTC epoch-day filter and `group_by="day"`. The collector follows pagination. If that endpoint is unavailable to the key, it falls back to the documented [machine earnings endpoint](https://docs.vast.ai/api-reference/billing/show-earnings): `GET /api/v0/users/me/machine-earnings/` with `sday` and `eday`. The installed official Vast SDK confirms these parameters are days since epoch.

Only complete daily rows are summed. Missing individual days in a valid completed report are zero; a missing or malformed report is an error. Duplicate dates are rejected. The app keeps machine state available when earnings fail, labels that result Partial, and shows unavailable financial values as dashes.

Per-machine utilization uses the documented [machine earnings endpoint](https://docs.vast.ai/api-reference/billing/show-earnings) (`per_machine[].gpu_earn` over `sday`/`eday`), falling back to `GET /api/v1/user/earnings/` grouped by `machine_id`. Utilization is GPU revenue ÷ (listed GPU price × GPUs × hours), so it is an estimate that rentals priced below the listing lower. It is recomputed at most every five minutes; if both endpoints fail, machines simply show no ring and Settings shows the reason.

Browser session credentials are never read or stored.

## Pearl

Hashrate comes directly from `GET https://pool.kryptex.com/prl/api/v3/miner/workers/{address}`, using the configured public mining wallet and optional exact worker name. The live response's `results` contain `avg_hashrate_30m`, `avg_hashrate_3h`, and `avg_hashrate_24h` in H/s, often encoded as numeric strings. The bar and projections use the 30-minute accepted average; the dropdown also shows the longer averages and the number of online workers. An explicit offline status contributes zero to the current rate; historical averages stay visible. Missing workers, malformed rates, incomplete responses and API failures remain unavailable rather than zero. No local miner API or adapter is used.

Price uses `GET https://api.coingecko.com/api/v3/simple/price?ids=pearl-2&vs_currencies=usd&include_last_updated_at=true`. The asset is Pearl Research, not another PRL token. Quotes are cached for two minutes and rejected if their provider timestamp is over 15 minutes old. The pool source is `GET https://pool.kryptex.com/prl/api/v1/pool/info`: `estimated_profit_day` is base PRL per H/s per day; `fee` is the pool fee fraction. The pool fee is deducted once; accepted hashrate already excludes shares submitted to the developer's fee wallet. Projections require PPS+ workers. See the [projection formula](pearl-pool.md#projection-definitions).

Sources are independent: a failed price request does not erase hashrate; a failed power reading never turns gross revenue into a number labeled profit. Worker data is cached for 60 seconds per wallet/worker selection, with source-specific backoff. Only normalized metrics and a configuration digest enter the cache; wallet addresses and worker names stay in preferences. Hour/day/week/month correspond to 1/24/168/720 hours. The monthly period is always 30 days.

Wallet balance uses the saved mining address at `https://blockbook.pearlresearch.ai/api/v2/address/{address}?details=basic`, after validating the explorer's synchronized Pearl mainnet status and eight-decimal unit. It shows confirmed holdings at that address, excluding mempool changes. Kryptex's miner `balance` endpoint supplies total/confirmed/unconfirmed unpaid rewards and the confirmed payout threshold. Its `payouts` endpoint supplies the latest five records with pool-reported status and transaction links; `payouts/{address}/stats.paid` supplies the all-time payout total. These figures are wallet-wide and independent of the selected worker. See [wallet balance and payouts](pearl-pool.md#wallet-balance-and-payouts) for source contracts and proof boundaries. Failures do not replace missing balances with zero or missing history with an empty list.

## Kraken

Balances come from [`POST https://api.kraken.com/0/private/Balance`](https://docs.kraken.com/api/docs/rest-api/get-account-balance), which needs only the Query Funds permission. Each request carries the API key in `API-Key` and an `API-Sign` signature: HMAC-SHA512 over the URI path and SHA-256(nonce + POST data), keyed by the base64-decoded private key, as in [Kraken's authentication guide](https://docs.kraken.com/api/docs/guides/spot-rest-auth). The private key never leaves the Mac. The nonce is a millisecond timestamp persisted in `kraken-nonce.json`, so it keeps increasing across runs and clock corrections; another client sending larger nonces with the same key would make Kraken reject these, so the key should be used only for Information Bar. Save & connect validates both keys with one Balance request before storing them.

Balance keys are folded into their asset. Staked, opt-in reward, yield-bearing, auto-earn and parachain variants (`.S`, `.M`, `.B`, `.F`, `.P`) count toward the base asset and are labeled "in Earn"; held variants such as `.HOLD` count without that label. Bonded staking assets such as `DOT28.S` and `ETH2` are valued as their base asset only when they have no market of their own, so assets that merely end in digits (`C98`, `USDT0`) are left alone. `KFEE` fee credits are excluded and zero balances skipped. Kraken's `XBT` and `XDG` are displayed as BTC and DOGE.

Asset names and markets come from `GET /0/public/Assets` and [`GET /0/public/AssetPairs`](https://docs.kraken.com/api/docs/rest-api/get-tradable-asset-pairs) (online pairs only), cached for a day in `kraken-markets.json`; a list up to a week old is reused while Kraken is unreachable. Each asset is priced on its market in the portfolio currency, inverted where only the opposite pair exists (USD cash in a EUR portfolio uses EUR/USD), or through one bridge market in USD, EUR, BTC, ETH, USDT or USDC. One [`GET /0/public/Ticker`](https://docs.kraken.com/api/docs/rest-api/get-ticker-information) request covers every market. The price is the last trade (`c[0]`); today's change compares it with the 00:00 UTC open (`o`) for the amounts held now. An unknown pair fails the whole Ticker request, so a delisted market triggers one market-list refresh and retry. Assets without any route stay listed without a price and are excluded from the total. If prices fail, balances stay visible as Partial and the total is unavailable.

Kraken error codes are normalized: an invalid key, invalid signature or missing permission asks for new credentials; nonce errors, temporary lockouts, rate limits and outages back off for five to fifteen minutes. The cache holds normalized balances and prices plus a configuration digest that changes with the keys or currency; it never holds either key. Disconnect removes the Keychain item and the cached portfolio. Holdings worth less than one unit of the portfolio currency are grouped as small balances in the dropdown.

## Power and HomeWizard

Power has its own settings, menu item and collector. Multiple meters can use the [HomeWizard local API](https://api-documentation.homewizard.com/docs/getting-started/):

- v1: `GET http://device/api/v1/data`, reading `active_power_w`. Enable Local API in the HomeWizard app.
- v2: `GET https://device/api/measurement`, reading `power_w`, with `X-Api-Version: 2` and a device-specific bearer token kept in Keychain.

For v2, the app validates TLS against the [official HomeWizard public CA](https://api-documentation.homewizard.com/docs/v2/authorization/#certificate), bundled as `scripts/homewizard-ca.pem`. It verifies the certificate name `appliance/<product type>/<serial>` rather than the device IP. Certificate checking is never disabled. Local connections resolve and validate the destination IP once, connect directly (without HTTP proxies), and do not follow redirects.

**Search for devices** uses native Bonjour for the [documented HomeWizard services](https://api-documentation.homewizard.com/docs/discovery/): `_hwenergy._tcp` (v1) and `_homewizard._tcp` (v2). A search lasts up to 12 seconds and can be stopped. Resolved service names, ports and TXT records prefill setup; the v2 certificate identity comes from the advertised `id`. Devices advertising both versions appear once, preferring v2. Existing meters are identified by serial number, hostname or resolved IP. Discovery does not add meters, enable an API or create credentials automatically. Watermeters/displays are listed without a power setup action. Search is limited to the local Bonjour network; permit Local Network access in macOS, or add a reachable meter by address.

Each meter is assigned to Pearl, Vast.ai, or monitoring only. Costs require current readings from all meters assigned to that provider. There are no manual wattage entries or fallback estimates. Whole-house P1 meters should normally be monitoring only. Select a specific meter for the Power menu item, or use Assigned loads (excluding monitor-only meters). Do not assign overlapping meters to the same equipment. Negative readings represent export and are displayed as negative watts, but cost projections do not include export credits.

The shared tariff has its own currency. Costs convert into the revenue display currency using the same USD/EUR rate, so changing a provider's currency never reinterprets the tariff. A missing exchange rate leaves net values unavailable. Zero tariffs and zero measured draw are valid; missing values remain unknown. An existing Vast `powerPrice` migrates once with its currency. Old `machineWatts`, `pearlWatts` and `vastMachineWatts` entries are ignored and omitted on the next preferences save. Clearing a migrated tariff does not restore it from the old field.

## Exchange rates

The revenue and power collectors read `GET https://api.frankfurter.dev/v1/latest?base=USD&symbols=EUR`, the European Central Bank reference rate, without any credential, and cache it for twelve hours in `rates.json`. This also supports a EUR tariff with USD revenue. A stale cached rate is kept while the service is unreachable; without any rate, revenue amounts stay in USD and costs that need conversion remain unavailable.

## Credential boundary

No credential is written to this repository, printed, included in command arguments or stored in the metrics cache. The app saves explicitly entered Vast, Kraken and HomeWizard keys in separate macOS Keychain entries and sends them to its collector over a private stdin pipe. Cloud tokens go only to fixed provider HTTPS endpoints; the Kraken private key only signs requests locally and is never sent. Each HomeWizard token goes only to its configured local device with certificate verification. Redirects are disabled. Error bodies and local-helper stderr are suppressed; errors shown in the UI are normalized. A configuration digest invalidates Pearl, Power and Kraken cache data after connection changes without caching URLs or tokens.

This is a local, unsandboxed macOS app because it integrates with installed CLI processes and account stores. Python 3 is a runtime prerequisite. The app bundle is ad-hoc signed for local use; a distribution build would need a stable signing identity and notarization.

## Expanded dropdown metrics

The seven-day GPU/storage/network/SLA breakdown is accumulated from the same validated complete-day rows as the seven-day total; today and referrals are excluded. Its components reconcile to that total.

Host details also preserve `earn_day`, `gpu_max_cur_temp` (degrees Celsius), `reliability2` (fraction displayed as a percentage), `cpu_name`, `listed`, and the listed hourly GPU price. Unknown optional fields remain absent. The daily host figure is labeled as Vast-reported earnings; its backend window is not used to calculate the seven-day daily average. Resident container counts include running containers.

The seven menu items have independent persistent settings and macOS autosave names for ordering. Provider SVGs are bundled template images; Pearl and Power use system symbols. The configuration design follows the independent categories and global/per-item controls in the [official iStat Menus guide](https://register.bjango.com/help/istatmenus7/welcome/).

## Earnings definitions

Vast reports USD. With Euro selected, amounts use the European Central Bank reference rate from api.frankfurter.dev, refreshed every 12 hours; while no rate is available they stay in USD.

| Metric | Definition |
| --- | --- |
| GPU rate · est. | Occupied GPUs × current listed hourly GPU price. Existing contracts and discounts may differ. Storage and network revenue are excluded from this estimate. |
| Today | Recorded rental earnings since 00:00 UTC, including GPU, storage, network and SLA adjustments. Referrals are excluded. |
| 7-day average | Total recorded rental earnings over the previous seven complete UTC days ÷ 7. Includes zero-earning days; excludes the incomplete current day. |
| Rented | Vast reports `current_rentals_running > 0`. Stored-only containers are displayed separately. |
| Utilization | GPU revenue earned in the ring period ÷ (listed GPU price × GPUs × hours in the period), capped at 100%. Today means today so far in UTC; 7 and 30 days mean the previous complete UTC days. Rentals priced below the listing lower it. |
| Power cost | Assigned meter watts × 24 h × tariff / 1000. Net figures deduct this estimate: today for the hours elapsed since 00:00 UTC, the rate per hour, and the 7-day average per day. This extrapolates current draw, not historical metered usage. The Earnings setting shows gross, net or both columns; the menu bar follows net only when Net is selected. Missing costs show a dash, never gross labeled as net. |

Gross values are revenue before costs; net values subtract estimated electricity only. Hardware, tax and payout costs are not deducted. Hovering a machine row shows Vast's reported hourly average separately from the current price estimate, plus the provider's daily earnings figure, listed price, GPU temperature, reliability and CPU when available. Resident container counts include running containers and must not be added to running counts. The chart covers the previous seven complete UTC days; its tooltip shows the GPU, storage and network split.

## Refresh and freshness

The ChatGPT item shows Codex subscription allowances using its documented app-server interface. Claude and Cursor use the account endpoints their clients use; these are not stable public APIs. They may require adapter updates when providers change them. Sign in again using each provider's own app when credentials expire; Information Bar does not rotate their tokens or send inference requests.

ChatGPT, Cursor, Vast, Pearl, Kraken and Power refresh every minute by default, or every two minutes when configured in General. Disabled Vast and Kraken items are skipped during automatic refreshes, including their Keychain lookups; explicit refreshes from their settings still work. Claude refreshes at most once every five minutes, including manual refreshes (the two-minute schedule checks it every six minutes). Server backoff is respected; without a server hint, sign-in errors retry after a minute and other provider errors after five. Last successful metrics remain visible with a stale label if a refresh fails, and disappear from the menu bar summary. Pearl's independent metrics and each HomeWizard reading become unavailable individually. Hiding the Power item does not stop readings used for revenue calculations. Cache files contain normalized metrics only and have mode `0600` under `~/Library/Application Support/Information Bar/Cache`.
