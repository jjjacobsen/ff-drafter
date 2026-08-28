# Dynamic VORP optimizer

## Scope

The optimizer calculates a bid recommendation from ESPN projected fantasy points, roster demand, and remaining auction money. It does not estimate market prices or plan complete future rosters for the user

It recalculates after synchronized roster or budget changes. BID and CLOCK updates for the same nominee only compare the next bid with the stored maximum

ESPN `draftAuctionValue` is not an optimizer input. It remains informational in the UI and can help rank nomination candidates

## League replacement levels

The optimizer counts every unfilled starter slot across all teams. Exact and flex slots are included. Bench, reserve, and IR slots are excluded from paid starter demand

One polynomial maximum-points assignment puts remaining players into the open league starter slots. It uses the same ESPN slot compatibility rules as roster normalization. Zero-point dummy players let the assignment represent a position without enough remaining players

The assignment also determines the expected positional mix of the complete league starting lineups. Open bench slots are distributed across those positions in proportion to that mix. Whole bench slots use largest remainders and position names break ties. Already drafted starters remain part of the positional weights, so the mix stays stable as the draft advances

For each position, expected remaining demand is its selected remaining starters plus its allocated open bench slots. The replacement projection is the lowest projection among the top remaining players that meet this total demand. This bench-aware cutoff prevents all discretionary money from being concentrated in starters. A position without expected demand has a zero replacement level. Missing ESPN projections are also zero

A remaining player's VORP is:

```text
max(projected points - position replacement points, 0)
```

Projected points are stored to one-thousandth of a point for deterministic assignment and dollar calculations

## Dynamic fair value

The optimizer calculates money from current mechanical draft state:

```text
remaining discretionary dollars = max(
    sum of team remaining budgets - all open roster slots,
    0
)
```

All open roster slots reserve `$1`, including bench slots

The discretionary dollars are allocated across positive VORP from players expected to fill remaining starter and bench demand. Each selected player starts at `$1`. Whole dollars use largest remainders, with lower player IDs breaking equal remainders. This keeps the allocation exact and stable

A remaining player outside the expected draftable pool has a `$1` fair value. A player below his position replacement level has a zero maximum bid

Completed sales affect only team budgets, league money, roster occupancy, and player availability. Their prices are not compared with ESPN values

## Personal roster fit

A second maximum-points assignment finds the user's best current starting lineup. It can move owned players between all compatible exact and flex starter slots. A second assignment adds the nominee and measures the projected-point gain

The nominee is a starter when he fills an open compatible starter slot or increases the best starting-lineup projection. Otherwise, he is a bench player and his maximum is capped at `$1`

The recommendation stores:

- Projected season points
- Position replacement points
- VORP points
- Personal starting-lineup marginal points
- Dynamic fair value
- Starter or bench role
- ESPN legal maximum
- Actionable maximum bid

## Maximum bid and action

The legal maximum reserves `$1` for every other empty roster slot:

```text
legal max = user remaining budget - other empty roster slots
max bid = min(dynamic fair value, legal max)
```

A player without a compatible open roster slot has a zero maximum. A player below replacement also has a zero maximum. D/ST has an explicit `$1` cap

The action is:

- `BID` when the next bid does not exceed `max`
- `HOLD` when the user's team already leads
- `PASS` otherwise

An auction with no leader and a zero current bid has a `$1` next bid. Otherwise, the next bid is the current bid plus `$1`

## Nomination evaluation

Nomination evaluation remains bounded to the eight highest ESPN auction values. It prefers a bench-role player, then the higher of ESPN value and dynamic fair value, then lower personal marginal points. The selected player opens at `$1`

This uses ESPN value only as an opponent-interest heuristic. It does not affect player quality or bid limits
