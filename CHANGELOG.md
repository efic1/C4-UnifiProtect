# Changelog

Versions are the integer in each driver's `<version>`, which Composer uses to compare updates.
Earlier development builds are summarised rather than listed individually.

## Camera driver 53 / Setup driver 5

A review of 52 for edge cases and controller load. Every item below was reproduced with a failing
test first; 29 camera and 5 setup tests were added.

Camera driver
- Status no longer sticks: "Unreachable", "Auth Failed" and "API not found" clear as soon as the
  console answers properly, and when the NVR Address or API Key changes (which also re-tests the
  connection). Background polls need three failures in a row before showing "Unreachable".
- Switching camera (dropdown, Camera ID, or a push from the setup driver) now goes through one
  routine. Replies still in flight for the previous camera - stream tokens, polls, snapshot frames -
  are ignored instead of overwriting the new camera's state, and detections held for the old camera
  are cleared.
- The poll chain can no longer die. An error while handling a reply is caught, and a poll that
  never gets a reply is replaced after a minute (before, one lost reply stopped polling for good).
- A poll reply that carries no connection state is ignored rather than read as "offline" (it fired
  false offline/online events). A restart no longer announces "camera online".
- Polled events: the first doorbell ring after startup is no longer swallowed; sustained motion is
  one episode rather than one event per poll (a doorbell ring is still one event per ring).
- Stream tokens are re-read at startup and when a camera comes back online, since Protect can change
  them. The refresh never switches RTSP on and never blanks tokens that still work.
- The random generator is now seeded per camera. It started from the same state on every boot, so
  the "random" startup slot and WebSocket keys were identical across cameras.
- Event socket: the reconnect backoff is only reset once a connection has stayed up for a minute,
  so a console that accepts and then drops us is no longer retried every few seconds. When the
  socket drops, the camera is polled within seconds instead of up to a minute later.
- Snapshots: viewers that ask while a frame is being fetched wait for it instead of getting a 503;
  a listener that is still starting is not started twice; a frame older than a minute is no longer
  served as current; a frame fetched for the previous camera is discarded.

Setup driver
- A camera driver deleted in Composer is dropped from the managed list and added again on the next
  sync (previously the sync kept configuring the missing device). An empty lookup result is treated
  as a failed lookup and prunes nothing.
- "Done" is reported when the new drivers actually exist, not when the last one was requested. A
  step that fails, or a device that never appears, can no longer leave the sync stuck "busy".

## Camera driver 52

- History entries now carry the camera's name in their title ("Person Detected · Street North -
  G6"), or the installer's name for the device if one was chosen. Field testing showed History labels
  records with the driver's definition name and ignores renaming devices entirely.
- The driver device is no longer renamed: it had no visible effect, and each rename refreshes the
  whole project. The Composer-visible device is still named after the camera.
- The driver's name drops "(Standalone)".

## Camera driver 51

- Fixed: `C4:GetProxyDevices()` returns a number, not a table, so the proxy id was always empty. The
  Composer-visible device was therefore never renamed, and History event types were never
  registered. Both now work.

## Camera driver 50

- Fixed: History still showed "UniFi Protect Camera (Standalone)". History labels records with the
  driver's own device, not the proxy that v49 renamed. Both are now named; the driver device mirrors
  the proxy, so History shows whatever name you see in Composer, including one you chose.
- Cameras configured by hand before v49 had no stored camera name, so nothing was renamed. The name
  is now looked up once at startup when missing.
- Run Diagnostics shows the camera, proxy and driver names.

## Camera driver 49

- Each camera device is named after its Protect camera, so History entries show the camera rather
  than "UniFi Protect Camera". Only a default name, or a name the driver set, is replaced; a name the
  installer chose is kept. **Use Protect Camera Name** forces it. Renames happen only on a real
  change, and at startup in each camera's own slot, because each rename refreshes the project.
- Unmapped smart-detection classes are logged once per detection instead of on every update.

## Camera driver 48 / Setup driver 4

- **History**: events recorded in the Control4 app's timeline, chosen per type independently of
  programming events (**History - Person** etc.), with a per-type cooldown. Event types are
  registered with the History agent at startup, with retries.
- **Detect Motion** and **Detect Doorbell** toggles; all six detection kinds can now be switched off.
- The setup driver pushes the Detect and History choices to every camera.
- **Load:** startup no longer fetches the camera list, and each camera's first requests go out in
  its own random slot rather than all at once after a Director restart. Polling slows to once a
  minute and adaptive bursts are suppressed while the event stream is live. Other cameras' events are
  skipped before parsing, and frame parsing is linear. Diagnostics reports request and message counts.

## Camera driver 47

- Events now arrive over Protect's WebSocket event stream: sub-second, with real end times, and no
  periodic API requests. New **Event Source** property (WebSocket, Polling, Off; default WebSocket)
  and read-only **Event Stream** status.
- Polling suppresses its own detections while the stream is live, and covers while it reconnects.
- Fixed: clearing a detection did not cancel its watchdog timer, which could produce a second
  "Ended" event.

## Camera driver 46 / Setup driver 3

First public release.

### Camera driver
- Live video over plain RTSP (port 7447), with remote viewing over 4Sight via the static URL path
  and `http_tunnel`.
- Stream quality chosen from the size the client requests; Preferred Quality when it gives none.
- Camera dropdown populated by discovery; stream tokens fetched on selection.
- RTSP enabled in Protect automatically when a camera has none (once; can be switched off).
- Snapshot thumbnails served from a per-camera listener on the controller, fetched on demand,
  released when idle.
- Detection events (motion, person, vehicle, animal, package, doorbell, online/offline) with
  matching variables; polling off by default, with adaptive bursts.
- RTSP port held at 7447 by correcting the proxy when it reports its stored value.
- HTTP 429 retried with backoff and jitter; one request at a time per camera.
- A single derived Driver Status, ordered by dependency.
- Diagnostics action.

### Setup driver
- Creates one camera driver per Protect camera, named after it, and pushes its configuration.
- Adopts camera drivers added by hand or left from an earlier install instead of duplicating them.
- Configures cameras one at a time to stay under Protect's rate limit.
- Push Settings for rotating the API key.

## Development history

The path to the first release, in the order problems were found. Details are in
`docs/DEVELOPMENT_NOTES.md`.

- Properties outside `<config>` were silently ignored.
- Actions arrive as `LUA_ACTION`; unhandled at first.
- Unclosed `<stream>` elements (copied from Snap One's examples) broke every camera's list.
- Stored stream tokens were wiped on reload by unordered property replay.
- Proxy replies were returned from `ReceivedFromProxy`, where they are discarded; moved to
  `UIRequest`.
- Dynamic streams worked on the LAN but not remotely; replaced with the static path and
  `http_tunnel`.
- The proxy's stored port of 554 silently overrode 7447.
- Returning `""` instead of an empty document stalled the camera view.
- Missing event descriptions and an empty `<states/>` broke the Programming tab.
- A status race left "No RTSP alias" showing after the tokens loaded.
- Bulk configuration tripped Protect's rate limit.
