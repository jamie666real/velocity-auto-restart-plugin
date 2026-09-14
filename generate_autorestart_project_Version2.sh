#!/usr/bin/env bash
set -euo pipefail

echo "Generating Velocity AutoRestart project files..."

# Create directories
mkdir -p src/main/java/com/example/autorestart
mkdir -p src/main/resources/META-INF
mkdir -p src/main/resources
mkdir -p .github/workflows
mkdir -p docs

# Java plugin
cat > src/main/java/com/example/autorestart/AutoRestartPlugin.java <<'EOF'
package com.example.autorestart;

import com.google.inject.Inject;
import com.velocitypowered.api.command.CommandManager;
import com.velocitypowered.api.command.CommandSource;
import com.velocitypowered.api.command.SimpleCommand;
import com.velocitypowered.api.plugin.Plugin;
import com.velocitypowered.api.plugin.annotation.DataDirectory;
import com.velocitypowered.api.proxy.ProxyServer;
import net.kyori.adventure.text.Component;
import org.slf4j.Logger;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.*;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.stream.Collectors;

@Plugin(id = "autorestart", name = "AutoRestart", version = "1.1.0", description = "Auto-restarts proxy at configured time with advanced warnings")
public class AutoRestartPlugin {

    private final ProxyServer proxy;
    private final Path dataDirectory;
    private final Logger logger;

    // config defaults
    private String time = "12:00"; // H:mm
    private String timezone = "America/Chicago";
    private int shutdownDelaySeconds = 60; // how long after the first announcement until shutdown
    private List<Integer> warnIntervals = Arrays.asList(60, 30, 10, 5); // seconds before shutdown
    private String triggerPermission = "autorestart.trigger";
    private String restartCommand = ""; // optional command to run before shutdown (e.g. /opt/scripts/restart_proxy.sh)
    private boolean runCommandBeforeShutdown = false; // whether to run restartCommand before calling proxy.shutdown()
    private int commandTimeoutSeconds = 30; // wait for external command this many seconds

    @Inject
    public AutoRestartPlugin(ProxyServer proxy, @DataDirectory Path dataDirectory, Logger logger) {
        this.proxy = proxy;
        this.dataDirectory = dataDirectory;
        this.logger = logger;

        try {
            loadOrCreateConfig();
        } catch (IOException e) {
            logger.error("Failed to read/create config: ", e);
        }

        registerCommands();
        scheduleDailyRestart();
        logger.info("AutoRestart plugin enabled, will restart daily at {} {}", time, timezone);
    }

    private void loadOrCreateConfig() throws IOException {
        if (!Files.exists(dataDirectory)) {
            Files.createDirectories(dataDirectory);
        }
        Path cfg = dataDirectory.resolve("config.properties");
        if (!Files.exists(cfg)) {
            Properties defaults = new Properties();
            defaults.setProperty("time", time);
            defaults.setProperty("timezone", timezone);
            defaults.setProperty("shutdownDelaySeconds", Integer.toString(shutdownDelaySeconds));
            defaults.setProperty("warnIntervals", warnIntervals.stream().map(Object::toString).collect(Collectors.joining(",")));
            defaults.setProperty("permission", triggerPermission);
            defaults.setProperty("restartCommand", restartCommand);
            defaults.setProperty("runCommandBeforeShutdown", Boolean.toString(runCommandBeforeShutdown));
            defaults.setProperty("commandTimeoutSeconds", Integer.toString(commandTimeoutSeconds));
            try (OutputStream out = Files.newOutputStream(cfg)) {
                defaults.store(out, "AutoRestart configuration");
            }
            logger.info("Created default config at {}", cfg);
        }

        Properties props = new Properties();
        try (InputStream in = Files.newInputStream(cfg)) {
            props.load(in);
        }

        time = props.getProperty("time", time);
        timezone = props.getProperty("timezone", timezone);
        shutdownDelaySeconds = Integer.parseInt(props.getProperty("shutdownDelaySeconds", Integer.toString(shutdownDelaySeconds)));
        String intervalsCsv = props.getProperty("warnIntervals", warnIntervals.stream().map(Object::toString).collect(Collectors.joining(",")));
        warnIntervals = Arrays.stream(intervalsCsv.split(","))
                .map(String::trim)
                .filter(s -> !s.isEmpty())
                .map(Integer::parseInt)
                .distinct()
                .sorted(Comparator.reverseOrder())
                .collect(Collectors.toList());
        triggerPermission = props.getProperty("permission", triggerPermission);
        restartCommand = props.getProperty("restartCommand", restartCommand);
        runCommandBeforeShutdown = Boolean.parseBoolean(props.getProperty("runCommandBeforeShutdown", Boolean.toString(runCommandBeforeShutdown)));
        commandTimeoutSeconds = Integer.parseInt(props.getProperty("commandTimeoutSeconds", Integer.toString(commandTimeoutSeconds)));

        // sanitize warn intervals: remove any bigger than shutdownDelaySeconds
        warnIntervals = warnIntervals.stream()
                .filter(i -> i > 0 && i <= shutdownDelaySeconds)
                .sorted(Comparator.reverseOrder())
                .collect(Collectors.toList());
    }

    private void registerCommands() {
        CommandManager cmdManager = proxy.getCommandManager();
        SimpleCommand cmd = invocation -> {
            CommandSource source = invocation.source();
            if (!source.hasPermission(triggerPermission)) {
                source.sendMessage(Component.text("You do not have permission to run this command."));
                return;
            }

            int delay = shutdownDelaySeconds;
            String[] args = invocation.arguments();
            if (args.length >= 1) {
                try {
                    delay = Integer.parseInt(args[0]);
                    if (delay < 1) delay = shutdownDelaySeconds;
                } catch (NumberFormatException ignored) {
                }
            }

            source.sendMessage(Component.text("Restart sequence triggered: shutdown in " + delay + " seconds."));
            startWarningSequence(delay);
        };

        cmdManager.register("autorestart", cmd);
        logger.info("Registered command /autorestart (permission: {})", triggerPermission);
    }

    private void scheduleDailyRestart() {
        DateTimeFormatter tf = DateTimeFormatter.ofPattern("H:mm");
        LocalTime targetTime;
        try {
            targetTime = LocalTime.parse(time, tf);
        } catch (Exception e) {
            logger.warn("Invalid time in config ({}). Falling back to 12:00", time);
            targetTime = LocalTime.of(12, 0);
        }

        ZoneId zone;
        try {
            zone = ZoneId.of(timezone);
        } catch (Exception e) {
            logger.warn("Invalid timezone in config ({}). Falling back to America/Chicago", timezone);
            zone = ZoneId.of("America/Chicago");
        }

        ZonedDateTime now = ZonedDateTime.now(zone);
        ZonedDateTime next = now.withHour(targetTime.getHour()).withMinute(targetTime.getMinute()).withSecond(0).withNano(0);
        if (next.isBefore(now) || next.equals(now)) {
            next = next.plusDays(1);
        }
        Duration initialDelay = Duration.between(ZonedDateTime.now(ZoneId.systemDefault()), next.withZoneSameInstant(ZoneId.systemDefault()));
        Duration repeat = Duration.ofDays(1);

        proxy.getScheduler().buildTask(this, () -> {
            logger.info("Auto restart time reached — starting restart sequence (shutdownDelaySeconds={})", shutdownDelaySeconds);
            startWarningSequence(shutdownDelaySeconds);
        }).delay(initialDelay).repeat(repeat).schedule();

        logger.info("Scheduled first restart in {} seconds (at {} {})", initialDelay.getSeconds(), next.toLocalDateTime(), timezone);
    }

    private void startWarningSequence(int finalDelaySeconds) {
        // broadcast at each configured interval relative to shutdown
        if (warnIntervals.isEmpty()) {
            // fallback: single announce then shutdown
            announceBroadcast(finalDelaySeconds);
        } else {
            announceBroadcast(finalDelaySeconds); // initial summary
            for (int interval : warnIntervals) {
                int delay = finalDelaySeconds - interval;
                if (delay < 0) continue;
                proxy.getScheduler().buildTask(this, () -> announceBroadcast(interval)).delay(Duration.ofSeconds(delay)).schedule();
            }
        }

        // schedule optional restart command + shutdown
        proxy.getScheduler().buildTask(this, () -> {
            if (runCommandBeforeShutdown && restartCommand != null && !restartCommand.isBlank()) {
                runExternalCommand(restartCommand, commandTimeoutSeconds);
            }
            logger.info("Performing proxy.shutdown() (requested by AutoRestart)");
            proxy.shutdown();
        }).delay(Duration.ofSeconds(finalDelaySeconds)).schedule();
    }

    private void announceBroadcast(int secondsRemaining) {
        String when = secondsRemaining >= 60 ? (secondsRemaining / 60) + " minute(s)" : secondsRemaining + " second(s)";
        String message = "Proxy will restart in " + when + ". Please prepare to disconnect.";
        proxy.getAllPlayers().forEach(p -> p.sendMessage(Component.text(message)));
        logger.info("Broadcasted restart warning: {}", message);
    }

    private void runExternalCommand(String command, int timeoutSeconds) {
        logger.info("Running external restart command: {}", command);
        // split command with shell if necessary. To keep it simple, run with /bin/sh -c on UNIX-like systems.
        boolean isWindows = System.getProperty("os.name").toLowerCase().contains("win");
        List<String> cmdList;
        if (isWindows) {
            cmdList = Arrays.asList("cmd.exe", "/c", command);
        } else {
            cmdList = Arrays.asList("/bin/sh", "-c", command);
        }

        Thread t = new Thread(() -> {
            ProcessBuilder pb = new ProcessBuilder(cmdList);
            pb.redirectErrorStream(true);
            try {
                Process p = pb.start();
                // capture output
                StringBuilder out = new StringBuilder();
                try (InputStream is = p.getInputStream();
                     InputStreamReader isr = new InputStreamReader(is, StandardCharsets.UTF_8);
                     BufferedReader br = new BufferedReader(isr)) {
                    String line;
                    while ((line = br.readLine()) != null) {
                        out.append(line).append("\n");
                    }
                } catch (IOException e) {
                    logger.warn("Error reading restart command output: ", e);
                }

                boolean finished = p.waitFor(timeoutSeconds, TimeUnit.SECONDS);
                if (!finished) {
                    p.destroyForcibly();
                    logger.warn("Restart command did not finish within {}s and was killed. Partial output:\n{}", timeoutSeconds, out.toString());
                } else {
                    int code = p.exitValue();
                    logger.info("Restart command finished with exit code {}. Output:\n{}", code, out.toString());
                }
            } catch (IOException | InterruptedException e) {
                logger.error("Failed to run restart command: ", e);
                Thread.currentThread().interrupt();
            }
        }, "AutoRestart-CommandRunner");
        t.setDaemon(true);
        t.start();
    }
}
EOF

# build.gradle.kts
cat > build.gradle.kts <<'EOF'
plugins {
    java
}

group = "com.example"
version = "1.1.0"

repositories {
    mavenCentral()
    maven("https://repo.papermc.io/repository/maven-public/")
}

val velocityApiVersion = "3.4.0" // update if you need a different Velocity API version
dependencies {
    compileOnly("com.velocitypowered:velocity-api:$velocityApiVersion")
    compileOnly("net.kyori:adventure-api:4.14.0")
}

tasks.withType<JavaCompile> {
    options.encoding = "UTF-8"
    options.release.set(17)
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

tasks.build {
    dependsOn("jar")
}
EOF

# settings.gradle.kts
cat > settings.gradle.kts <<'EOF'
rootProject.name = "velocity-autorestart"
EOF

# META-INF/velocity-plugin.json
cat > src/main/resources/META-INF/velocity-plugin.json <<'EOF'
{
  "id": "autorestart",
  "name": "AutoRestart",
  "version": "1.1.0",
  "main": "com.example.autorestart.AutoRestartPlugin",
  "authors": [
    "created-by-ai"
  ],
  "description": "Automatically restarts the Velocity proxy at a configured daily time with warnings and optional restart command.",
  "dependencies": []
}
EOF

# config.properties
cat > src/main/resources/config.properties <<'EOF'
# AutoRestart configuration
# time (H:mm 24-hour)
time=12:00
# timezone (ZoneId). Defaults to US Central (America/Chicago).
timezone=America/Chicago
# number of seconds between start of countdown and actual shutdown
shutdownDelaySeconds=60
# comma-separated list of warning intervals (seconds before shutdown). Must be <= shutdownDelaySeconds.
warnIntervals=60,30,10,5
# permission required to run /autorestart
permission=autorestart.trigger
# optional command to run to restart the proxy (e.g. "/opt/scripts/restart_proxy.sh &")
restartCommand=
# execute restartCommand before calling proxy.shutdown()? true or false
runCommandBeforeShutdown=false
# how many seconds to wait for restartCommand to finish before continuing (if runCommandBeforeShutdown is true)
commandTimeoutSeconds=30
EOF

# README
cat > README.md <<'EOF'
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
- "CST" can be ambiguous. This plugin defaults to ZoneId `America/Chicago`. Change `timezone` in config.properties if you meant another CST.
EOF

# start-proxy.sh
cat > start-proxy.sh <<'EOF'
#!/usr/bin/env bash
# Example: start the proxy jar in background and detach properly.
# Place proxy.jar in same directory as this script, or change JAR path.
JAR="/opt/velocity/proxy.jar"
JAVA="/usr/bin/java"
JAVA_OPTS="-Xms512M -Xmx2G"
LOG="/var/log/velocity/proxy.log"

mkdir -p "$(dirname "$LOG")"

nohup $JAVA $JAVA_OPTS -jar "$JAR" >> "$LOG" 2>&1 &
echo $! > /var/run/velocity.pid
EOF
chmod +x start-proxy.sh

# docs/velocity.service
cat > docs/velocity.service <<'EOF'
[Unit]
Description=Velocity Proxy
After=network.target

[Service]
User=mc
WorkingDirectory=/opt/velocity
ExecStart=/usr/bin/java -Xms512M -Xmx2G -jar proxy.jar
Restart=always
RestartSec=5
# Optional: ensure logs end up in journal
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# workflow
cat > .github/workflows/build.yml <<'EOF'
name: Build and upload shadow JAR

on:
  push:
    branches: [ "feature/autorestart-plugin", "main", "master" ]
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest

    steps:
    - name: Checkout repository
      uses: actions/checkout@v4

    - name: Set up JDK 17
      uses: actions/setup-java@v4
      with:
        distribution: 'temurin'
        java-version: '17'

    - name: Build plugin jar
      uses: gradle/gradle-build-action@v2
      with:
        arguments: 'jar'
        cache-enabled: true

    - name: Upload artifact
      uses: actions/upload-artifact@v4
      with:
        name: velocity-autorestart-jar
        path: build/libs/*.jar
EOF

echo "Files generated. To add them to a repository, run:"
echo "  git add ."
echo "  git commit -m \"Add AutoRestart Velocity plugin\""
echo "  git push origin <branch>"
echo "Done."