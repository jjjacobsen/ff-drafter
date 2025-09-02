from __future__ import annotations

import curses
import difflib
import sys
from dataclasses import dataclass, field

import pandas as pd

# Minimal, dependency-free interactive shell to help during an auction draft.
# - Reads salaries.csv into a DataFrame
# - Fuzzy-find players by name; then arrow keys to select from matches
# - Show suggested salary from CSV
# - Select/create a team (with fuzzy find) and enter purchase price
# - Track each team's budget, remaining, and positions filled


DEFAULT_BUDGET = 200  # per team, used when auto-creating a team
MY_TEAM_NAME = "me"

# Caps to avoid extreme swings
CAP_MIN = 0.6
CAP_MAX = 1.3

# Need-based multipliers (applied for my team only)
NEED_MULT_HIGH = 1.10  # need base slot
NEED_MULT_MED = 1.02  # only flex remaining
NEED_MULT_LOW = 0.85  # base + flex filled

# Supply/Inflation tuning
SUPPLY_WEIGHT = 0.25  # scarcity factor contribution when base need
SUPPLY_WEIGHT_MED = 0.10
TIER_GAP_WEIGHT = 0.5  # converts price gap ratio into factor
INFLATION_MIN = 0.85
INFLATION_MAX = 1.15


@dataclass
class Team:
    name: str
    budget: int = DEFAULT_BUDGET
    spent: int = 0
    roster: dict[str, int] = field(default_factory=dict)

    @property
    def remaining(self) -> int:
        return self.budget - self.spent


def load_salaries(path: str = "salaries.csv") -> pd.DataFrame:
    df = pd.read_csv(path)
    # Normalize columns by lowercasing their names
    df.columns = [c.strip().lower() for c in df.columns]
    # Validate expected columns
    for required in ("name", "salary"):
        if required not in df.columns:
            raise ValueError(f"Missing required column '{required}' in {path}")
    # Position is optional
    if "position" not in df.columns:
        df["position"] = "UNKNOWN"
    return df


def fuzzy_matches(
    query: str,
    choices: list[str],
    limit: int = 15,
    min_ratio: int = 40,
) -> list[str]:
    q = query.strip().lower()
    if not q:
        # Return the first N choices if no query
        return choices[:limit]

    scored: list[tuple[int, str]] = []
    for ch in choices:
        cl = ch.lower()
        # Prefer substring matches
        if q in cl:
            # Higher score for earlier matches
            idx = cl.find(q)
            score = 200 - idx  # ensure substring matches outrank difflib-only
        else:
            ratio = int(difflib.SequenceMatcher(None, q, cl).ratio() * 100)
            score = ratio
        if score >= min_ratio:
            scored.append((score, ch))

    scored.sort(key=lambda t: t[0], reverse=True)
    return [c for _, c in scored[:limit]]


def curses_select(options: list[str], title: str = "Select") -> str | None:
    if not options:
        return None

    def _menu(stdscr):
        curses.curs_set(0)
        idx = 0
        while True:
            stdscr.erase()
            maxy, maxx = stdscr.getmaxyx()
            header = title[: maxx - 1]
            stdscr.addstr(0, 0, header)
            stdscr.addstr(1, 0, "Use ↑/↓ and Enter. q/Esc to cancel.")
            start_line = 3
            visible = max(1, min(len(options), maxy - start_line - 1))
            top = max(0, min(idx - visible // 2, len(options) - visible))

            for i in range(visible):
                opt_i = top + i
                if opt_i >= len(options):
                    break
                prefix = "> " if opt_i == idx else "  "
                text = (prefix + options[opt_i])[: maxx - 1]
                if opt_i == idx:
                    stdscr.attron(curses.A_REVERSE)
                    stdscr.addstr(start_line + i, 0, text)
                    stdscr.attroff(curses.A_REVERSE)
                else:
                    stdscr.addstr(start_line + i, 0, text)

            key = stdscr.getch()
            if key in (curses.KEY_UP, ord("k")):
                idx = max(0, idx - 1)
            elif key in (curses.KEY_DOWN, ord("j")):
                idx = min(len(options) - 1, idx + 1)
            elif key in (curses.KEY_ENTER, 10, 13):
                return options[idx]
            elif key in (27, ord("q")):
                return None

    try:
        return curses.wrapper(_menu)
    except Exception:
        # Fallback to simple numeric choice if curses fails (e.g., non-tty)
        print(title)
        for i, opt in enumerate(options, 1):
            print(f"  {i}. {opt}")
        try:
            sel = input("Select number (blank cancels): ").strip()
        except KeyboardInterrupt:
            return None
        if not sel.isdigit():
            return None
        idx = int(sel) - 1
        if 0 <= idx < len(options):
            return options[idx]
        return None


def curses_select_kv(
    options: list[tuple[str, str]],
    title: str = "Select",
) -> str | None:
    """Select from (label, value) options; returns value or None."""
    if not options:
        return None
    labels = [lbl for (lbl, _val) in options]
    chosen = curses_select(labels, title=title)
    if chosen is None:
        return None
    for lbl, val in options:
        if lbl == chosen:
            return val
    return None


def _fmt_player_label(name: str, team: str, pos: str, width: int = 28) -> str:
    # Fixed-width alignment for name; compact columns for team/pos
    clipped = (name[: width - 1] + "…") if len(name) > width else name
    return f"{clipped.ljust(width)}  {team.ljust(4)}  {pos}"


def prompt_player(df: pd.DataFrame, drafted: set[str]) -> pd.Series | str | None:
    names = [n for n in df["name"].astype(str).tolist() if n not in drafted]
    if not names:
        print("All players drafted. Draft complete.")
        return None

    while True:
        try:
            raw = input("Player (or 'teams'/'undo'/'q'): ").strip()
        except (EOFError, KeyboardInterrupt):
            return None

        if not raw:
            continue
        if raw.lower() in {"q", "quit", "exit"}:
            return None
        if raw.lower() in {"teams", ":teams"}:
            return "__SHOW_TEAMS__"  # sentinel handled by caller
        if raw.lower() in {"undo", ":undo"}:
            return "__UNDO__"

        matches = fuzzy_matches(raw, names, limit=20)
        if not matches:
            print("No matches. Try again.")
            continue
        if len(matches) == 1:
            chosen_name = matches[0]
        else:
            # Build labels with team and position for clearer selection
            options: list[tuple[str, str]] = []
            for n in matches:
                # Use the first match for name; assume unique
                row = df[df["name"] == n].iloc[0]
                team = str(row.get("proteam", "")).upper()
                pos = str(row.get("position", ""))
                label = _fmt_player_label(n, team, pos)
                options.append((label, n))

            chosen_name = curses_select_kv(options, title="Select player")
            if not chosen_name:
                continue

        row = df[df["name"] == chosen_name].iloc[0]
        return row


def prompt_team(teams: dict[str, Team]) -> Team | None:
    existing = list(teams.keys())
    while True:
        try:
            raw = input("Team: ").strip()
        except (EOFError, KeyboardInterrupt):
            return None
        if not raw:
            continue

        # Exact hit
        if raw in teams:
            return teams[raw]

        suggestions = fuzzy_matches(raw, existing, limit=10)
        create_label = f"Create new team '{raw}'"
        options = ([create_label, *suggestions]) if raw not in existing else suggestions

        if not options:
            # No suggestions, create directly
            team = Team(name=raw)
            teams[raw] = team
            return team

        choice = curses_select(options, title="Select team or create new")
        if not choice:
            # Cancelled selection; ask again
            continue

        if choice == create_label:
            team = Team(name=raw)
            teams[raw] = team
            return team
        else:
            # Existing team selected
            return teams[choice]


def prompt_price(default: int | None) -> int | None:
    while True:
        try:
            raw = input(
                f"Price{f' [${default}]' if default is not None else ''}: "
            ).strip()
        except (EOFError, KeyboardInterrupt):
            return None
        if raw == "" and default is not None:
            return int(default)
        if raw.isdigit():
            return int(raw)
        print("Enter a whole number (e.g., 15)")


def print_team_summary(teams: dict[str, Team]) -> None:
    if not teams:
        print("No teams yet.")
        return
    print("\nTeams:")
    for t in sorted(teams.values(), key=lambda x: x.name.lower()):
        roster_bits = (
            ", ".join(f"{pos}:{cnt}" for pos, cnt in sorted(t.roster.items()))
            or "no picks"
        )
        print(f"- {t.name}: spent ${t.spent}, remaining ${t.remaining} | {roster_bits}")
    print()


# --- Pricing Engine ---


def _clamp(v: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, v))


def _requirements() -> dict[str, int]:
    # FLEX is separate and satisfied by RB/WR/TE overflow
    return {"QB": 1, "RB": 2, "WR": 2, "TE": 1, "D/ST": 1, "K": 1, "FLEX": 1}


def _flex_used(roster: dict[str, int], req: dict[str, int]) -> int:
    overflow = 0
    for pos in ("RB", "WR", "TE"):
        have = roster.get(pos, 0)
        overflow += max(0, have - req.get(pos, 0))
    return min(req.get("FLEX", 0), overflow)


def _need_level(team: Team, pos: str, req: dict[str, int]) -> str:
    pos = pos.upper()
    have = team.roster.get(pos, 0)
    base_need = max(0, req.get(pos, 0) - have)
    if base_need > 0:
        return "high"
    flex_left = req.get("FLEX", 0) - _flex_used(team.roster, req)
    if pos in {"RB", "WR", "TE"} and flex_left > 0:
        return "med"
    return "low"


def _inflation_factor(
    teams: dict[str, Team],
    df: pd.DataFrame,
    drafted: set[str],
) -> float:
    # With new salary model: sum(base salaries) == total team budgets.
    # Inflation simplifies to: spendable_money_left / remaining_fair_value
    remaining_value = float(df.loc[~df["name"].isin(drafted), "salary"].sum())
    if remaining_value <= 0 or not teams:
        return 1.0

    spendable = float(sum(t.remaining for t in teams.values()))
    raw = spendable / remaining_value
    return _clamp(raw, INFLATION_MIN, INFLATION_MAX)


def _supply_factor(
    df: pd.DataFrame,
    drafted: set[str],
    pos: str,
    need_level: str,
    pos_initial_counts: dict[str, int],
) -> float:
    pos = pos.upper()
    init_cnt = pos_initial_counts.get(pos)
    if not init_cnt or init_cnt <= 0:
        return 1.0

    remaining_cnt = int(
        df.loc[(df["position"].str.upper() == pos) & (~df["name"].isin(drafted))].shape[
            0
        ]
    )
    scarcity = max(0.0, 1.0 - (remaining_cnt / init_cnt))
    if need_level == "high":
        return 1.0 + scarcity * SUPPLY_WEIGHT
    if need_level == "med":
        return 1.0 + scarcity * SUPPLY_WEIGHT_MED
    return 1.0


def _tier_gap_factor(
    df: pd.DataFrame,
    drafted: set[str],
    pos: str,
    player_salary: int,
    player_name: str,
) -> float:
    # Mild boost if next-best at position is a big drop
    pos_mask = df["position"].str.upper() == pos.upper()
    remaining = df.loc[
        pos_mask & (~df["name"].isin(drafted)), ["name", "salary"]
    ].copy()
    if remaining.empty:
        return 1.0
    remaining.sort_values("salary", ascending=False, inplace=True)
    names = remaining["name"].tolist()
    try:
        idx = names.index(player_name)
    except ValueError:
        # If player already drafted or not found, no effect
        return 1.0
    cur = max(1, int(player_salary))
    if idx + 1 >= len(remaining):
        return 1.0
    nxt = int(remaining.iloc[idx + 1]["salary"]) or 0
    gap_ratio = max(0.0, (cur - nxt) / float(cur))
    return 1.0 + min(0.2, gap_ratio * TIER_GAP_WEIGHT)


def _tier_scarcity_factor(
    df: pd.DataFrame,
    drafted: set[str],
    pos: str,
    tier_value: str | int | float | None,
    need_level: str,
) -> float:
    # If I have a high (or medium) need and there are very few remaining
    # players in this tier for this position, nudge the price up a bit.
    if tier_value is None or tier_value == "" or pd.isna(tier_value):
        return 1.0
    pos_up = pos.upper()
    rem = df.loc[
        (df["position"].str.upper() == pos_up)
        & (~df["name"].isin(drafted))
        & (df.get("tier").astype(str) == str(tier_value)),
        ["name"],
    ]
    remaining_in_tier = int(rem.shape[0])
    if need_level == "high":
        if remaining_in_tier <= 1:
            return 1.10
        if remaining_in_tier <= 3:
            return 1.05
    if need_level == "med" and remaining_in_tier <= 1:
        return 1.05
    return 1.0


def adjusted_salary(
    row: pd.Series,
    df: pd.DataFrame,
    teams: dict[str, Team],
    drafted: set[str],
    pos_initial_counts: dict[str, int],
    my_team_name: str = MY_TEAM_NAME,
) -> int:
    base = int(row.get("salary", 0) or 0)
    pos = str(row.get("position", "")).upper()
    name = str(row.get("name", ""))
    tier_value = row.get("tier") if "tier" in row else None

    mult = 1.0

    # Inflation
    mult *= _inflation_factor(teams, df, drafted)

    # Ensure my team exists for need eval
    my_team = teams.get(my_team_name)
    if my_team is None:
        my_team = Team(name=my_team_name)
        teams[my_team_name] = my_team

    # Need factor
    req = _requirements()
    level = _need_level(my_team, pos, req)
    if level == "high":
        mult *= NEED_MULT_HIGH
    elif level == "med":
        mult *= NEED_MULT_MED
    else:
        mult *= NEED_MULT_LOW

    # Supply factor (thinness)
    mult *= _supply_factor(df, drafted, pos, level, pos_initial_counts)

    # Tier-gap factor (mild)
    mult *= _tier_gap_factor(df, drafted, pos, base, name)

    # Tier scarcity factor (for my need)
    mult *= _tier_scarcity_factor(df, drafted, pos, tier_value, level)

    # Final clamp and int conversion
    mult = _clamp(mult, CAP_MIN, CAP_MAX)
    return round(base * mult)


def main():
    print("Starting new draft. Reading salaries.csv …")
    try:
        df = load_salaries("salaries.csv")
    except Exception as e:
        print(f"Failed to read salaries.csv: {e}")
        sys.exit(1)

    drafted: set[str] = set()
    teams: dict[str, Team] = {}

    # Precompute engine baselines
    pos_initial_counts: dict[str, int] = (
        df["position"].str.upper().value_counts().to_dict()
    )
    # history items: (player_name, position, price, team_name)
    history: list[tuple[str, str, int, str]] = []

    name_col = "name"
    pos_col = "position"
    salary_col = "salary"

    while True:
        sel = prompt_player(df, drafted)
        if sel is None:
            print("Exiting draft.")
            break
        # If sel is our sentinel string, show teams and continue
        if isinstance(sel, str) and sel == "__SHOW_TEAMS__":
            print_team_summary(teams)
            continue
        if isinstance(sel, str) and sel == "__UNDO__":
            if not history:
                print("Nothing to undo.")
                continue
            last_player, last_pos, last_price, last_team = history.pop()
            if last_player in drafted:
                drafted.remove(last_player)
            team_obj = teams.get(last_team)
            if team_obj:
                team_obj.spent = max(0, team_obj.spent - last_price)
                if last_pos in team_obj.roster:
                    new_cnt = max(0, team_obj.roster[last_pos] - 1)
                    if new_cnt == 0:
                        del team_obj.roster[last_pos]
                    else:
                        team_obj.roster[last_pos] = new_cnt
            print(f"Undid: {last_player} from {last_team} (-${last_price}).")
            print_team_summary(teams)
            continue

        # Otherwise, sel should be a pandas Series for the chosen player
        if not isinstance(sel, pd.Series):
            print("Unexpected selection type; please try again.")
            continue

        player_name = str(sel[name_col])
        player_pos = str(sel[pos_col]) if pos_col in sel else "UNKNOWN"
        suggested = (
            int(sel[salary_col])
            if salary_col in sel and pd.notnull(sel[salary_col])
            else None
        )

        player_tier = sel.get("tier") if "tier" in sel else None
        tier_str = (
            f" — Tier {player_tier}"
            if player_tier is not None and not pd.isna(player_tier)
            else ""
        )
        print(f"Selected: {player_name} ({player_pos}){tier_str}")
        if suggested is not None:
            adj = adjusted_salary(
                sel,
                df,
                teams,
                drafted,
                pos_initial_counts,
                MY_TEAM_NAME,
            )
            print(f"Suggested salary: ${adj} (base ${suggested})")
        else:
            print("Suggested salary: n/a")

        # Ask for price first, then team
        price = prompt_price(adj if suggested is not None else None)
        if price is None:
            print("Cancelled. Back to player search.")
            continue

        team = prompt_team(teams)
        if team is None:
            print("Cancelled. Back to player search.")
            continue

        # Update team and track history for undo
        team.spent += price
        team.roster[player_pos] = team.roster.get(player_pos, 0) + 1
        drafted.add(player_name)
        history.append((player_name, player_pos, price, team.name))

        print(
            f"Assigned {player_name} to {team.name} for ${price}. "
            f"Remaining for {team.name}: ${team.remaining}."
        )

        # Optional quick view after each assignment
        print_team_summary(teams)


if __name__ == "__main__":
    main()
