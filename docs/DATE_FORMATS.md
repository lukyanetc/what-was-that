# Date formats

What Was That!? formats dates the way [moment.js](https://momentjs.com/docs/#/displaying/format/) does, but date only (no time). Type a pattern into the **Day** or **Month** field in Settings → General → Date Format.

- Text in `[square brackets]` is printed as is: `[Day] D` → `Day 10`.
- Characters that are not tokens (spaces, `.`, `/`, `-`, `,`) are printed as is.
- Names are in English.

Examples use Tuesday, March 10, 2026.

## Tokens

| Token | Meaning | Example |
|---|---|---|
| `YYYY` | Year, 4 digits | `2026` |
| `YY` | Year, 2 digits | `26` |
| `Y` | Year, any length | `2026` |
| `Q` | Quarter | `1` |
| `Qo` | Quarter with ordinal | `1st` |
| `MMMM` | Month name | `March` |
| `MMM` | Month, short | `Mar` |
| `MM` | Month number, 2 digits | `03` |
| `M` | Month number | `3` |
| `Mo` | Month number with ordinal | `3rd` |
| `DD` | Day of month, 2 digits | `10` |
| `D` | Day of month | `10` |
| `Do` | Day of month with ordinal | `10th` |
| `DDDD` | Day of year, 3 digits | `069` |
| `DDD` | Day of year | `69` |
| `DDDo` | Day of year with ordinal | `69th` |
| `dddd` | Weekday name | `Tuesday` |
| `ddd` | Weekday, short | `Tue` |
| `dd` | Weekday, 2 letters | `Tu` |
| `d` | Weekday number (0 is Sunday) | `2` |
| `do` | Weekday number with ordinal | `2nd` |
| `e` | Weekday number (0 is Sunday) | `2` |
| `E` | ISO weekday number (1 is Monday, 7 is Sunday) | `2` |
| `W` | ISO week of year | `11` |
| `WW` | ISO week of year, 2 digits | `11` |
| `Wo` | ISO week of year with ordinal | `11th` |
| `w` / `ww` / `wo` | Week of year, weeks start on Sunday | |
| `GGGG` / `GG` | ISO week-numbering year | `2026` / `26` |
| `gggg` / `gg` | Week-numbering year, weeks start on Sunday | |

## Presets

| Pattern | Result |
|---|---|
| `DD ddd` | `10 Tue` (default for days) |
| `ddd DD` | `Tue 10` |
| `DD.MM` | `10.03` |
| `DD.MM.YYYY` | `10.03.2026` |
| `MM/DD/YYYY` | `03/10/2026` |
| `YYYY-MM-DD` | `2026-03-10` |
| `MMMM YYYY` | `March 2026` (default for months) |
| `MMM YY` | `Mar 26` |

## Uppercase

With **Uppercase** switched on (Settings → Appearance), the result is shown in capitals: `10 TUE`, `MARCH 2026`.
