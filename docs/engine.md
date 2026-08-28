# Autonomous draft engine

## Scope

The engine always controls bids and nominations after ESPN state synchronization. It reads only `draft.State`, so a connection during an active draft uses the restored budgets, rosters, purchases, auction, and clock

The application disables ESPN autodraft when ESPN reports that it is active. This prevents ESPN and the local engine from bidding at the same time

## Maximum bid

Every available player starts below the ESPN value. The baseline discount changes in whole-dollar steps based on the draft phase and the player's ESPN value

The draft-phase discount uses the average remaining budget of all other teams:

| Other-team average | Discount |
| --- | ---: |
| `$101+` | `-4` |
| `$76–100` | `-3` |
| `$51–75` | `-2` |
| `$26–50` | `-1` |
| `$0–25` | `+0` |

The player-value discount prevents a fixed `$4` from consuming most of a low-value player's price:

| ESPN value | Discount limit |
| --- | ---: |
| `$36+` | `-4` |
| `$21–35` | `-3` |
| `$11–20` | `-2` |
| `$6–10` | `-1` |
| `$1–5` | `+0` |

The engine uses the smaller discount from these two tables

### Roster adjustment

A player has no extra roster penalty while the user has an open starter slot for that exact position

When only an open flex slot can start the player, the engine subtracts another `$2`. For example, a running back has this penalty after both RB slots are full while the flex slot remains open

While any priority starter slot is open, D/ST, K, and every player who can only use the bench have a hard `$1` maximum

The one configured starting QB slot is part of the priority lineup. After it is filled, another QB is treated exactly like any other possible bench player

The engine returns a zero maximum when no compatible roster slot remains

### Budget adjustment

The engine compares the user's remaining budget with the average remaining budget of all other teams

The maximum stays at its baseline through the first `$20` above that average. After that, each complete `$10` of additional gap adds `$1` to the maximum

This adjustment is capped at the ESPN value until the user's budget is more than twice the other-team average. After that point, each complete `$10` above twice the average permits another `$1` above the ESPN value

Roster penalties apply after the phase, player-value, and budget adjustments. This preserves the lower value of a player who can only use a flex slot

### Priority-starter spending plan

The engine directs its discretionary budget to the one starting QB slot and all RB, WR, TE, and RB/WR/TE flex starter slots

It reserves `$1` for every open non-priority slot, including D/ST, K, and bench slots

```text
priority budget = remaining budget - non-priority reserves
target per slot = priority budget / open priority starter slots
```

Both calculations use whole dollars. The engine recalculates them after every roster or budget change

The engine builds the highest-ESPN-value legal lineup for the open priority slots from all available players. A player receives spending pressure only when he belongs to this plan. Other players continue to use the normal value maximum

The target per slot acts as a floor on the normal maximum. The number of open priority slots limits that floor:

| Open priority slots | Forcing cap |
| --- | ---: |
| `4+` | ESPN value |
| `3` | ESPN value `+$2` |
| `2` | ESPN value `+$5` |
| `1` | Full target per slot |

The engine takes the higher of the normal maximum and the limited spending target. It then applies the flex penalty and legal maximum

This pressure has no effect early when good players already have normal maximums above the target. It becomes stronger as priority slots close and the remaining budget must fit into fewer important starters

### Late roster spending plan

After every priority starter slot is full, the engine releases the effective `$1` cap for the remaining roster plan

It divides the complete remaining budget across all empty D/ST, K, and bench slots. A maximum-value assignment selects the best available legal player for every remaining slot. Only those planned players receive the late spending target, so less valuable alternatives retain the `$1` maximum

```text
late target per slot = remaining budget / all empty roster slots
```

The late target has no ESPN-value cap. It starts near `$1` or `$2` and rises when players are purchased cheaply or fewer slots remain. The final roster nomination uses the complete final target, limited by ESPN's legal maximum, so unused auction money has a place to go

A QB can be selected for a bench slot during this phase, but it has no separate backup-QB rule

### Legal limit

The engine reserves `$1` for every empty roster slot after the current purchase

```text
legal maximum = remaining budget - other empty roster slots
```

The final maximum is the adjusted value limited by the legal maximum. A legal player has a minimum maximum of `$1`, so the engine can complete its roster

## Bid schedule

The engine does not bid while more than eight seconds remain

At eight seconds or less, it bids `$1` above the current bid when that next bid does not exceed the maximum. It does not bid when the user already leads

After another team makes a counter bid, the engine waits one second before it bids again. It reads all queued ESPN messages and validates the current player, leader, next bid, maximum, budget, roster space, and clock before it sends each bid

## Nominations

When it is the user's turn, the engine waits five seconds before it nominates a player. After every priority starter slot is full, it waits one second instead

The normal nomination strategy selects the highest ESPN-value player from a position with no compatible open starter slot. This sends valuable players that the user is less likely to need into the auction. If no starting position is filled, it nominates the available player with the highest ESPN value

When the priority spending floor raises any planned player's maximum, the engine stops nominating decoys. It nominates the highest ESPN-value player in the priority plan with a `$1` opening bid

When only one priority starter slot remains, the engine always nominates the best planned player. Its opening bid is the target per slot, limited by the player's final maximum

The late roster plan uses the same nomination behavior. It nominates planned players when their late target raises the maximum, and the final roster nomination opens at the complete remaining target. This gives both spending plans a way to use money when no opponent raises the price

A lower player ID resolves an equal ESPN value. The engine validates that the nominee is still available and that the user's roster and budget can accept the opening bid before it sends the nomination
