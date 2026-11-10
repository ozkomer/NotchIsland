# NotchIsland

A small macOS app that turns the notch on a MacBook into a live status area, in the spirit of the Dynamic Island. It sits on the notch, opens wings on both sides when something is happening, and drops down into a panel when you point at it.

![Compact: an activity with a progress ring](docs/compact.png)

![Expanded panel](docs/expanded.png)

The interface text is currently in Turkish.

## What it shows

- **Now playing** from Music and Spotify: artwork, title, artist, a progress bar, and previous / play-pause / next buttons.
- **YouTube in Safari** (regular videos and Shorts): thumbnail and title. Display only, no buttons.
- **Timer and stopwatch**: pick 1 to 120 minutes, or count up.
- **Your own activities**: scripts push a title, a detail line and a progress value with the `notch` command.
- **Microphone and camera in use**: an orange or green dot, plus the name of the app holding the microphone.
- **Short notices**: volume changes, keyboard language switch, charger plugged or unplugged, low battery (20% and 10%), battery full, network lost or back.
- **Next calendar event**: off by default; turn it on from the right-click menu.

When several things are active, the right wing shows the most important one (your activity, then the clock, then the calendar, then music) and the left wing shows the icon of the next.

## Requirements

- macOS 14 or later
- A Swift toolchain (Xcode or the Xcode Command Line Tools)
- A Mac with a notch. On a screen without one, the app draws a pill at the top center instead.

## Build and run

```sh
git clone https://github.com/ozkomer/NotchIsland.git
cd NotchIsland
./build.sh --run
```

`build.sh` compiles the package, assembles `NotchIsland.app` next to the script, signs it ad hoc, and writes the `notch` command. Right-click the island for "start at login", the calendar switch, and quit.

## The `notch` command

`build.sh` creates a `notch` script in the project folder. It talks to the running app, so the app has to be open.

```sh
# Show or update an activity. The id is yours to choose.
./notch show deploy "Deploy" --progress 40 --detail "switching to green" --icon shippingbox.fill --color green

# Finish it: a green check, or a red error.
./notch done deploy
./notch fail deploy "Failed"

# Remove it without a notice.
./notch clear deploy

# Run a command, show how long it has been running, and report how it ended.
./notch run "Build" -- npm run build
```

- `--progress` takes 0 to 100. Without it, the activity shows elapsed time.
- `--icon` takes an SF Symbols name.
- `--color` takes one of: green, red, orange, yellow, blue, cyan, purple, pink, white.
- `notch run` exits with the status of the command it ran.

## Permissions

| Permission | When macOS asks | Used for |
|---|---|---|
| Automation: Music, Spotify | When one of them is running | Reading the current track and sending play / pause / next |
| Automation: Safari | When Safari is running | Reading tab addresses and titles to find a YouTube tab |
| Calendar | When you turn on the calendar switch | Reading the next event |

Everything else (microphone and camera indicators, volume, keyboard language, battery, network) uses public system properties and needs no permission. The app never records audio or video; it only reads whether a device is in use.

Because the app is signed ad hoc, macOS may ask for the Automation permissions again after each rebuild.

## Limitations

- **YouTube is Safari only**, and the play state is inferred from whether Safari is producing sound. If another Safari tab makes sound while a YouTube tab is open, the island shows the video as playing. With several YouTube tabs, the first one found is shown.
- **No system-wide "now playing".** Recent macOS versions do not let third-party apps read it, so each player needs its own support.
- **Wings cover menu bar items** that sit right next to the notch.
- **It does not show the system's own Live Activities.** It only shows what is listed above.
- Built and tried on one machine (a 14-inch MacBook Pro). The battery, network, keyboard and calendar notices have had little testing.

## How it works

A borderless panel is placed over the menu bar, centered on the notch. SwiftUI draws a black shape that matches the notch and animates between three sizes: idle, compact and expanded. The pointer position is polled, so the panel only takes mouse events while the pointer is over the island and clicks elsewhere pass through.

| File | Role |
|---|---|
| `main.swift` | Panel, pointer tracking, right-click menu, command line entry |
| `IslandModel.swift` | State and sizing |
| `IslandView.swift` | All drawing |
| `MusicController.swift` | Music and Spotify |
| `YouTubeController.swift`, `AudioActivity.swift` | YouTube tabs and play detection |
| `SystemMonitors.swift`, `PowerMonitor.swift` | Microphone, camera, volume, keyboard, network, battery |
| `CalendarMonitor.swift` | Next event |
| `Commands.swift` | The `notch` command |

## License

MIT. See [LICENSE](LICENSE).

NotchIsland is not affiliated with Apple. Dynamic Island and Live Activities are Apple features; this project only takes inspiration from them.
