# Marina for the Mac App Store

This target is intentionally separate from the full Marina distribution. It is an App Sandbox-compliant controller for a Marina service already running on the same Mac.

- It communicates only with `http://127.0.0.1:7737`.
- It does not install a CLI, launch shell commands, inspect ports, or read project files. Neither target contains an update framework or analytics.
- The full Developer ID distribution remains the process supervisor and source of truth.
- When the local service is unavailable, **Explore Demo** presents sample projects and
  simulated Start, Stop, and Restart controls so App Review can evaluate the complete
  companion without installing the full Marina distribution.

Generate and validate the project with:

```bash
cd StoreApp
xcodegen generate
xcodebuild -project MarinaCompanion.xcodeproj -scheme MarinaCompanion -destination 'platform=macOS' test
```
