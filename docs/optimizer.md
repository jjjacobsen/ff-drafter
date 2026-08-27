# Dynamic roster optimizer

## Scope

The optimizer is a read-only advisor. It does not place bids or nominate players

It recalculates after synchronized draft updates and stores one recommendation for the current auction player in draft state. BID and CLOCK updates for the same player reuse the cached recommendation and only update the action

## Inputs

The optimizer uses:

- ESPN `draftAuctionValue` directly as player utility
- The user's remaining budget and owned players
- Every configured ESPN roster slot
- All undrafted players in the ESPN catalog
- The current auction player, bid, and leading team

It does not use ESPN value as a projected purchase cost. It does not use sale prices to change player values. Other teams' rosters only determine which players are no longer available

D/ST utility and its maximum bid are always `$1`

## Roster assignment

The optimizer solves two complete roster assignments. The first excludes the nominee. The second includes the nominee as a mandatory player

Each roster slot is one assignment row and each candidate player is one assignment column. A rectangular Hungarian matcher enforces one player per slot and at most one slot per player. Incompatible slot and position edges cannot be selected

Owned players are mandatory in both assignments and can move to any compatible slot. The nominee is also mandatory in the second assignment. A bonus larger than every possible utility difference forces mandatory players into the maximum assignment, and the optimizer verifies that every mandatory player was selected

Starter slots have utility weight `4`. ESPN bench, reserve, and extended-designated-reserve slots `20`, `22`, and `24` have utility weight `1`. The matcher maximizes the exact weighted ESPN utility of the complete roster

Before matching, undrafted candidates are sorted deterministically and reduced to the top roster-size values at each exact position. A lower player at the same position has identical slot compatibility and cannot improve a maximum-utility assignment. Owned players and the forced nominee are never removed by this reduction

For `S` roster slots and `C` retained candidates, each rectangular Hungarian solve takes `O(S²C)` time and `O(S + C)` working memory. Catalog collection and deterministic reduction take `O(P log P)` time for `P` undrafted players. There is no recursion or enumeration by budget, player combination, or plan frontier

## Recommendation values

The main screen shows:

- `target`: `min(max(ESPN value, $1), max bid)`
- `max`: The nominee's proportional spending allocation, limited by the legal maximum
- `legal`: Remaining budget minus `$1` for every other empty roster slot
- `replacement`: The nominee's ESPN value minus his utility-equivalent marginal improvement
- `marginal`: The weighted score difference between the forced and unforced assignments, divided by `4` when the nominee is a starter or `1` when he is on the bench

If the forced assignment has less weighted utility than the assignment without the nominee, maximum bid is `$0`

The action is:

- `BID` when the next bid does not exceed the maximum
- `HOLD` when the user's team already leads
- `PASS` when the next bid exceeds the maximum or no complete compatible assignment exists

An auction with no leader and a zero current bid has a `$1` next bid. Otherwise, the next bid is the current bid plus `$1`

## Spending pace

The forced assignment identifies the future players who fill the user's empty slots. The optimizer reserves `$1` for each empty slot, then distributes all discretionary dollars across those selected future players in proportion to their slot-weighted ESPN value above the `$1` baseline

Integer remainders use deterministic player ID and slot order. If all eligible selected future weights are zero, discretionary dollars are divided equally. D/ST receives no discretionary dollars and remains capped at `$1`

The nominee's allocation is its maximum bid, clamped to the legal maximum. Spending pace therefore moves the remaining budget toward the best players in the current exact roster assignment without treating ESPN utility as a predicted purchase cost

## Safety rules

The optimizer never recommends more than ESPN's legal maximum. It reserves at least `$1` for every other empty roster slot and returns a zero maximum for an incompatible or incomplete roster assignment
