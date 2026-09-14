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
