# Recording color and effect stacking — October 27, 2026

## Fixes

- Camera recording now resolves the final linear composition to sRGB, matching the hardware conversion used by the viewfinder. The former history-copy pass wrote linear values directly into encoded-video buffers, darkening midtones and exaggerating apparent contrast.
- H.264, HEVC, ProRes 422 HQ, and ProRes 4444 XQ receive explicit, matching sRGB transfer / Rec.709 primaries and matrix metadata. ProRes keeps half-float precision. Source pixel buffers carry matching color attachments.
- The branding compositor now handles RGBA half-float buffers as 16-bit floating-point RGBA. Its old 8-bit BGRA context could corrupt ProRes pixels.
- Stack mode preserves different variants of the same effect family. Disarming Stack changes the next-selection policy without deleting the current composition. Intent-based selection now follows the same policy as the browser.
- The render graph skips disabled or zero-mix stages while retaining the other active stages in order.
- Tracking burn-in waits for the first raster and prevents CPU reuse of textures still referenced by the GPU. Hand tracking and every other tracking mode use the same finished-composition capture path.

## Physical-device checks

Executed on **nick’s iPhone**, iPhone 17 Pro Max, iOS 27.2. **16 tests passed, zero failures, zero skips.** See [phone-tests.json](phone-tests.json).

Coverage:

- Every current catalog effect can be added to one Stack without dropping earlier effects or family variants; disarming preserves it and the next exclusive selection replaces it.
- Every registered style/temporal shader kernel executes on the phone GPU. Dedicated solver stages are checked for registration; this kernel smoke test does not simulate every solver interaction.
- Recording resolve matches a hardware sRGB render across a color ramp, for both 8-bit BGRA and half-float RGBA output.
- Real H.264, HEVC, ProRes 422 HQ and ProRes 4444 XQ movies encode and decode with sRGB metadata and preserved midtones.
- ProRes branding draws without corrupting untouched half-float pixels.
- Disabled/failed graph stages are skipped while later stages continue; slot duplication, independent tuning, reordering and removal retain their existing behavior.

Result bundle: `/private/tmp/gv-title-device-20261027/Logs/Test/Test-GreyVision-2026.10.27_12-33-36--0500.xcresult`.

An older registry assertion failed in the first run because it required contiguous shader IDs after effects had been retired. The test now checks uniqueness and a valid render-stage mapping for every active effect. The final run above passed.

## Tracking checks

[tracking-self-check.txt](tracking-self-check.txt) records **79 passing host checks** against the production Swift and Metal source, covering all ten tracking modes, hand joints/bones over processed imagery, cold capture, texture lifetime, restart, crop/resize mapping and 4K output. These reproduced 22 failures before the tracking correction.

Standalone host codec round trips also preserved midtones in all four formats. That fixture omits branding; the device tests separately exercised the production branding compositor and full movie writer.

## Verification limits

The Mac was locked during the direct UI inspection attempt, so live Stack-button tapping and an actual hand-tracking-plus-temporal-sort take were not visually verified. No claim is made that every possible effect permutation has been filmed. The automated checks cover the shared composition/recording path, every catalog selection and shader kernel, all tracking modes, and all four supported capture codecs.

## Deployment

The signed normal Debug build was installed and launched on Nick's iPhone after testing. Installation container: `BE79E678-46F5-42E5-912B-430A12D5BE5B`. Install log: `/tmp/gv-recording-stack-final-install.log`.

The phone temporarily disconnected during the first independent process query. After reconnecting, a diagnostic relaunch remained alive during and after a 20-second console observation, with no application errors in console output. CoreDevice independently confirmed GreyVision running as PID 3242 in the installed container. The console command's timeout ended observation without terminating the app.

Color-policy references: [Apple video color properties](https://developer.apple.com/documentation/avfoundation/avvideocolorpropertieskey), [sRGB transfer identifier](https://developer.apple.com/documentation/avfoundation/avvideotransferfunction_iec_srgb), [Metal sRGB conversion](https://developer.apple.com/documentation/metal/mtlpixelformat/bgra8unorm_srgb).
