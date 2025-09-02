import os
from pathlib import Path

import pandas as pd
from dotenv import load_dotenv
from espn_api.football import League
from invoke import task


def _create_league(year: int):
    """Create ESPN League instance with environment variables."""
    return League(
        league_id=os.getenv("LEAGUE_ID"),
        year=year,
        espn_s2=os.getenv("ESPN_S2"),
        swid=os.getenv("SWID"),
    )


def _collect_all_players(league):
    """Collect all players from league teams and free agents."""
    players = {p.playerId: p for t in league.teams for p in t.roster}
    # add everyone else from the FA pool (big size pulls "all")
    for p in league.free_agents(size=2000):  # ESPN usually <1500 players
        players.setdefault(p.playerId, p)
    return list(players.values())


def collect_prev_season_data(year: int):
    """Collect previous season data for all players and return as DataFrame."""
    league = _create_league(year)
    players = _collect_all_players(league)

    player_data = []
    for p in players:
        # Skip players with invalid posRank (not > 0)
        if not (isinstance(p.posRank, int | float) and p.posRank > 0):
            continue

        breakdown = p.stats[0]["breakdown"]

        player_row = {
            # Basic info
            "playerId": p.playerId,
            "name": p.name,
            "proTeam": p.proTeam,
            "position": p.position,
            "posRank": p.posRank,
            # General stats
            "points": p.stats[0]["points"],
            "avg_points": p.stats[0]["avg_points"],
            "games_played": breakdown.get("210", 0.0),
            # Passing stats
            "passingAttempts": breakdown.get("passingAttempts", 0.0),
            "passingCompletions": breakdown.get("passingCompletions", 0.0),
            "passingIncompletions": breakdown.get("passingIncompletions", 0.0),
            "passingYards": breakdown.get("passingYards", 0.0),
            "passingTouchdowns": breakdown.get("passingTouchdowns", 0.0),
            "passingInterceptions": breakdown.get("passingInterceptions", 0.0),
            # Rushing stats
            "rushingAttempts": breakdown.get("rushingAttempts", 0.0),
            "rushingYards": breakdown.get("rushingYards", 0.0),
            "rushingYardsPerAttempt": breakdown.get("rushingYardsPerAttempt", 0.0),
            "rushingTouchdowns": breakdown.get("rushingTouchdowns", 0.0),
            "fumbles": breakdown.get("fumbles", 0.0),
            # Receiving stats
            "receivingReceptions": breakdown.get("receivingReceptions", 0.0),
            "receivingYards": breakdown.get("receivingYards", 0.0),
            "receivingTouchdowns": breakdown.get("receivingTouchdowns", 0.0),
            "receivingTargets": breakdown.get("receivingTargets", 0.0),
            "receivingYardsAfterCatch": breakdown.get("receivingYardsAfterCatch", 0.0),
            "receivingYardsPerReception": breakdown.get(
                "receivingYardsPerReception", 0.0
            ),
            # Kicking stats
            "madeFieldGoals": breakdown.get("madeFieldGoals", 0.0),
            "attemptedFieldGoals": breakdown.get("attemptedFieldGoals", 0.0),
            "missedFieldGoals": breakdown.get("missedFieldGoals", 0.0),
            "madeExtraPoints": breakdown.get("madeExtraPoints", 0.0),
            "attemptedExtraPoints": breakdown.get("attemptedExtraPoints", 0.0),
            "missedExtraPoints": breakdown.get("missedExtraPoints", 0.0),
            # Defense stats
            "defensive0PointsAllowed": breakdown.get("defensive0PointsAllowed", 0.0),
            "defensive1To6PointsAllowed": breakdown.get(
                "defensive1To6PointsAllowed", 0.0
            ),
            "defensive7To13PointsAllowed": breakdown.get(
                "defensive7To13PointsAllowed", 0.0
            ),
            "defensive14To17PointsAllowed": breakdown.get(
                "defensive14To17PointsAllowed", 0.0
            ),
            "defensiveTouchdowns": breakdown.get("defensiveTouchdowns", 0.0),
            "defensiveInterceptions": breakdown.get("defensiveInterceptions", 0.0),
            "defensiveForcedFumbles": breakdown.get("defensiveForcedFumbles", 0.0),
            "defensiveSacks": breakdown.get("defensiveSacks", 0.0),
        }
        player_data.append(player_row)

    df = pd.DataFrame(player_data)

    return df


def collect_current_season_projections(year: int):
    """Collect current season projections for all players and return as DataFrame."""
    league = _create_league(year)
    players = _collect_all_players(league)

    player_data = []
    for p in players:
        player_row = {
            "playerId": p.playerId,
            "name": p.name,
            "proTeam": p.proTeam,
            "position": p.position,
            "proj_points": p.projected_points,
        }
        if player_row["proTeam"] == "None":
            continue
        if player_row["proj_points"] == 0:
            continue
        player_data.append(player_row)

    df = pd.DataFrame(player_data)

    return df


@task(name="collect-prev-season-data")
def collect_prev_season_data_task(ctx, year):
    """Collect previous season data for all players and save to CSV."""
    load_dotenv()

    try:
        year_int = int(year)
    except ValueError:
        print(
            f"Error: '{year}' is not a valid year. "
            "Please provide a 4-digit year (e.g., 2023)"
        )
        return

    print(f"Collecting data for {year_int}...")
    df = collect_prev_season_data(year_int)

    # Create prev_seasons directory if it doesn't exist
    prev_seasons_dir = Path("data")
    prev_seasons_dir.mkdir(exist_ok=True)

    # Write DataFrame to CSV
    csv_path = prev_seasons_dir / f"{year_int}.csv"
    df.to_csv(csv_path, index=False)
    print(f"\nData saved to: {csv_path}")

    print(f"Successfully collected data for {len(df)} players from {year_int} season")


@task(name="collect-current-season-projections")
def collect_current_season_projections_task(ctx, year):
    """Collect current season projections for all players and save to CSV."""
    load_dotenv()

    try:
        year_int = int(year)
    except ValueError:
        print(
            f"Error: '{year}' is not a valid year. "
            "Please provide a 4-digit year (e.g., 2025)"
        )
        return

    print(f"Collecting current season projections for {year_int}...")
    df = collect_current_season_projections(year_int)

    # Create prev_seasons directory if it doesn't exist
    prev_seasons_dir = Path("data")
    prev_seasons_dir.mkdir(exist_ok=True)

    # Write DataFrame to CSV
    csv_path = prev_seasons_dir / f"proj_{year_int}.csv"
    df.to_csv(csv_path, index=False)
    print(f"\nData saved to: {csv_path}")

    print(
        f"Successfully collected projections for {len(df)} "
        f"players from {year_int} season"
    )
