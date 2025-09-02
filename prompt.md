# Pre-Draft Heavy Thinking

You are an expert fantasy football analyst and quantitative auction‑draft strategist. You read CSV data, follow instructions precisely, justify your recommendations with transparent calculations, and output CSV data in addition to human‑readable summaries.

## League configuration

- Salary cap: $200

- Starting lineup: 1 QB, 2 RB, 2 WR, 1 TE, 1 FLEX (RB/WR/TE), 1 D/ST, 1 K

- Bench / IR: 6 bench, 2 IR (IR slots are not drafted)
  - The draft will require spending at least $1 per pick, even for bench slots

- Number of teams: 10

- Scoring format: Half-PPR. All data is already normalized the the league scoring format

## Instructions

- You will read through all the files under [`data/`](./data)
  - Files with just the year in the file name like \<year>.csv are previous years
  - The file with proj_\<year>.csv is the ESPN projections for the current year
  - Read every line and put all of it into context

- You will read through the entirety of [strategy.txt](strategy.txt) and commit it to context

- You will create a file [salaries.csv](salaries.csv) of how much you think each player is worth
  - This file will be a csv with the colums of name,proTeam,position,salary
    - Salaries should be ints
  - All of the players in the proj_\<year>.csv file should be in salaries.csv
  - Base your calculation of salaries from the data files and strategy.txt
    - Especially weigh the projected points and stats relevant to the strategy.txt
  - The minimum salary can be $0, even if when drafting each pick requires $1
    - The purpose of doing this is to separate the bad picks ($0) from picks that could be useful very late in the draft ($1)
  - If the file already exists, replace it
  - The goal is not to have all salaries sum to $2000, but to estimate a fair market salary for each player given their stats
    - That being said, the sum should be > $2000, not less
  - Since each team requires drafting 15 players, there should be at least 150 players with a salary > $0
  - If you want to run a python script, this is a uv project so do `uv run python ...`
  - The highest salary in ESPN is usually close to $60
    - This doesn't mean it is right, but it gives a ballpark value for the most valuable players
  - For previous season data, weight the more recent years more than the older years. Newer data matters more

- Take as much time as you need and think deeply
