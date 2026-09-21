# Changelog

Versions are the integer in each driver's `<version>`, which Composer uses to compare updates.
Earlier development builds are summarised rather than listed individually.

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
