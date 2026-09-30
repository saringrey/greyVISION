# grey//VISION Domain Language

- **Launch Ceremony** — the cold-launch Gate → Boot → Workspace progression,
  including choreography, timing, interruption, and the final launch intent.
- **Capture Source Transition** — the exclusive transaction that moves the
  instrument among Camera, LiDAR, and Objects and restores Camera after an AR
  source fails to start.
- **Camera** — the AVFoundation live source and its processed Metal frame path.
- **LiDAR** — the ARKit scene-depth source and depth-effect modes.
- **Objects** — the ARKit world-tracking source for placed geometry.
- **Recording Transaction** — the operator's single Record action and its
  source-appropriate processed-frame or Objects recording path.
- **Effect Editing** — selection, ADD mode, focused slot, stack mutation,
  parameter commits, composition history, and recipe application.
- **Composition** — RGB Split plus the ordered effect stack at one moment.
- **Recipe** — a named, persisted capture format and Composition.
- **Slot** — one identified placement of an effect in render order. Multiple
  Slots may carry the same effect with different parameters.
