# UniFi Protect for Control4

Control4 drivers for UniFi Protect cameras and doorbells: live video on touchscreens and in the
Control4 app (including remotely over 4Sight, with no port forwarding), Protect detection events
for programming, and camera thumbnails.

Two drivers:

| Driver | Purpose |
|---|---|
| **UniFi Protect Camera** (`unifi_protect_camera.c4z`) | One instance per camera. Video, events, snapshots. Runs on its own. |
| **UniFi Protect Setup** (`unifi_protect_setup.c4z`) | Optional. Enter the console address and API key once; it creates and configures a camera driver for every Protect camera. Not involved in video or events — remove it and the cameras keep working. |

## Status

Built and tested against a live system: Control4 OS 3.4.3, UniFi Protect 6.x, G5 and G6 cameras.

| Feature | Status |
|---|---|
| Live video on the LAN | Verified |
| Live video remotely over 4Sight, no port forwarding | Verified |
| Detection events in Composer programming | Verified |
| Setup driver creating and configuring cameras | Verified |
| Snapshot thumbnails | Implemented and tested offline; not yet confirmed on hardware |
| Audio | Not supported — see [Limitations](#limitations) |

## Requirements

- A UniFi OS console (UDM-Pro, UDM-SE, UNVR, CloudKey Gen2+) running Protect 6.x or later
- A UniFi API key with Protect access
- Control4 OS 3.3.0 or later (3.4.x recommended)

## Installation

Download both `.c4z` files from the [latest release](../../releases/latest).

### With the setup driver (recommended for more than one camera)

1. In Composer, load `unifi_protect_camera.c4z` into the driver database. You do not need to add it
   to the project — the setup driver creates the instances.
2. Add **UniFi Protect Setup** to the room where the cameras should appear.
3. Enter **NVR Address** and **API Key**, then run **Test Connection**.
4. Run **Create / Update Cameras**.

One camera driver appears per Protect camera, named after it, fully configured. Cameras are
configured a couple of seconds apart to stay under Protect's rate limit, so eight cameras take about
twenty seconds; **Setup Status** shows progress.

Re-running is safe: existing cameras are updated, never duplicated, and camera drivers added by hand
are found and adopted. To rotate the API key, change it on the setup driver and run **Push Settings
to Cameras**.

### Without the setup driver

1. Add **UniFi Protect Camera** to the project.
2. Enter **NVR Address** and **API Key**, run **Discover Cameras**, and pick one from the **Camera**
   dropdown. Stream tokens are fetched automatically.

### RTSP

Protect ships with RTSP **off**, for every camera and every quality. With **Enable RTSP
Automatically** on (the default), a camera driver that finds no stream enabled asks Protect to turn
it on. Otherwise run **Enable RTSP Streams** on the camera driver.

## How it works

- **Video** is plain RTSP on port 7447 (`rtsp://<console>:7447/<token>`). RTSPS on 7441 is SRTP
  behind a self-signed certificate that Control4 will not validate; 7447 needs neither a certificate
  nor credentials — the stream token is the secret.
- **Remote viewing** works because the driver uses the camera proxy's static URL path with
  `http_tunnel`, which keeps Director in the media path so 4Sight can relay it. Control4's dynamic
  stream API hands the client a URL directly and does *not* work remotely without port forwarding.
- **Snapshots**: Protect refuses the API key as a URL parameter, and Navigator can only fetch URLs,
  not send headers. So each camera driver fetches frames itself with the key as a header, caches the
  latest, and serves it from a small HTTP listener on the controller. The key never leaves the
  controller. Frames are fetched only when a Navigator asks, and released after two minutes idle.
- **Events** are polled, because DriverWorks has no WebSocket client. Polling is **off by default**.
  With **Adaptive Polling**, a slow baseline speeds up to once a second for a burst after any event.

The in-driver documentation (Composer's Documentation tab) covers properties, actions and
troubleshooting in detail. [docs/DEVELOPMENT_NOTES.md](docs/DEVELOPMENT_NOTES.md) records what was
learned about the DriverWorks camera proxy along the way, much of which is not in Snap One's
documentation.

## Events

Motion Detected, Motion Ended, Person Detected, Vehicle Detected, Animal Detected, Package Detected,
Doorbell Pressed, Camera Online, Camera Offline — with matching boolean variables for conditionals.

Smart detections fire only when Protect names the detection class. If a detection arrives with no
class, the driver logs a warning rather than guessing, since guessing "person" would fire false
alarms for passing cars.

## Limitations

- **No audio.** The driver does not block audio — it passes the RTSP stream through, and Control4
  shows its audio button. But Control4 plays only G.711 μ-law (PCMU) at 8 kHz, and Protect's RTSP
  audio is believed to be AAC. To check your cameras, open a stream URL in VLC and look at Tools →
  Codec Information.
- **No PTZ, no two-way talk, no recorded playback.**
- **Detection latency follows the polling interval.** There is no push event channel.
- **Snapshot thumbnails may not load away from home**, since the snapshot URL is a LAN address. Live
  video is unaffected.
- The snapshot URL is unauthenticated and reachable from anything on the LAN. The API key is not.

## Development

```
drivers/
  camera/        driver.xml, driver.lua, www/documentation.html
  setup/         driver.xml, driver.lua, www/documentation.html
test/
  c4stub.lua     a fake Control4 runtime so drivers run offline
  camera_tests.lua
  setup_tests.lua
tools/
  build.sh       every gate, both test suites, then package into dist/
  check_*.py     the gates
docs/
  DEVELOPMENT_NOTES.md
```

Requires Lua 5.1, Python 3 and `zip`.

```sh
make check   # gates and tests
make build   # gates, tests, and dist/*.c4z
```

The build refuses to package unless every gate passes. Each gate exists because the thing it checks
once shipped broken:

- Lua compiles, and `driver.xml` is well-formed
- No function calls a `local` defined later in the file (compiles cleanly, fails at runtime)
- `DRIVER_VERSION` in the Lua matches `<version>` in the XML
- `<properties>`, `<actions>`, `<script>` and `<documentation>` are inside `<config>`
- Every writable property has a handler; every action is dispatched
- Every event has a unique id and a description; no empty `<states/>`
- The setup driver targets the camera driver's actual filename

**Tests.** 92 tests across both drivers, each tied to a bug that shipped. The stub supports
**asynchronous HTTP** (`async = true`, replies delivered on `st.flush()`), because the synchronous
default hid a race that only appeared on real hardware. The setup driver's end-to-end tests load
real camera driver instances in isolated environments and route `C4:SendToDevice` between them.

When adding a test, break the code it covers and confirm the test fails. Several tests in this
project passed against broken code until that was done.

CI (`.github/workflows/ci.yml`) runs the full build on every push and pull request, and attaches the
drivers to a GitHub release when a `v*` tag is pushed.

## Credits

[control4-frigate](https://github.com/mattstein111/control4-frigate) by mattstein111 was the key
reference for how a working Control4 camera driver answers the proxy (`UIRequest`), creates child
drivers, and handles audio.

## Disclaimer

Not affiliated with or endorsed by Ubiquiti Inc. or Snap One, LLC. UniFi and UniFi Protect are
trademarks of Ubiquiti Inc.; Control4 is a trademark of Snap One, LLC. Use at your own risk.

## License

MIT — see [LICENSE](LICENSE).
