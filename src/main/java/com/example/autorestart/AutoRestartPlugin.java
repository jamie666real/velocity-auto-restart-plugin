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
import java.time.format.DateTimeParseException;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.stream.Collectors;

@Plugin(id = "autorestart", name = "AutoRestart", version = "1.0", description = "Auto-restarts proxy at configured time with advanced warnings")
public class AutoRestartPlugin {

    private final ProxyServer proxy;
    private final Path dataDirectory;
    private final Logger logger;

    // config defaults
    private String time = "12:00 PM"; // h:mm a (12-hour) or H:mm (24-hour)
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
        LocalTime targetTime = parseConfiguredTime(time);

        ZoneId zone;
        try {
            zone = ZoneId.of(timezone);
        } catch (Exception e) {
            logger.warn("Invalid timezone in config ({}). Falling back to America/Chicago", timezone);
            zone = ZoneId.of("America/Chicago");
        }

        ZonedDateTime now = ZonedDateTime.now(zone);
        ZonedDateTime next = now.withHour(targetTime.getHour()).withMinute(targetTime.getMinute()).withSecond(0).withNano(0);
        if (next.isBefore(now)) {
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

    private LocalTime parseConfiguredTime(String configuredTime) {
        String trimmed = configuredTime == null ? "" : configuredTime.trim();

        // Accept AM/PM in any capitalization, while preserving 24-hour inputs.
        if (trimmed.matches("(?i).*\\b(am|pm)\\b.*")) {
            trimmed = trimmed.toUpperCase(Locale.US);
        }

        for (DateTimeFormatter formatter : Arrays.asList(
                DateTimeFormatter.ofPattern("h:mm a", Locale.US),
                DateTimeFormatter.ofPattern("H:mm")
        )) {
            try {
                return LocalTime.parse(trimmed, formatter);
            } catch (DateTimeParseException ignored) {
                // try the next supported format
            }
        }

        logger.warn("Invalid time in config ({}). Falling back to 12:00 PM", configuredTime);
        return LocalTime.of(12, 0);
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
