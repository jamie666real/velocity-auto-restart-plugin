# Velocity AutoRestart Plugin

Features:
- Daily scheduled restart at configured time/timezone
- Configurable shutdown delay and multiple countdown warnings
- /autorestart [seconds] command (permission-controlled)
- Optional external restart command hook
- Gradle build with shadowJar to produce a ready-to-drop-in fat jar

Build:
1. Ensure Java 17+ and Gradle are available.
2. Build the plugin jar:
   gradle jar
   Output: build/libs/velocity-autorestart-1.1.0.jar
3. Optional extra artifact from a previous Shadow setup is not required here.

Install:
1. Copy the jar into your Velocity proxy `plugins/` directory.
2. Start Velocity.
3. On first run the plugin will create a data folder under `plugins/autorestart/` with a config.properties. Edit that file if desired and restart Velocity.

Restart behavior:
- The plugin calls `proxy.shutdown()` to stop the proxy JVM. That will not automatically restart the process unless something on the host restarts it (systemd, supervisor, or a background script).
- You can:
  - Use the included systemd unit to have systemd restart the proxy automatically.
  - Or set `restartCommand` and `runCommandBeforeShutdown=true` so the plugin attempts to run a script that re-launches the proxy (the script must start the proxy detached).

Notes:
- This plugin defaults to `America/Chicago`. Change `timezone` in config.properties if you meant another timezone.
