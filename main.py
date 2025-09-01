import os

from dotenv import load_dotenv
from espn_api.football import League


def main():
    league = League(
        league_id=os.getenv("LEAGUE_ID"),
        year=2024,
        espn_s2=os.getenv("ESPN_S2"),
        swid=os.getenv("SWID"),
    )
    print("Hello from ff-drafter!")
    print(league.teams)


if __name__ == "__main__":
    load_dotenv()
    main()
