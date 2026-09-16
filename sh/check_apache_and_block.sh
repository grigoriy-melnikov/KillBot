#!/bin/bash

MEMORY_THRESHOLD=70  # 70% of total server memory
LOG_FILE="/var/log/apache_block.log"
BLOCK_SCRIPT="/opt/killbot/f2b/block_all_countries_except.sh"
PID_FILE="/var/run/apache_block.pid"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a $LOG_FILE
}

# Stop services
stop_services() {
    log "Stopping nginx and apache2..."
    systemctl stop nginx
    systemctl stop apache2
    sleep 2  # Give them time to stop
}

# Start services
start_services() {
    log "Starting nginx and apache2..."
    systemctl start apache2
    systemctl start nginx
}

# Check whether the script is already running
if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE" 2>/dev/null)
    if kill -0 "$pid" 2>/dev/null; then
        # Check how long the process has been running
        if [ -d "/proc/$pid" ]; then
            start_time=$(stat -c %Y /proc/$pid 2>/dev/null)
            current_time=$(date +%s)
            age=$((current_time - start_time))
            
            if [ $age -gt 3600 ]; then  # 3600 seconds = 1 hour
                log "⚠️ Process has been running for more than an hour (${age}s). Killing the old process and continuing."
                kill -9 "$pid" 2>/dev/null
                rm -f "$PID_FILE"
            else
                log "Script is already running (PID: $pid, uptime: ${age}s). Exiting."
                exit 0
            fi
        fi
    else
        log "Stale PID file found, process does not exist. Removing."
        rm -f "$PID_FILE"
    fi
fi

# Create a new PID file
echo $$ > "$PID_FILE"
log "="
log "Starting memory check (PID: $$)"

# Read used memory from free
MEM_INFO=$(free | grep Mem:)
TOTAL_MEM=$(echo $MEM_INFO | awk '{print $2}')
USED_MEM=$(echo $MEM_INFO | awk '{print $3}')
USED_PERCENT=$((USED_MEM * 100 / TOTAL_MEM))

log "System is using: $((USED_MEM / 1024 / 1024)) GB of $((TOTAL_MEM / 1024 / 1024)) GB ($USED_PERCENT%)"

if [ $USED_PERCENT -gt $MEMORY_THRESHOLD ]; then
    log "🔥 MEMORY THRESHOLD EXCEEDED! Starting the block..."
    
    # Stop services before blocking
    stop_services
    
    # Run the block script
    if bash $BLOCK_SCRIPT; then
        log "✅ Block script completed successfully"
    else
        log "❌ Block script failed"
    fi
    
    # Start services again
    start_services
else
    log "✅ Memory is OK ($USED_PERCENT% < $MEMORY_THRESHOLD%)"
fi

# Remove the PID file on exit
rm -f "$PID_FILE"
log "Check finished"