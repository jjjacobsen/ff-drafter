# FF Drafter 🏈

A fantasy football data analysis tool that assists during your draft by leveraging ESPN's fantasy football API.

## Features

- Connect to ESPN fantasy football leagues
- Analyze team data and player statistics
- Assist with draft decision-making

## Installation

This project uses [uv](https://docs.astral.sh/uv/) for dependency management. To get started:

```bash
# Clone the repository
git clone <your-repo-url>
cd ff-drafter

# Install dependencies
uv sync

# Run the application
uv run python main.py
```

## Configuration

To use this tool, you need to configure your ESPN league credentials. The tool requires three values from ESPN's API:

### Required Configuration Values

1. **`league_id`** - Your ESPN league identifier

   You can find this in your league URL:

   ```url
   https://fantasy.espn.com/football/league?leagueId=123456
   ```

   In this example, `123456` is your league ID.

2. **`espn_s2`** - ESPN authentication cookie (required for private leagues)

3. **`swid`** - ESPN session identifier (required for private leagues)

> **Note:** The `espn_s2` and `swid` values are only required for private leagues.

### Getting ESPN Credentials

To obtain your `espn_s2` and `swid` values, follow the detailed guide in the [ESPN API documentation](https://github.com/cwendt94/espn-api/discussions/150).

### Environment Setup

1. Copy the example environment file:

   ```bash
   cp .env.example .env
   ```

2. Edit `.env` and add your actual values:

   ```bash
   LEAGUE_ID=your_league_id_here
   ESPN_S2=your_espn_s2_value_here
   SWID=your_swid_value_here
   ```

## Usage

Once configured, run the application:

```bash
uv run python main.py
```

### Collecting Previous Season Data

To collect previous season data for analysis:

```bash
uv run inv collect-prev-season-data <year>
```

### Collecting Current Season Projectsion

To collect the projections for the current season:

```bash
uv run inv collect-current-season-projections <year>
```

### Calculating salaries.csv

This is the base salary values that the AI will generate based on my strategy. Simply open up codex, claude, or cursor cli and enter:

```text
I'd like you to treat prompt.md as your prompt and execute it
```

Continue to use that chat to refine values as needed

## License

This project is open source. Please check the license file for details.
