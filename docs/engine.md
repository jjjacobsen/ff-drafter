# Autonomous draft engine

## Scope

The engine always controls bids and nominations after ESPN state synchronization. It reads only `draft.State`, so a connection during an active draft uses the restored budgets, rosters, purchases, auction, and clock

The application disables ESPN autodraft when ESPN reports that it is active. This prevents ESPN and the local engine from bidding at the same time

## Maximum bid

Every available player starts with this maximum:

```text
ESPN value - $4
```

The engine then applies roster and budget adjustments

### Roster adjustment

A player has no extra roster penalty while the user has an open starter slot for that exact position

When only an open flex slot can start the player, the engine subtracts another `$2`. For example, a running back has this penalty after both RB slots are full while the flex slot remains open

When the player can only use the bench, the engine subtracts another `$4`. QB, D/ST, and K use an `$8` bench penalty because a second player at these positions usually has much less value

The engine returns a zero maximum when no compatible roster slot remains

### Budget adjustment

The engine compares the user's remaining budget with the average remaining budget of all other teams

The adjustment starts when the user has more than `$10` above that average. The engine adds `$1` to every maximum for each started `$5` above the threshold

```text
budget adjustment = ceil((user budget - other-team average - $10) / $5)
```

This adjustment increases bid limits as other teams spend money. It prevents the engine from keeping too much money while the useful player pool becomes smaller

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

When it is the user's turn, the engine waits five seconds before it nominates a player for `$1`

After every starter slot is full, it waits one second instead

The engine first finds positions that have no compatible open starter slot. It nominates the available player with the highest ESPN value from those filled positions. This sends valuable players that the user is less likely to need into the auction

If no starting position is filled, it nominates the available player with the highest ESPN value. A lower player ID resolves an equal ESPN value

The engine validates that the nominee is still available and that the user's roster and budget can accept the `$1` opening bid before it sends the nomination
