# Dynamic roster optimizer

## Scope

The optimizer calculates roster plans and bid recommendations without performing network actions. The ESPN worker uses the stored recommendation to place bids and evaluate nominations

It recalculates after synchronized draft changes. BID and CLOCK updates for the same player reuse the cached recommendation and only update the action

## Values and expected costs

ESPN `draftAuctionValue` is player utility. D/ST utility is always `$1`

Future purchase cost starts from ESPN value and follows the league's observed auction market. The optimizer calculates a discretionary-dollar inflation ratio from every completed purchase:

- Expected discretionary dollars are `max(ESPN value - $1, 0)`
- Actual discretionary dollars are `max(purchase cost - $1, 0)`
- A `$100` expected and `$100` actual prior stabilizes the ratio early in the draft
- A player's expected cost is `$1` plus rounded ESPN discretionary value multiplied by that ratio

Adjusted and undone purchases automatically change the ratio because the calculation reads the current rosters. D/ST expected cost remains `$1`

The user's realized difference is owned ESPN value minus actual purchase cost. A complete plan's final planned difference adds future ESPN value and subtracts future expected cost

## Bounded roster planning

The optimizer creates one baseline plan that excludes the nominee and one forced plan that includes the nominee. Owned players are mandatory in both plans. The nominee is mandatory in the forced plan. Every player is assigned to one compatible ESPN roster slot, and every slot must be filled

Planning uses an iterative fixed-width beam. It does not use recursion or an unbounded Pareto frontier. At each assignment step it retains at most 32 partial plans:

- 20 plans selected for roster quality
- Up to 8 additional plans selected for planned difference
- Remaining capacity selected for minimum expected spend

The planner supports up to 32 configured roster slots. To bound branching, each exact position keeps its 16 highest-value undrafted players plus enough lowest-cost players to fill the roster. Owned players and the forced nominee are never removed

An exact polynomial assignment also finds the minimum-expected-cost complete assignment in this reduced candidate set. Owned players and the forced nominee remain mandatory. If its minimum cost exceeds the remaining budget, no affordable plan exists in the reduced set. If the quality beam loses every complete assignment, the planner returns this minimum-cost assignment

Every complete plan must fit the user's remaining budget. If any retained baseline plan can finish at a planned difference of at least `+$12`, lower-difference baseline plans are not eligible and the forced plan must preserve that floor. If the baseline cannot reach the floor, the planner selects roster quality without trying to maximize an unreachable difference

Eligible plans use this exact lexicographic order:

1. Higher starter ESPN value
2. Higher bench ESPN value
3. Higher planned difference
4. Lower expected spend
5. Lower player IDs in roster-slot order

The fixed beam and bounded candidate reduction are deliberate responsiveness limits. They approximate the global quality optimum when a discarded partial plan would later become best. The minimum-cost fallback is exact only for the reduced candidate set. Every returned plan is complete and budget-feasible

## Nominee eligibility and displayed values

The forced plan reserves the nominee's inflation-adjusted expected cost, limited by the legal maximum. This prevents the rest of the planned roster from consuming money that should remain available for the nominee. If no affordable completion exists at that reservation, the planner retries with a `$1` reservation

A nominee is eligible only when the forced plan:

- Improves starter ESPN value, or
- Ties starter ESPN value without reducing bench ESPN value

The baseline and forced plans are solved independently. If no affordable baseline completion exists but the nominee enables one, the nominee is eligible under the same legal and budget limits. Its marginal value is its own ESPN value, and it gets no credit for avoided baseline cost

The main screen shows:

- `max`: The only actionable optimizer limit
- `legal`: Remaining budget minus `$1` for every other empty slot. This is diagnostic because `max` already includes it
- `expected`: The nominee's inflation-adjusted expected market cost
- `marginal`: Starter ESPN value gained when starter value improves, otherwise bench ESPN value gained when starter value ties
- `Starter` or `Bench`: The nominee's projected forced-plan role

The recommendation action is:

- `BID` when the next bid does not exceed `max`
- `HOLD` when the user's team already leads
- `PASS` otherwise

An auction with no leader and a zero current bid has a `$1` next bid. Otherwise, the next bid is the current bid plus `$1`

## Maximum bid

For an eligible nominee, the optimizer derives four limits from the selected plans:

- Legal capacity: ESPN's legal maximum after reserving `$1` for every other empty slot
- Budget capacity: Remaining budget after expected cost for every forced-plan player except the nominee
- Protected-difference capacity: The greatest nominee cost that preserves `+$12` when the selected baseline plan already reaches that floor
- Roster-value capacity: Expected cost avoided by removing the baseline plan's displaced future spending, plus the nominee's marginal roster value

`max` is the greatest nonnegative whole-dollar amount within all applicable limits. When the selected baseline reaches `+$12`, the forced plan must preserve it and `max` is capped by protected-difference capacity. When the baseline cannot reach the floor, the floor cap does not apply. A temporary nominee discount does not activate the floor by itself. D/ST remains capped at `$1`

This values a nominee by the expected player cost it replaces and the roster improvement it adds. A major starter upgrade can therefore support a bid near ESPN value, while unused discretionary budget is not distributed proportionally across the roster

## Nomination evaluation

When it is the user's nomination turn, the application evaluates at most 8 full recommendations in descending ESPN-value order. It keeps players with a legal `$1` optimizer maximum and prefers the largest `ESPN value - max` difference. This selects a high-value player that the optimizer least wants to buy

Evaluation stops early when the next unseen ESPN value minus `$1` cannot beat the selected decoy score
