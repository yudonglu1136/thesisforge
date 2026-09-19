# IOT / SPOT: bounded current economic models

Valuation date: 2026-09-05. Financial data frozen through 2026-08-28. FX: 2026-09-04 ECB. These are current analyst scenarios, not historical releases or issuer price targets. No market quote is a valuation input.

| Issuer | Current route | Bear | Base | Bull |
| --- | --- | ---: | ---: | ---: |
| IOT | Explicit NTM EV/sales; **not DCF** | $20.87 | $36.42 | $52.25 |
| SPOT | Parent-economic FCFE / EUR cost of equity | $199.83 | $282.59 | $375.83 |

These ranges are assumption scenarios, not confidence intervals. Parent integration still requires current-only publication gates and the full independent release audit. No database was written during this work.

## SPOT

Latest financial period: June 30, 2026, available August 4. The audited 2025 20-F and H1 2026 6-K give the following EUR-million TTM bridge:

| Metric | FY2025 | H1 2026 | Less H1 2025 | TTM |
| --- | ---: | ---: | ---: | ---: |
| Operating cash | 2,933 | 1,652 | 1,248 | 3,337 |
| Cash PPE | 61 | 25 | 16 | 70 |
| Financing lease principal | 73 | 36 | 44 | 65 |
| SBC cash-flow addback | 247 | 142 | 115 | 274 |
| Management capex | 61 | 34 | 16 | 79 |

Baseline FCFE = 3,337 − 70 − 65 − 274 − 9 = **€2,919m**.

The €9m management-capex / cash-PPE difference remains an explicit conservative reconciliation reserve, not a verified cash expenditure. It must not be hidden or described as a known lease cash payment. Restricted-cash releases are not extrapolated as recurring income. Cash interest and tax are already in CFO. There is no extra net-debt deduction, cash addition, dividend addition or repurchase premium.

Ordinary common shares: 210,241,268 issued less 4,657,063 treasury = **205,584,205**, not the provider's 205,788,241 quarterly weighted-average EPS count. The evidence separately retains Dec2025 205,832,527 and Mar2026 205,620,061 counts.

Share compensation convention: recurring SBC is a cash-equivalent cost, with no second denominator charge for unvested awards. Already-exercisable legacy options receive a conservative one-full-share-per-option claim bound of 2,789,877 shares with no exercise proceeds. Denominator: **208.374082m**. This claim bound is not diluted EPS or an assertion that every option will be exercised.

Base DCF: five rolling years; annual FCFE growth 12%, 10%, 8%, 6%, 4%; EUR nominal Ke 10%; terminal growth 2.5%; end-year discounting t=1…5; terminal value at t=5 uses the next year's FCFE. Ke is an explicit analyst hurdle, not a claimed empirically estimated CAPM. The EUR equity value is translated at current ECB USD/EUR 1.1622. The preserved source financial conversion at August4 was 1.1515; these are separate dates and operations.

No finance fair-value gains or normalized EPS enter this DCF.

## IOT

Latest included financial period: May 2, 2026 (FY2027 Q1), available June 9. September 3 earnings are outside the frozen August28 financial dataset and are not silently used. The current valuation must display this financial period, not imply that FY2027 Q2 has been consumed.

TTM cash diagnostic from FY2026 + Q1 FY2027 − Q1 FY2026:

`265.011 CFO − 30.082 cash PPE − 315.375 SBC − 9.5 capitalized SBC − 0.647 other-financing cash reserve = −$90.593m`

The capitalized-SBC disclosures are rounded issuer figures. Other financing outflows are conservatively reserved in full; they are not claimed to be a precisely isolated finance-lease total. Operating lease cash, device investment and deferred commissions are already reflected in CFO. The legal arbitration award is not treated as recurring operating income or revenue.

The negative diagnostic is **not** given a positive perpetual DCF. Instead the finite model uses explicit 15%/25%/30% forward revenue growth and 6x/10x/14x NTM sales scenarios. Multiples are analyst assumptions inside the existing software-profile range, not purported observed peer medians.

May2 issued shares: 370,981,108 A + 211,728,974 B + zero C = **582,710,082**, matching the current provider count. Add a full-delivery bound for 5,396,988 options, 21,744,310 RSUs and 1,015,333 disclosed potential ESPP shares. A separate 2% next-year new-grant dilution assumption is not a second count of these existing awards. No legacy-SBC cash charge is subtracted again from EV/sales equity value.

All $218.986m cash is reserved for operations; $585.333m short-term plus $477.072m long-term marketable securities enter the EV-to-equity bridge. The $69.020m provider debt number is disclosed operating-lease liabilities, not financial borrowings. The multiple convention retains rent as an operating cost; those leases are not deducted again as financial debt.

## Reproduction and safety

Implementation: `server/guruCurrentEconomicValuation.js`; independent recomputation: `server/guruCurrentEconomicValuationAudit.js`; dated official sources and raw bridge: `server/config/guru-current-economic-evidence.json`.

Run from the repo with the project Node runtime:

```sh
node scripts/evaluate-reviewed-current-guru.mjs output/guru-valuation-expansion-2026-09-05/input-stage/candidate-source.sqlite output/guru-valuation-expansion-2026-09-05/current-ecb-reference-fx.json
node --test server/guruCurrentEconomicValuation.test.js server/reviewedShareCountAudit.test.js server/guruValuationUniverse.test.js
```

Verified against real source input in read-only mode: both current model builds succeeded and independently recomputed with zero failures. 47 combined JavaScript tests and 9 existing Python share-correction tests passed. Tests reject wrong period, future dates, ARQ masquerading as TTM, unknown/inverted FX, different source amounts, share-factor errors, duplicated claims/debt/cash, terminal timing mistakes and source tampering. Changing market price does not change either value.

The reviewed-batch manifest records `currentModelReview` but preserves generic `reviewStatus=unreviewed`. This is intentional: current source reconciliation is not authorization to publish old unadjusted cash-flow histories as audited curves. Earlier observations remain unchanged and independently dated.
